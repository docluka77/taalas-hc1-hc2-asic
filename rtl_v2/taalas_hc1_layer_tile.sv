`timescale 1ns / 1ps
/* verilator lint_off PINCONNECTEMPTY */
/* verilator lint_off UNUSED */
/* verilator lint_off SYNCASYNCNET */
// =============================================================================
// Module:      taalas_hc1_layer_tile (M14)
// Project:     Taalas HC1/HC2 Hardwired LLM Inference ASIC
// Description: Complete Hardwired Llama-3.1 Transformer Decoder Layer Tile
//              Integrating the Full Spatial Token-Pipe Datapath:
//              1. Input/Output Wormhole Token-Pipe NoC Router (M12)
//              2. Pre-Attention & Post-Attention Newton-Raphson RMSNorm (M10)
//              3. Two-Mask Via-Programmable Weight ROM Macro (M1)
//              4. Multiplierless 3b/6b CSD MAC Array (M2) + HC2 MXFP4 Lane (M3)
//              5. Group Dequantizer & Zero-Stall LoRA Fusion Unit (M4 + M7)
//              6. Llama-3.1 Frequency-Scaled RoPE Complex Rotator (M8)
//              7. 16-Bank SECDED 6T SRAM Macro + GQA 4:1 KV-Cache Manager (M5+M6)
//              8. Streaming Single-Pass Online Softmax Flash-Decode Engine (M9)
//              9. Fused SwiGLU FFN Pipe (Gate/Up/SiLU/Down) + Residuals (M11)
// =============================================================================

module taalas_hc1_layer_tile #(
    parameter int TILE_ID        = 0,
    parameter int FLIT_WIDTH     = 128,
    parameter int HIDDEN_DIM     = 16,
    parameter int HEAD_DIM       = 16,
    parameter int GQA_RATIO      = 4,
    parameter bit HC2_MXFP4_MODE = 1'b0
) (
    input  logic                    clk,
    input  logic                    rst_n,

    // Power/Clock-Gating & Global Mode Configuration
    input  logic                    tile_cg_en_i,
    input  logic                    rom_sleep_en_i,
    input  logic                    hc2_mxfp4_mode_i,
    input  logic                    zero_skip_en_i,
    input  logic                    lora_en_i,
    input  logic [7:0]              lora_rank_i,
    input  logic signed [15:0]      lora_alpha_q8_8_i,
    input  logic                    ntk_rope_en_i,
    input  logic                    bcast_en_i,
    input  logic [2:0]              slot_id_i,
    input  logic [11:0]             token_pos_i,
    input  logic                    kv_clear_slot_i,

    // Host LoRA SRAM DMA Write Broadcast Port
    input  logic                    dma_sram_we_i,
    input  logic [7:0]              dma_sram_layer_i,
    input  logic [11:0]             dma_sram_row_i,
    input  logic [63:0]             dma_sram_wdata_i,

    // Upstream Token-Pipe NoC Link (from Tile i-1 or Host Embedding)
    input  logic                    noc_in_valid_i,
    output logic                    noc_in_ready_o,
    input  logic [FLIT_WIDTH-1:0]   noc_in_flit_i,
    output logic                    noc_up_credit_ret_o,

    // Downstream Token-Pipe NoC Link (to Tile i+1 or LM-Head)
    output logic                    noc_out_valid_o,
    input  logic                    noc_out_ready_i,
    output logic [FLIT_WIDTH-1:0]   noc_out_flit_o,
    input  logic                    noc_dn_credit_ret_i,

    // Tile Status & Hardware Performance Telemetry Outputs
    output logic                    tile_busy_o,
    output logic                    tile_done_pulse_o,
    output logic [3:0]              tile_fsm_state_o,
    output logic [255:0]            layer_out_vec_o,
    output logic [15:0]             rom_reads_inc_o,
    output logic [7:0]              sram_conflict_inc_o,
    output logic                    ecc_sec_pulse_o,
    output logic                    ecc_ded_pulse_o,
    output logic [15:0]             zero_skip_inc_o,
    output logic                    noc_stall_pulse_o
);

    // -------------------------------------------------------------------------
    // 1. Master Layer Tile Sequencer FSM (Section 6.3 of Microarch Spec)
    // -------------------------------------------------------------------------
    typedef enum logic [3:0] {
        TILE_IDLE           = 4'd0,
        TILE_PRE_ATTN_NORM  = 4'd1,
        TILE_QKV_PROJ       = 4'd2,
        TILE_ROPE_KV_APPEND = 4'd3,
        TILE_FLASH_DECODE   = 4'd4,
        TILE_O_PROJ_RES1    = 4'd5,
        TILE_PRE_FFN_NORM   = 4'd6,
        TILE_SWIGLU_FFN     = 4'd7,
        TILE_NOC_EGRESS     = 4'd8
    } tile_state_e;

    tile_state_e state_q, state_d;
    logic [3:0]  step_cnt_q;
    logic        eff_hc2_mode;
    logic        local_dma_hit;

    assign eff_hc2_mode  = HC2_MXFP4_MODE || hc2_mxfp4_mode_i;
    assign local_dma_hit = dma_sram_we_i && (dma_sram_layer_i == 8'(TILE_ID));
    // -------------------------------------------------------------------------
    // 2. Internal Datapath Activation & Residual Registers (16 x Q8.8 = 256b)
    // -------------------------------------------------------------------------
    logic [255:0]           res1_buf_q;
    logic [255:0]           norm1_vec_q;
    logic [255:0]           qkv_vec_q;
    logic [255:0]           rope_vec_q;
    logic [255:0]           attn_vec_q;
    logic [255:0]           res2_buf_q;
    logic [255:0]           norm2_vec_q;
    logic [255:0]           final_vec_q;
    logic [31:0]            rx_hdr_q;

    // -------------------------------------------------------------------------
    // 3. Sub-Module M12: Credit-Based Wormhole Token-Pipe NoC Router
    // -------------------------------------------------------------------------
    logic                   noc_loc_rx_valid, noc_loc_rx_ready;
    logic [FLIT_WIDTH-1:0]  noc_loc_rx_flit;
    logic                   noc_loc_tx_valid, noc_loc_tx_ready;
    logic [FLIT_WIDTH-1:0]  noc_loc_tx_flit;
    logic [3:0]             noc_avail_cred, noc_inflight;
    logic [1:0]             noc_skid_occ;
    logic [3:0]             noc_fifo_occ;
    logic [31:0]            noc_rx_cnt, noc_tx_cnt, noc_stall_cnt;
    logic                   noc_crc_err;

    assign noc_loc_rx_ready = (state_q == TILE_IDLE) && !tile_cg_en_i;
    assign noc_loc_tx_valid = (state_q == TILE_NOC_EGRESS);

    // Format egress flit with destination = next tile (TILE_ID + 1)
    logic [23:0] tx_hdr_base;
    logic [7:0]  tx_hdr_crc8;
    assign tx_hdr_base = {rx_hdr_q[31:26], 6'(TILE_ID), 6'(TILE_ID + 1), 3'b000, slot_id_i};
    assign tx_hdr_crc8 = tx_hdr_base[7:0] ^ tx_hdr_base[15:8] ^ tx_hdr_base[23:16] ^ 8'h5A;
    assign noc_loc_tx_flit = {tx_hdr_base, tx_hdr_crc8, final_vec_q[FLIT_WIDTH-33:0]};

    taalas_token_pipe_noc_router #(
        .FLIT_WIDTH  (FLIT_WIDTH),
        .FIFO_DEPTH  (8),
        .MAX_CREDITS (8),
        .TILE_ID     (TILE_ID)
    ) u_noc_router (
        .clk                     (clk),
        .rst_n                   (rst_n),
        .bcast_en_i              (bcast_en_i),
        .c2c_en_i                (1'b0),
        .in_valid_i              (noc_in_valid_i),
        .in_ready_o              (noc_in_ready_o),
        .in_flit_i               (noc_in_flit_i),
        .upstream_credit_ret_o   (noc_up_credit_ret_o),
        .local_tx_valid_i        (noc_loc_tx_valid),
        .local_tx_ready_o        (noc_loc_tx_ready),
        .local_tx_flit_i         (noc_loc_tx_flit),
        .local_rx_valid_o        (noc_loc_rx_valid),
        .local_rx_ready_i        (noc_loc_rx_ready),
        .local_rx_flit_o         (noc_loc_rx_flit),
        .out_valid_o             (noc_out_valid_o),
        .out_ready_i             (noc_out_ready_i),
        .out_flit_o              (noc_out_flit_o),
        .downstream_credit_ret_i (noc_dn_credit_ret_i),
        .c2c_tx_valid_o          (),
        .c2c_tx_ready_i          (1'b1),
        .c2c_tx_flit_o           (),
        .c2c_rx_valid_i          (1'b0),
        .c2c_rx_ready_o          (),
        .c2c_rx_flit_i           ('0),
        .avail_credits_o         (noc_avail_cred),
        .inflight_flits_o        (noc_inflight),
        .skid_occupancy_o        (noc_skid_occ),
        .fifo_occupancy_o        (noc_fifo_occ),
        .flits_rx_cnt_o          (noc_rx_cnt),
        .flits_tx_cnt_o          (noc_tx_cnt),
        .stall_cycles_cnt_o      (noc_stall_cnt),
        .crc_err_o               (noc_crc_err)
    );

    // -------------------------------------------------------------------------
    // 4. Sub-Module M10 (1): Pre-Attention RMSNorm Engine
    // -------------------------------------------------------------------------
    logic         norm1_start, norm1_busy, norm1_out_valid, norm1_out_last, norm1_done;
    logic [255:0] norm1_y_vec;
    logic [31:0]  norm1_var_eps;
    logic [15:0]  norm1_inv_rms;
    logic [2:0]   norm1_fsm;

    assign norm1_start = (state_q == TILE_PRE_ATTN_NORM) && (step_cnt_q == 4'd0);

    taalas_rmsnorm_engine #(
        .HIDDEN_DIM  (32),
        .VEC_W       (16),
        .DATA_W      (16),
        .EPS_DEFAULT (4)
    ) u_pre_attn_norm (
        .clk            (clk),
        .rst_n          (rst_n),
        .start_i        (norm1_start),
        .in_valid_i     (1'b1),
        .x_vec_i        (res1_buf_q),
        .eps_q16_i      (16'd4),
        .ext_gamma_en_i (1'b0),
        .gamma_vec_i    ('0),
        .busy_o         (norm1_busy),
        .out_valid_o    (norm1_out_valid),
        .out_last_o     (norm1_out_last),
        .done_o         (norm1_done),
        .y_vec_o        (norm1_y_vec),
        .var_eps_o      (norm1_var_eps),
        .inv_rms_q8_8_o (norm1_inv_rms),
        .fsm_state_o    (norm1_fsm)
    );
    // -------------------------------------------------------------------------
    // 5. Sub-Modules M1 + M2 + M3 + M7 + M4:
    //    Hardwired Via-Mask ROM, 3b/6b CSD MAC / HC2 MXFP4, LoRA & Dequantizer
    // -------------------------------------------------------------------------
    logic         rom_cs_en;
    logic [1:0]   rom_bank_sel;
    logic [5:0]   rom_row_addr;
    logic [511:0] rom_rdata;
    logic [191:0] rom_w3b;
    logic [47:0]  rom_out_idx, rom_out_val6b;
    logic [15:0]  rom_grp_scale;
    logic [7:0]   rom_grp_zp;
    logic         rom_rvalid;
    logic [9:0]   rom_active_vias;
    logic [3:0]   rom_bank_active;
    logic         rom_bl_prech;

    assign rom_cs_en    = (state_q == TILE_QKV_PROJ) || (state_q == TILE_O_PROJ_RES1) ||
                          (state_q == TILE_SWIGLU_FFN);
    assign rom_bank_sel = (state_q == TILE_QKV_PROJ) ? 2'd0 :
                          (state_q == TILE_O_PROJ_RES1) ? 2'd1 : 2'd2;
    assign rom_row_addr = {2'b00, step_cnt_q};

    taalas_via_mask_rom_macro #(
        .NUM_BANKS     (4),
        .ROWS          (64),
        .COLS          (512),
        .COLS_3B       (64),
        .OUTLIER_SLOTS (8),
        .MASK_SEED     (32'h5441_414C + TILE_ID)
    ) u_via_mask_rom (
        .clk                (clk),
        .rst_n              (rst_n),
        .sleep_n            (!rom_sleep_en_i && !tile_cg_en_i),
        .sleep_i            (rom_sleep_en_i || tile_cg_en_i),
        .iso_en_i           (rom_sleep_en_i || tile_cg_en_i),
        .cs_en              (rom_cs_en),
        .precharge_en       (rom_cs_en),
        .sa_en              (rom_cs_en),
        .bank_sel_i         (rom_bank_sel),
        .addr_i             (rom_row_addr),
        .prog_en_i          (1'b0),
        .prog_bank_i        ('0),
        .prog_row_i         ('0),
        .prog_wdata_i       ('0),
        .bist_start_i       (1'b0),
        .bist_busy_o        (),
        .bist_done_o        (),
        .bist_crc16_o       (),
        .bist_pass_o        (),
        .rdata_o            (rom_rdata),
        .weights_3b_o       (rom_w3b),
        .outlier_idx_o      (rom_out_idx),
        .outlier_val6b_o    (rom_out_val6b),
        .group_scale_fp16_o (rom_grp_scale),
        .group_zp_int8_o    (rom_grp_zp),
        .rvalid_o           (rom_rvalid),
        .active_vias_o      (rom_active_vias),
        .bank_active_o      (rom_bank_active),
        .bl_precharged_o    (rom_bl_prech)
    );

    // Pack 16-element Q8.8 activation vector into 16 x INT8 (128 bits) for MAC
    logic [255:0] vmm_src_vec;
    logic [127:0] vmm_act_int8;
    logic         vmm_in_valid;

    assign vmm_src_vec = (state_q == TILE_QKV_PROJ)    ? norm1_vec_q :
                         (state_q == TILE_O_PROJ_RES1) ? attn_vec_q  : norm2_vec_q;
    assign vmm_in_valid = rom_rvalid && (step_cnt_q == 4'd1);

    always_comb begin
        for (int i = 0; i < 16; i++) begin
            vmm_act_int8[i*8 +: 8] = vmm_src_vec[i*16 + 4 +: 8];
        end
    end

    // M2: Multiplierless 3b/6b CSD Wired MAC Array (16-elem x 16-ch)
    logic               csd_mac_valid;
    logic [16*24-1:0]   csd_acc_out;
    logic signed [15:0] csd_act_sum;
    logic [15:0]        csd_zero_saved;

    taalas_3b6b_wired_mac_array #(
        .VEC_LEN      (16),
        .OUT_CHANNELS (16),
        .NUM_OUTLIERS (4)
    ) u_wired_mac (
        .clk              (clk),
        .rst_n            (rst_n),
        .valid_i          (vmm_in_valid),
        .act_vec_i        (vmm_act_int8),
        .w_base_3b_i      ({4{rom_w3b}}),
        .w_out_val_6b_i   ({8{rom_out_val6b}}),
        .w_out_idx_6b_i   ({8{rom_out_idx}}),
        .zero_skip_en_i   (zero_skip_en_i),
        .valid_o          (csd_mac_valid),
        .acc_out_o        (csd_acc_out),
        .act_sum_o        (csd_act_sum),
        .zero_ops_saved_o (csd_zero_saved)
    );
    // M3: HC2 OCP MXFP4 MAC Lane (16-elem x 16-lane)
    logic             mxfp4_valid;
    logic [16*16-1:0] mxfp4_dot_int16;
    logic [16*10-1:0] mxfp4_exp_comb;
    logic [16*32-1:0] mxfp4_fp32_out;

    taalas_mxfp4_hc2_mac_lane #(
        .BLOCK_SIZE (16),
        .NUM_LANES  (16)
    ) u_mxfp4_mac (
        .clk         (clk),
        .rst_n       (rst_n),
        .valid_i     (vmm_in_valid),
        .act_mxfp4_i (vmm_act_int8[63:0]),
        .act_e8m0_i  (8'd127),
        .w_mxfp4_i   ({2{rom_rdata}}),
        .w_e8m0_i    ({16{8'd127}}),
        .valid_o     (mxfp4_valid),
        .dot_int16_o (mxfp4_dot_int16),
        .exp_comb_o  (mxfp4_exp_comb),
        .fp32_out_o  (mxfp4_fp32_out)
    );

    // M7: Zero-Stall SRAM-Backed LoRA Parallel Overlay Engine
    logic             lora_valid;
    logic [8*24-1:0]  lora_latent_h;
    logic [16*16-1:0] lora_delta_out;
    logic [15:0]      lora_stall_cyc;

    taalas_lora_sram_overlay_engine #(
        .IN_DIM       (16),
        .OUT_CHANNELS (16),
        .MAX_RANK     (8),
        .MAX_SKEW     (8)
    ) u_lora_overlay (
        .clk                 (clk),
        .rst_n               (rst_n),
        .valid_i             (vmm_in_valid),
        .lora_en_i           (lora_en_i),
        .active_rank_i       (lora_rank_i),
        .alpha_over_r_q8_8_i (lora_alpha_q8_8_i),
        .skew_delay_i        (3'd1),
        .act_vec_i           (vmm_act_int8),
        .ext_weights_en_i    (1'b0),
        .lora_a_flat_i       ('0),
        .lora_b_flat_i       ('0),
        .sram_we_i           (local_dma_hit),
        .sram_sel_b_i        (dma_sram_row_i[4]),
        .sram_row_addr_i     (dma_sram_row_i[5:0]),
        .sram_wdata_i        ({2{dma_sram_wdata_i}}),
        .valid_o             (lora_valid),
        .latent_h_o          (lora_latent_h),
        .lora_delta_o        (lora_delta_out),
        .stall_cycles_o      (lora_stall_cyc)
    );

    // M4: Per-Group Zero-Point & Scale Dequantizer + LoRA Fusion
    logic [16*24-1:0] deq_raw_acc_in;
    logic             deq_in_valid, deq_out_valid, deq_sat_flag;
    logic [255:0]     deq_out_vec;
    logic [16*32-1:0] deq_fp32_out;

    always_comb begin
        deq_raw_acc_in = '0;
        for (int ch = 0; ch < 16; ch++) begin
            logic signed [15:0] mx_dot;
            mx_dot = $signed(mxfp4_dot_int16[ch*16 +: 16]);
            if (eff_hc2_mode) begin
                deq_raw_acc_in[ch*24 +: 24] = {{8{mx_dot[15]}}, mx_dot};
            end else begin
                deq_raw_acc_in[ch*24 +: 24] = csd_acc_out[ch*24 +: 24];
            end
        end
    end
    assign deq_in_valid = eff_hc2_mode ? mxfp4_valid : csd_mac_valid;

    taalas_group_dequant_scale_unit #(
        .OUT_CHANNELS (16),
        .ACC_WIDTH    (24),
        .SCALE_WIDTH  (16),
        .OUT_WIDTH    (16)
    ) u_group_dequant (
        .clk           (clk),
        .rst_n         (rst_n),
        .valid_i       (deq_in_valid),
        .first_group_i (1'b1),
        .last_group_i  (1'b1),
        .raw_acc_i     (deq_raw_acc_in),
        .act_sum_i     (csd_act_sum),
        .w_scale_i     ({16{16'h0100}}),
        .act_scale_i   (16'sd256),
        .w_zp_i        ('0),
        .lora_delta_i  (lora_delta_out),
        .lora_en_i     (lora_en_i),
        .valid_o       (deq_out_valid),
        .dequant_out_o (deq_out_vec),
        .acc_fp32_o    (deq_fp32_out),
        .sat_flag_o    (deq_sat_flag)
    );
    // -------------------------------------------------------------------------
    // 6. Sub-Modules M8 + M5 + M6 + M9:
    //    RoPE Complex Rotation, 16-Bank SECDED 6T SRAM, KV-Cache & Flash-Decode
    // -------------------------------------------------------------------------
    logic         rope_in_valid, rope_out_valid;
    logic [255:0] rope_out_vec;

    assign rope_in_valid = (state_q == TILE_ROPE_KV_APPEND) && (step_cnt_q == 4'd0);

    taalas_rope_cordic_unit #(
        .HEAD_DIM        (16),
        .PAIR_LANES      (8),
        .DATA_W          (16),
        .TRIG_W          (16),
        .THETA_BASE      (500000),
        .SCALE_FACTOR_X8 (8)
    ) u_rope_cordic (
        .clk                 (clk),
        .rst_n               (rst_n),
        .valid_i             (rope_in_valid),
        .is_key_i            (1'b0),
        .head_id_i           (6'd0),
        .pair_chunk_idx_i    (3'd0),
        .token_pos_i         ({5'd0, token_pos_i}),
        .ntk_scale_en_i      (ntk_rope_en_i),
        .bypass_en_i         (1'b0),
        .vec_in_i            (qkv_vec_q),
        .valid_o             (rope_out_valid),
        .is_key_o            (),
        .head_id_o           (),
        .pair_chunk_idx_o    (),
        .vec_out_o           (rope_out_vec),
        .cos_monitor_o       (),
        .sin_monitor_o       (),
        .zero_pos_identity_o (),
        .sat_count_o         ()
    );

    // M6: GQA 4:1 KV-Cache Manager
    logic         kv_append_en, kv_read_en;
    logic         sram_req_valid, sram_req_we;
    logic [3:0]   sram_req_bank;
    logic [9:0]   sram_req_row;
    logic [63:0]  sram_req_wdata;
    logic [127:0] kv_k_deq, kv_v_deq;
    logic [511:0] kv_gqa_k_bcast, kv_gqa_v_bcast;
    logic         kv_valid, kv_last, kv_seq_done;
    logic [2:0]   kv_fsm_state;

    assign kv_append_en = (state_q == TILE_ROPE_KV_APPEND) && (step_cnt_q == 4'd0);
    assign kv_read_en   = (state_q == TILE_FLASH_DECODE)   && (step_cnt_q == 4'd0);

    taalas_kv_cache_manager #(
        .MAX_USERS    (8),
        .MAX_SEQ_LEN  (32),
        .NUM_KV_HEADS (8),
        .GQA_RATIO    (4),
        .HEAD_DIM     (16)
    ) u_kv_cache_mgr (
        .clk                (clk),
        .rst_n              (rst_n),
        .slot_id_i          (slot_id_i),
        .kv_head_id_i       (3'd0),
        .append_en_i        (kv_append_en),
        .read_seq_en_i      (kv_read_en),
        .clear_slot_i       (kv_clear_slot_i),
        .sliding_win_en_i   (1'b1),
        .sink_tokens_cfg_i  (4'd4),
        .k_vec_in_i         (qkv_vec_q[63:0]),
        .v_vec_in_i         (qkv_vec_q[127:64]),
        .k_scale_in_i       (16'h0100),
        .v_scale_in_i       (16'h0100),
        .k_zp_in_i          (4'd0),
        .v_zp_in_i          (4'd0),
        .sram_req_valid_o   (sram_req_valid),
        .sram_req_we_o      (sram_req_we),
        .sram_req_bank_o    (sram_req_bank),
        .sram_req_row_o     (sram_req_row),
        .sram_req_wdata_o   (sram_req_wdata),
        .k_dequant_o        (kv_k_deq),
        .v_dequant_o        (kv_v_deq),
        .gqa_k_bcast_o      (kv_gqa_k_bcast),
        .gqa_v_bcast_o      (kv_gqa_v_bcast),
        .wr_ptr_o           (),
        .rd_ptr_o           (),
        .seq_pos_o          (),
        .curr_seq_len_o     (),
        .slot_active_mask_o (),
        .eviction_cnt_o     (),
        .kv_valid_o         (kv_valid),
        .kv_last_o          (kv_last),
        .seq_done_o         (kv_seq_done),
        .fsm_state_o        (kv_fsm_state)
    );

    // M5: 16-Bank On-Die 6T SRAM Macro with GF(2^4) Swizzle & SECDED ECC
    logic        sram_resp_valid, sram_sec_err, sram_ded_err, sram_conflict_free;
    logic [63:0] sram_resp_rdata;
    logic [15:0] sram_conflict_mask;

    taalas_sram_6t_banked_macro #(
        .NUM_BANKS  (16),
        .BANK_DEPTH (64),
        .DATA_WIDTH (64),
        .ECC_WIDTH  (8),
        .RAW_WIDTH  (72)
    ) u_sram_macro (
        .clk                  (clk),
        .rst_n                (rst_n),
        .ret_sleep_i          (tile_cg_en_i),
        .bank_cg_en_i         (16'hFFFF),
        .req_valid_i          (sram_req_valid || local_dma_hit),
        .req_we_i             (sram_req_we    || local_dma_hit),
        .req_bank_i           (local_dma_hit ? dma_sram_row_i[3:0] : sram_req_bank),
        .req_row_i            (local_dma_hit ? dma_sram_row_i[5:0] : sram_req_row[5:0]),
        .req_wdata_i          (local_dma_hit ? dma_sram_wdata_i    : sram_req_wdata),
        .req_wmask_i          (8'hFF),
        .vec_req_valid_i      (16'hFFFF),
        .vec_req_row_i        ({16{2'b00, sram_req_row[5:0]}}),
        .bank_conflict_mask_o (sram_conflict_mask),
        .conflict_free_o      (sram_conflict_free),
        .err_inj_en_i         (1'b0),
        .err_inj_mask_i       ('0),
        .resp_valid_o         (sram_resp_valid),
        .resp_rdata_o         (sram_resp_rdata),
        .resp_raw_codeword_o  (),
        .phys_bank_o          (),
        .sec_err_o            (sram_sec_err),
        .ded_err_o            (sram_ded_err),
        .err_syndrome_o       (),
        .sec_err_cnt_o        (),
        .ded_err_cnt_o        ()
    );
    // M9: Streaming Single-Pass Online Softmax Flash-Decode Engine
    logic          flash_step_valid, flash_out_valid;
    logic [1023:0] flash_attn_out;
    logic [255:0]  k_shared_q88, v_shared_q88;

    always_comb begin
        for (int i = 0; i < 16; i++) begin
            k_shared_q88[i*16 +: 16] = {{4{kv_k_deq[i*8 + 7]}}, kv_k_deq[i*8 +: 8], 4'b0000};
            v_shared_q88[i*16 +: 16] = {{4{kv_v_deq[i*8 + 7]}}, kv_v_deq[i*8 +: 8], 4'b0000};
        end
    end

    taalas_flash_decode_attention #(
        .HEAD_DIM  (16),
        .GQA_RATIO (4),
        .DATA_W    (16)
    ) u_flash_attn (
        .clk               (clk),
        .rst_n             (rst_n),
        .start_seq_i       (kv_read_en),
        .kv_valid_i        (kv_valid),
        .kv_last_i         (kv_last),
        .q_heads_i         ({4{rope_vec_q}}),
        .k_shared_i        (k_shared_q88),
        .v_shared_i        (v_shared_q88),
        .scale_log2e_q8_8_i(16'd92),
        .step_valid_o      (flash_step_valid),
        .out_valid_o       (flash_out_valid),
        .attn_out_o        (flash_attn_out),
        .max_score_o       (),
        .denom_sum_o       ()
    );

    // -------------------------------------------------------------------------
    // 7. Sub-Modules M10 (2) + M11:
    //    Post-Attention RMSNorm & Fused SwiGLU FFN Pipe (Gate/Up/SiLU/Down)
    // -------------------------------------------------------------------------
    logic         norm2_start, norm2_busy, norm2_out_valid, norm2_out_last, norm2_done;
    logic [255:0] norm2_y_vec;

    assign norm2_start = (state_q == TILE_PRE_FFN_NORM) && (step_cnt_q == 4'd0);

    taalas_rmsnorm_engine #(
        .HIDDEN_DIM  (32),
        .VEC_W       (16),
        .DATA_W      (16),
        .EPS_DEFAULT (4)
    ) u_post_attn_norm (
        .clk            (clk),
        .rst_n          (rst_n),
        .start_i        (norm2_start),
        .in_valid_i     (1'b1),
        .x_vec_i        (res2_buf_q),
        .eps_q16_i      (16'd4),
        .ext_gamma_en_i (1'b0),
        .gamma_vec_i    ('0),
        .busy_o         (norm2_busy),
        .out_valid_o    (norm2_out_valid),
        .out_last_o     (norm2_out_last),
        .done_o         (norm2_done),
        .y_vec_o        (norm2_y_vec),
        .var_eps_o      (),
        .inv_rms_q8_8_o (),
        .fsm_state_o    ()
    );

    logic          swiglu_in_valid, swiglu_down_valid, swiglu_down_done;
    logic [255:0]  swiglu_silu_vec, swiglu_had_vec;
    logic [127:0]  swiglu_had_int8;
    logic [16*24-1:0] swiglu_down_acc;

    assign swiglu_in_valid = (state_q == TILE_SWIGLU_FFN) && deq_out_valid;

    taalas_swiglu_ffn_pipe #(
        .CHANNELS    (16),
        .DOWN_OUT_CH (16),
        .DATA_W      (16)
    ) u_swiglu_ffn (
        .clk              (clk),
        .rst_n            (rst_n),
        .valid_i          (swiglu_in_valid),
        .first_ffn_grp_i  (1'b1),
        .last_ffn_grp_i   (1'b1),
        .gate_vec_i       (deq_out_vec),
        .up_vec_i         (norm2_vec_q),
        .w_down_3b_i      ({4{rom_w3b}}),
        .silu_valid_o     (),
        .silu_vec_o       (swiglu_silu_vec),
        .hadamard_valid_o (),
        .hadamard_vec_o   (swiglu_had_vec),
        .hadamard_int8_o  (swiglu_had_int8),
        .down_valid_o     (swiglu_down_valid),
        .down_done_o      (swiglu_down_done),
        .down_acc_o       (swiglu_down_acc)
    );
    // -------------------------------------------------------------------------
    // 8. Saturating Residual Adders (Res1 = x_in + O_proj, Res2 = Res1 + FFN_down)
    // -------------------------------------------------------------------------
    function automatic logic signed [15:0] sat24_to_16(input logic signed [23:0] val24);
        begin
            if (val24 > 24'sd32767)       sat24_to_16 = 16'sd32767;
            else if (val24 < -24'sd32768) sat24_to_16 = -16'sd32768;
            else                          sat24_to_16 = val24[15:0];
        end
    endfunction

    logic [255:0] res1_sum_comb, res2_sum_comb;

    always_comb begin
        for (int i = 0; i < 16; i++) begin
            logic signed [16:0] s1, s2;
            logic signed [15:0] x_in_i, o_proj_i, r1_i, ffn_d_i;
            x_in_i   = $signed(res1_buf_q[i*16 +: 16]);
            o_proj_i = $signed(deq_out_vec[i*16 +: 16]);
            s1       = 17'(x_in_i) + 17'(o_proj_i);
            res1_sum_comb[i*16 +: 16] = (s1 > 17'sd32767) ? 16'sd32767 :
                                        (s1 < -17'sd32768) ? -16'sd32768 : s1[15:0];

            r1_i    = $signed(res2_buf_q[i*16 +: 16]);
            // [STAGE-10 FIX BUG-HC1-008]: Clamp signed 24-bit FFN accumulator to INT16 before residual add
            ffn_d_i = sat24_to_16($signed(swiglu_down_acc[i*24 +: 24]));
            s2      = 17'(r1_i) + 17'(ffn_d_i);
            res2_sum_comb[i*16 +: 16] = (s2 > 17'sd32767) ? 16'sd32767 :
                                        (s2 < -17'sd32768) ? -16'sd32768 : s2[15:0];
        end
    end

    // -------------------------------------------------------------------------
    // 9. Master Layer Tile Sequencer FSM Transitions & Datapath Latching
    // -------------------------------------------------------------------------
    always_comb begin
        state_d = state_q;
        unique case (state_q)
            TILE_IDLE:           if (noc_loc_rx_valid && !tile_cg_en_i) state_d = TILE_PRE_ATTN_NORM;
            TILE_PRE_ATTN_NORM:  if (norm1_done)                        state_d = TILE_QKV_PROJ;
            TILE_QKV_PROJ:       if (deq_out_valid)                     state_d = TILE_ROPE_KV_APPEND;
            TILE_ROPE_KV_APPEND: if (step_cnt_q >= 4'd3)                state_d = TILE_FLASH_DECODE;
            TILE_FLASH_DECODE:   if (flash_out_valid)                   state_d = TILE_O_PROJ_RES1;
            TILE_O_PROJ_RES1:    if (deq_out_valid)                     state_d = TILE_PRE_FFN_NORM;
            TILE_PRE_FFN_NORM:   if (norm2_done)                        state_d = TILE_SWIGLU_FFN;
            TILE_SWIGLU_FFN:     if (swiglu_down_done)                  state_d = TILE_NOC_EGRESS;
            TILE_NOC_EGRESS:     if (noc_loc_tx_ready)                  state_d = TILE_IDLE;
            default:             state_d = TILE_IDLE;
        endcase
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_q     <= TILE_IDLE;
            step_cnt_q  <= 4'd0;
            rx_hdr_q    <= 32'd0;
            res1_buf_q  <= 256'd0;
            norm1_vec_q <= 256'd0;
            qkv_vec_q   <= 256'd0;
            rope_vec_q  <= 256'd0;
            attn_vec_q  <= 256'd0;
            res2_buf_q  <= 256'd0;
            norm2_vec_q <= 256'd0;
            final_vec_q <= 256'd0;
        end else begin
            state_q <= state_d;
            if (state_q != state_d) begin
                step_cnt_q <= 4'd0;
            end else if (step_cnt_q < 4'd15) begin
                step_cnt_q <= step_cnt_q + 4'd1;
            end

            if (state_q == TILE_IDLE && noc_loc_rx_valid && !tile_cg_en_i) begin
                rx_hdr_q   <= noc_loc_rx_flit[FLIT_WIDTH-1 -: 32];
                res1_buf_q <= {{(256 - (FLIT_WIDTH - 32)){1'b0}}, noc_loc_rx_flit[FLIT_WIDTH-33:0]};
            end
            if (norm1_out_valid)                         norm1_vec_q <= norm1_y_vec;
            if (state_q == TILE_QKV_PROJ && deq_out_valid) qkv_vec_q <= deq_out_vec;
            if (rope_out_valid)                          rope_vec_q  <= rope_out_vec;
            if (flash_out_valid)                         attn_vec_q  <= flash_attn_out[255:0];
            if (state_q == TILE_O_PROJ_RES1 && deq_out_valid) res2_buf_q <= res1_sum_comb;
            if (norm2_out_valid)                         norm2_vec_q <= norm2_y_vec;
            if (swiglu_down_done)                        final_vec_q <= res2_sum_comb;
        end
    end

    assign tile_busy_o         = (state_q != TILE_IDLE) || (noc_skid_occ != 2'd0) || (noc_fifo_occ != 4'd0);
    assign tile_done_pulse_o   = (state_q == TILE_NOC_EGRESS) && noc_loc_tx_ready;
    assign tile_fsm_state_o    = state_q;
    assign layer_out_vec_o     = final_vec_q;
    assign rom_reads_inc_o     = rom_rvalid ? {6'd0, rom_active_vias} : 16'd0;
    assign sram_conflict_inc_o = sram_conflict_free ? 8'd0 : 8'd1;
    assign ecc_sec_pulse_o     = sram_sec_err;
    assign ecc_ded_pulse_o     = sram_ded_err;
    assign zero_skip_inc_o     = csd_mac_valid ? csd_zero_saved : 16'd0;
    assign noc_stall_pulse_o   = (!noc_loc_tx_ready && (state_q == TILE_NOC_EGRESS));

    // Inline SVA Formal Invariant: Master Tile FSM stays within valid states [0..8]
    logic past_valid_q;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) past_valid_q <= 1'b0;
        else        past_valid_q <= 1'b1;
    end

    always_ff @(posedge clk) begin
        if (past_valid_q && rst_n) begin
            assert (state_q <= TILE_NOC_EGRESS);
            // PROP_BUG008_SWIGLU_SAT_BOUND: Signed 24-to-16 saturation never wraps sign on overflow
            if ($signed(swiglu_down_acc[23:0]) > 24'sd32767) begin
                PROP_BUG008_SWIGLU_SAT_POS: assert (sat24_to_16($signed(swiglu_down_acc[23:0])) == 16'sd32767);
            end
            if ($signed(swiglu_down_acc[23:0]) < -24'sd32768) begin
                PROP_BUG008_SWIGLU_SAT_NEG: assert (sat24_to_16($signed(swiglu_down_acc[23:0])) == -16'sd32768);
            end
        end
    end

endmodule
