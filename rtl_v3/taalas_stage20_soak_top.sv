`timescale 1ns / 1ps
/* verilator lint_off SYNCASYNCNET */
// =============================================================================
// Module:      taalas_stage20_soak_top
// Project:     Taalas HC1/HC2 Autonomous Hardware Engineering Marathon (Stage 20C)
// Description: Multi-Subsystem 10,000,000-Cycle Continuous Hardware Soak &
//              Corner-Case Stress Harness integrating 9 core HC1/HC2 engines:
//                1. M02: taalas_3b6b_wired_mac_array (VEC_LEN=16, OUT_CHANNELS=8, NUM_OUTLIERS=4)
//                2. M03: taalas_mxfp4_hc2_mac_lane (BLOCK_SIZE=16, NUM_LANES=4)
//                3. M04: taalas_group_dequant_scale_unit (OUT_CHANNELS=8)
//                4. M05: taalas_sram_6t_banked_macro (NUM_BANKS=16, BANK_DEPTH=64)
//                5. M07: taalas_lora_sram_overlay_engine (IN_DIM=16, OUT_CHANNELS=8, MAX_RANK=8)
//                6. M12: taalas_token_pipe_noc_router (FLIT_WIDTH=128, FIFO_DEPTH=8, MAX_CREDITS=8)
//                7. M18: taalas_ecc_bist_scrubber (NUM_BANKS=16, BANK_DEPTH=64, SPARE_ROWS=8)
//                8. H2:  taalas_hc2_c2c_llr_serdes_ctrl (112G C2C Go-Back-N LLR Replay)
//                9. H3:  taalas_hc2_moe_mla_router (DeepSeek-R1 Top-K MoE & MLA Router)
// =============================================================================

module taalas_stage20_soak_top (
    input  logic        clk,
    input  logic        rst_n,

    // 1. M02: 3b/6b CSD Wired MAC Array Interface
    input  logic        m02_valid_i,
    input  logic        m02_zero_skip_en_i,
    input  logic [63:0] m02_act_lo_i,
    input  logic [63:0] m02_act_hi_i,
    input  logic [63:0] m02_w3b_pat_i,
    input  logic [63:0] m02_out_pat_i,
    output logic        m02_valid_o,
    output logic signed [15:0] m02_act_sum_o,
    output logic [15:0] m02_zero_ops_saved_o,
    output logic [63:0] m02_acc_lo_o,
    output logic [63:0] m02_acc_mid_o,
    output logic [63:0] m02_acc_hi_o,

    // 2. M03: HC2 OCP MXFP4 MAC Lane Interface
    input  logic        m03_valid_i,
    input  logic [63:0] m03_act_mxfp4_i,
    input  logic [7:0]  m03_act_e8m0_i,
    input  logic [63:0] m03_w_mxfp4_base_i,
    input  logic [31:0] m03_w_e8m0_i,
    output logic        m03_valid_o,
    output logic [63:0] m03_dot_int16_o,
    output logic [39:0] m03_exp_comb_o,
    output logic [63:0] m03_fp32_lo_o,
    output logic [63:0] m03_fp32_hi_o,

    // 3. M04: Per-Group Zero-Point & Scale Dequantizer Interface
    input  logic        m04_valid_i,
    input  logic        m04_first_group_i,
    input  logic        m04_last_group_i,
    input  logic        m04_lora_en_i,
    input  logic signed [23:0] m04_raw_acc_ch0_i,
    input  logic signed [15:0] m04_act_sum_i,
    input  logic signed [15:0] m04_w_scale_ch0_i,
    input  logic signed [15:0] m04_act_scale_i,
    input  logic signed [7:0]  m04_w_zp_ch0_i,
    input  logic signed [15:0] m04_lora_delta_ch0_i,
    output logic        m04_valid_o,
    output logic [63:0] m04_dequant_lo_o,
    output logic [63:0] m04_dequant_hi_o,
    output logic        m04_sat_flag_o,

    // 4. M05: 16-Bank On-Die 6T SECDED SRAM Macro Interface
    input  logic        m05_ret_sleep_i,
    input  logic [15:0] m05_bank_cg_en_i,
    input  logic        m05_req_valid_i,
    input  logic        m05_req_we_i,
    input  logic [3:0]  m05_req_bank_i,
    input  logic [5:0]  m05_req_row_i,
    input  logic [63:0] m05_req_wdata_i,
    input  logic [7:0]  m05_req_wmask_i,
    input  logic [15:0] m05_vec_req_valid_i,
    input  logic [63:0] m05_vec_row_lo_i,
    input  logic [63:0] m05_vec_row_hi_i,
    input  logic        m05_err_inj_en_i,
    input  logic [63:0] m05_err_inj_lo_i,
    input  logic [7:0]  m05_err_inj_hi_i,
    output logic        m05_conflict_free_o,
    output logic        m05_resp_valid_o,
    output logic [63:0] m05_resp_rdata_o,
    output logic [3:0]  m05_phys_bank_o,
    output logic        m05_sec_err_o,
    output logic        m05_ded_err_o,
    output logic [7:0]  m05_err_syndrome_o,
    output logic [15:0] m05_sec_cnt_o,
    output logic [15:0] m05_ded_cnt_o,

    // 5. M07: Zero-Stall SRAM LoRA Overlay Engine Interface
    input  logic        m07_valid_i,
    input  logic        m07_lora_en_i,
    input  logic [7:0]  m07_active_rank_i,
    input  logic signed [15:0] m07_alpha_q88_i,
    input  logic [2:0]  m07_skew_delay_i,
    input  logic [63:0] m07_act_lo_i,
    input  logic [63:0] m07_act_hi_i,
    input  logic        m07_sram_we_i,
    input  logic        m07_sram_sel_b_i,
    input  logic [5:0]  m07_sram_row_addr_i,
    input  logic [63:0] m07_sram_wdata_lo_i,
    input  logic [63:0] m07_sram_wdata_hi_i,
    output logic        m07_valid_o,
    output logic [63:0] m07_lora_delta_lo_o,
    output logic [63:0] m07_lora_delta_hi_o,
    output logic [15:0] m07_stall_cycles_o,

    // 6. M12: Credit-Based Wormhole Token-Pipe NoC Router Interface
    input  logic        m12_bcast_en_i,
    input  logic        m12_c2c_en_i,
    input  logic        m12_in_valid_i,
    input  logic [31:0] m12_in_hdr_i,
    input  logic [63:0] m12_in_pay_lo_i,
    input  logic        m12_loc_tx_valid_i,
    input  logic        m12_loc_rx_ready_i,
    input  logic        m12_out_ready_i,
    input  logic        m12_dn_credit_ret_i,
    input  logic        m12_c2c_tx_ready_i,
    input  logic        m12_c2c_rx_valid_i,
    output logic        m12_in_ready_o,
    output logic        m12_up_credit_ret_o,
    output logic        m12_loc_tx_ready_o,
    output logic        m12_loc_rx_valid_o,
    output logic [63:0] m12_loc_rx_pay_lo_o,
    output logic        m12_out_valid_o,
    output logic [63:0] m12_out_pay_lo_o,
    output logic        m12_c2c_tx_valid_o,
    output logic        m12_c2c_rx_ready_o,
    output logic [3:0]  m12_avail_credits_o,
    output logic [3:0]  m12_inflight_flits_o,
    output logic [1:0]  m12_skid_occ_o,
    output logic [3:0]  m12_fifo_occ_o,
    output logic [31:0] m12_rx_cnt_o,
    output logic [31:0] m12_tx_cnt_o,
    output logic [31:0] m12_stall_cnt_o,
    output logic        m12_crc_err_o,

    // 7. M18: Autonomous SECDED Patrol Scrubber, Spare-Row CAM & Droop Monitor
    input  logic        m18_active_req_i,
    input  logic [3:0]  m18_active_bank_i,
    input  logic [5:0]  m18_active_addr_i,
    input  logic        m18_seu_inj_en_i,
    input  logic [3:0]  m18_seu_inj_bank_i,
    input  logic [5:0]  m18_seu_inj_addr_i,
    input  logic [63:0] m18_seu_inj_mask_lo_i,
    input  logic [7:0]  m18_seu_inj_mask_hi_i,
    input  logic        m18_bist_start_i,
    input  logic [15:0] m18_expected_crc16_i,
    input  logic [7:0]  m18_canary_taps_i,
    input  logic [7:0]  m18_mac_active_lanes_i,
    output logic [31:0] m18_sbe_scrubbed_cnt_o,
    output logic [15:0] m18_dbe_detected_cnt_o,
    output logic        m18_uncorrectable_dbe_irq_o,
    output logic        m18_remap_valid_o,
    output logic        m18_active_hit_spare_o,
    output logic [3:0]  m18_spare_rows_used_o,
    output logic        m18_bist_done_o,
    output logic        m18_bist_pass_o,
    output logic [15:0] m18_bist_crc16_o,
    output logic        m18_clk_stretch_en_o,
    output logic        m18_gated_clk_en_o,
    output logic [15:0] m18_droop_event_cnt_o,

    // 8. H2: 112G C2C SerDes Link-Layer Retry (LLR) Controller Interface
    input  logic        h2_tx_flit_valid_i,
    input  logic [63:0] h2_tx_flit_data_i,
    input  logic        h2_link_err_inj_i,
    output logic        h2_tx_flit_ready_o,
    output logic        h2_rx_flit_valid_o,
    output logic [63:0] h2_rx_flit_data_o,
    output logic [7:0]  h2_rx_flit_seq_o,
    output logic        h2_replay_active_o,
    output logic        h2_rx_crc_err_o,
    output logic [4:0]  h2_tx_credits_avail_o,
    output logic [4:0]  h2_unacked_cnt_o,
    output logic [15:0] h2_tx_frame_cnt_o,
    output logic [15:0] h2_rx_good_cnt_o,
    output logic [15:0] h2_llr_replay_cnt_o,
    output logic [15:0] h2_crc_err_cnt_o,

    // 9. H3: DeepSeek-R1 Top-K MoE & MLA Router Interface
    input  logic        h3_valid_i,
    input  logic        h3_topk_mode_i,
    input  logic        h3_shared_expert_en_i,
    input  logic [7:0]  h3_token_id_i,
    input  logic [31:0] h3_act_mxfp4_i,
    input  logic [7:0]  h3_act_e8m0_i,
    output logic        h3_valid_o,
    output logic        h3_topk_mode_o,
    output logic        h3_shared_expert_active_o,
    output logic [15:0] h3_sel_expert_id_o,
    output logic [19:0] h3_dst_chip_id_o,
    output logic [63:0] h3_gate_weight_q88_o,
    output logic [63:0] h3_sel_expert_score_o,
    output logic [15:0] h3_active_expert_mask_o,
    output logic [15:0] h3_clock_gated_expert_mask_o,
    output logic [4:0]  h3_active_expert_cnt_o,
    output logic [4:0]  h3_gated_expert_cnt_o,
    output logic [15:0] h3_routed_token_cnt_o,
    output logic [31:0] h3_cum_gated_expert_cycles_o
);

    // -------------------------------------------------------------------------
    // 1. M02: 3b/6b CSD Wired MAC Array (VEC_LEN=16, OUT_CHANNELS=8, NUM_OUTLIERS=4)
    // -------------------------------------------------------------------------
    logic [8*16*3-1:0] m02_w_base_3b_bus;
    logic [8*4*6-1:0]  m02_w_out_val_6b_bus;
    logic [8*4*6-1:0]  m02_w_out_idx_6b_bus;
    logic [8*24-1:0]   m02_acc_full;

    always_comb begin
        for (int ch = 0; ch < 8; ch++) begin
            for (int i = 0; i < 16; i++) begin
                m02_w_base_3b_bus[(ch*16 + i)*3 +: 3] = m02_w3b_pat_i[((ch*3 + i) & 15)*3 +: 3];
            end
            for (int k = 0; k < 4; k++) begin
                m02_w_out_val_6b_bus[(ch*4 + k)*6 +: 6] = m02_out_pat_i[((ch + k) & 7)*6 +: 6];
                m02_w_out_idx_6b_bus[(ch*4 + k)*6 +: 6] = 6'((ch + k*4) & 15);
            end
        end
    end

    taalas_3b6b_wired_mac_array #(
        .VEC_LEN      (16),
        .OUT_CHANNELS (8),
        .NUM_OUTLIERS (4)
    ) u_m02_csd_mac (
        .clk              (clk),
        .rst_n            (rst_n),
        .valid_i          (m02_valid_i),
        .act_vec_i        ({m02_act_hi_i, m02_act_lo_i}),
        .w_base_3b_i      (m02_w_base_3b_bus),
        .w_out_val_6b_i   (m02_w_out_val_6b_bus),
        .w_out_idx_6b_i   (m02_w_out_idx_6b_bus),
        .zero_skip_en_i   (m02_zero_skip_en_i),
        .valid_o          (m02_valid_o),
        .acc_out_o        (m02_acc_full),
        .act_sum_o        (m02_act_sum_o),
        .zero_ops_saved_o (m02_zero_ops_saved_o)
    );
    assign m02_acc_lo_o  = m02_acc_full[63:0];
    assign m02_acc_mid_o = m02_acc_full[127:64];
    assign m02_acc_hi_o  = m02_acc_full[191:128];

    // -------------------------------------------------------------------------
    // 2. M03: HC2 OCP MXFP4 MAC Lane (BLOCK_SIZE=16, NUM_LANES=4)
    // -------------------------------------------------------------------------
    logic [4*64-1:0] m03_w_mxfp4_bus;
    logic [4*32-1:0] m03_fp32_full;
    always_comb begin
        for (int l = 0; l < 4; l++) begin
            m03_w_mxfp4_bus[l*64 +: 64] = m03_w_mxfp4_base_i ^ (64'h1111_1111_1111_1111 * 64'(l));
        end
    end

    taalas_mxfp4_hc2_mac_lane #(
        .BLOCK_SIZE (16),
        .NUM_LANES  (4)
    ) u_m03_mxfp4_mac (
        .clk         (clk),
        .rst_n       (rst_n),
        .valid_i     (m03_valid_i),
        .act_mxfp4_i (m03_act_mxfp4_i),
        .act_e8m0_i  (m03_act_e8m0_i),
        .w_mxfp4_i   (m03_w_mxfp4_bus),
        .w_e8m0_i    (m03_w_e8m0_i),
        .valid_o     (m03_valid_o),
        .dot_int16_o (m03_dot_int16_o),
        .exp_comb_o  (m03_exp_comb_o),
        .fp32_out_o  (m03_fp32_full),
        .nan_flag_o  ()
    );
    assign m03_fp32_lo_o = m03_fp32_full[63:0];
    assign m03_fp32_hi_o = m03_fp32_full[127:64];

    // -------------------------------------------------------------------------
    // 3. M04: Per-Group Zero-Point & Scale Dequantizer (OUT_CHANNELS=8)
    // -------------------------------------------------------------------------
    logic [8*24-1:0] m04_raw_acc_bus;
    logic [8*16-1:0] m04_w_scale_bus;
    logic [8*8-1:0]  m04_w_zp_bus;
    logic [8*16-1:0] m04_lora_delta_bus;
    logic [8*16-1:0] m04_dequant_full;

    always_comb begin
        for (int j = 0; j < 8; j++) begin
            m04_raw_acc_bus[j*24 +: 24]    = m04_raw_acc_ch0_i + 24'(j * 64);
            m04_w_scale_bus[j*16 +: 16]    = m04_w_scale_ch0_i + 16'(j * 8);
            m04_w_zp_bus[j*8 +: 8]         = m04_w_zp_ch0_i + 8'(j);
            m04_lora_delta_bus[j*16 +: 16] = m04_lora_delta_ch0_i + 16'(j * 4);
        end
    end

    taalas_group_dequant_scale_unit #(
        .OUT_CHANNELS (8),
        .ACC_WIDTH    (24),
        .SCALE_WIDTH  (16),
        .OUT_WIDTH    (16)
    ) u_m04_dequant (
        .clk           (clk),
        .rst_n         (rst_n),
        .valid_i       (m04_valid_i),
        .first_group_i (m04_first_group_i),
        .last_group_i  (m04_last_group_i),
        .raw_acc_i     (m04_raw_acc_bus),
        .act_sum_i     (m04_act_sum_i),
        .w_scale_i     (m04_w_scale_bus),
        .act_scale_i   (m04_act_scale_i),
        .w_zp_i        (m04_w_zp_bus),
        .lora_delta_i  (m04_lora_delta_bus),
        .lora_en_i     (m04_lora_en_i),
        .valid_o       (m04_valid_o),
        .dequant_out_o (m04_dequant_full),
        .acc_fp32_o    (),
        .sat_flag_o    (m04_sat_flag_o)
    );
    assign m04_dequant_lo_o = m04_dequant_full[63:0];
    assign m04_dequant_hi_o = m04_dequant_full[127:64];

    // -------------------------------------------------------------------------
    // 4. M05: 16-Bank On-Die 6T SECDED SRAM Macro (NUM_BANKS=16, BANK_DEPTH=64)
    // -------------------------------------------------------------------------
    taalas_sram_6t_banked_macro #(
        .NUM_BANKS  (16),
        .BANK_DEPTH (64),
        .DATA_WIDTH (64),
        .ECC_WIDTH  (8),
        .RAW_WIDTH  (72)
    ) u_m05_sram (
        .clk                  (clk),
        .rst_n                (rst_n),
        .ret_sleep_i          (m05_ret_sleep_i),
        .bank_cg_en_i         (m05_bank_cg_en_i),
        .req_valid_i          (m05_req_valid_i),
        .req_we_i             (m05_req_we_i),
        .req_bank_i           (m05_req_bank_i),
        .req_row_i            (m05_req_row_i),
        .req_wdata_i          (m05_req_wdata_i),
        .req_wmask_i          (m05_req_wmask_i),
        .vec_req_valid_i      (m05_vec_req_valid_i),
        .vec_req_row_i        ({m05_vec_row_hi_i, m05_vec_row_lo_i}),
        .bank_conflict_mask_o (),
        .conflict_free_o      (m05_conflict_free_o),
        .err_inj_en_i         (m05_err_inj_en_i),
        .err_inj_mask_i       ({m05_err_inj_hi_i, m05_err_inj_lo_i}),
        .resp_valid_o         (m05_resp_valid_o),
        .resp_rdata_o         (m05_resp_rdata_o),
        .resp_raw_codeword_o  (),
        .phys_bank_o          (m05_phys_bank_o),
        .sec_err_o            (m05_sec_err_o),
        .ded_err_o            (m05_ded_err_o),
        .err_syndrome_o       (m05_err_syndrome_o),
        .sec_err_cnt_o        (m05_sec_cnt_o),
        .ded_err_cnt_o        (m05_ded_cnt_o)
    );

    // -------------------------------------------------------------------------
    // 5. M07: Zero-Stall SRAM LoRA Overlay Engine (IN_DIM=16, OUT_CHANNELS=8, MAX_RANK=8)
    // -------------------------------------------------------------------------
    logic [8*16-1:0] m07_lora_delta_full;
    taalas_lora_sram_overlay_engine #(
        .IN_DIM       (16),
        .OUT_CHANNELS (8),
        .MAX_RANK     (8),
        .MAX_SKEW     (8)
    ) u_m07_lora (
        .clk                 (clk),
        .rst_n               (rst_n),
        .valid_i             (m07_valid_i),
        .lora_en_i           (m07_lora_en_i),
        .active_rank_i       (m07_active_rank_i),
        .alpha_over_r_q8_8_i (m07_alpha_q88_i),
        .skew_delay_i        (m07_skew_delay_i),
        .act_vec_i           ({m07_act_hi_i, m07_act_lo_i}),
        .ext_weights_en_i    (1'b0),
        .lora_a_flat_i       ('0),
        .lora_b_flat_i       ('0),
        .sram_we_i           (m07_sram_we_i),
        .sram_sel_b_i        (m07_sram_sel_b_i),
        .sram_row_addr_i     (m07_sram_row_addr_i),
        .sram_wdata_i        ({m07_sram_wdata_hi_i, m07_sram_wdata_lo_i}),
        .valid_o             (m07_valid_o),
        .latent_h_o          (),
        .lora_delta_o        (m07_lora_delta_full),
        .stall_cycles_o      (m07_stall_cycles_o)
    );
    assign m07_lora_delta_lo_o = m07_lora_delta_full[63:0];
    assign m07_lora_delta_hi_o = m07_lora_delta_full[127:64];

    // -------------------------------------------------------------------------
    // 6. M12: Credit-Based Wormhole Token-Pipe NoC Router (FLIT_WIDTH=128)
    // -------------------------------------------------------------------------
    logic [127:0] m12_loc_rx_flit_full;
    logic [127:0] m12_out_flit_full;
    taalas_token_pipe_noc_router #(
        .FLIT_WIDTH  (128),
        .FIFO_DEPTH  (8),
        .MAX_CREDITS (8),
        .TILE_ID     (2)
    ) u_m12_noc (
        .clk                     (clk),
        .rst_n                   (rst_n),
        .bcast_en_i              (m12_bcast_en_i),
        .c2c_en_i                (m12_c2c_en_i),
        .in_valid_i              (m12_in_valid_i),
        .in_ready_o              (m12_in_ready_o),
        .in_flit_i               ({m12_in_hdr_i, 32'hCAFE_BABE, m12_in_pay_lo_i}),
        .upstream_credit_ret_o   (m12_up_credit_ret_o),
        .local_tx_valid_i        (m12_loc_tx_valid_i),
        .local_tx_ready_o        (m12_loc_tx_ready_o),
        .local_tx_flit_i         ({m12_in_hdr_i, 32'hFACE_FEED, m12_in_pay_lo_i}),
        .local_rx_valid_o        (m12_loc_rx_valid_o),
        .local_rx_ready_i        (m12_loc_rx_ready_i),
        .local_rx_flit_o         (m12_loc_rx_flit_full),
        .out_valid_o             (m12_out_valid_o),
        .out_ready_i             (m12_out_ready_i),
        .out_flit_o              (m12_out_flit_full),
        .downstream_credit_ret_i (m12_dn_credit_ret_i),
        .c2c_tx_valid_o          (m12_c2c_tx_valid_o),
        .c2c_tx_ready_i          (m12_c2c_tx_ready_i),
        .c2c_tx_flit_o           (),
        .c2c_rx_valid_i          (m12_c2c_rx_valid_i),
        .c2c_rx_ready_o          (m12_c2c_rx_ready_o),
        .c2c_rx_flit_i           ({m12_in_hdr_i, 32'hC2C0_BEEF, m12_in_pay_lo_i}),
        .avail_credits_o         (m12_avail_credits_o),
        .inflight_flits_o        (m12_inflight_flits_o),
        .skid_occupancy_o        (m12_skid_occ_o),
        .fifo_occupancy_o        (m12_fifo_occ_o),
        .flits_rx_cnt_o          (m12_rx_cnt_o),
        .flits_tx_cnt_o          (m12_tx_cnt_o),
        .stall_cycles_cnt_o      (m12_stall_cnt_o),
        .crc_err_o               (m12_crc_err_o)
    );
    assign m12_loc_rx_pay_lo_o = m12_loc_rx_flit_full[63:0];
    assign m12_out_pay_lo_o    = m12_out_flit_full[63:0];

    // -------------------------------------------------------------------------
    // 7. M18: Autonomous SECDED Patrol Scrubber, Spare-Row CAM & Droop Monitor
    // -------------------------------------------------------------------------
    logic [71:0] m18_scrub_sram_mem [0:1023];
    logic        m18_scrub_re;
    logic [3:0]  m18_scrub_bank;
    logic [5:0]  m18_scrub_addr;
    logic        m18_scrub_rvalid_q;
    logic [3:0]  m18_scrub_rbank_q;
    logic [5:0]  m18_scrub_raddr_q;
    logic [71:0] m18_scrub_rdata_q;
    logic        m18_scrub_wb_we;
    logic [3:0]  m18_scrub_wb_bank;
    logic [5:0]  m18_scrub_wb_addr;
    logic [71:0] m18_scrub_wb_data;
    logic [7:0]  m18_bist_rom_addr;
    logic [63:0] m18_bist_rom_data;

    assign m18_bist_rom_data = 64'h5441_414C_4153_0000 | {56'd0, m18_bist_rom_addr};

    initial begin
        for (int idx = 0; idx < 1024; idx++) begin
            m18_scrub_sram_mem[idx] = 72'd0;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            m18_scrub_rvalid_q <= 1'b0;
            m18_scrub_rbank_q  <= 4'd0;
            m18_scrub_raddr_q  <= 6'd0;
            m18_scrub_rdata_q  <= 72'd0;
        end else begin
            if (m18_scrub_wb_we) begin
                m18_scrub_sram_mem[{m18_scrub_wb_bank, m18_scrub_wb_addr}] <= m18_scrub_wb_data;
            end else if (m18_seu_inj_en_i) begin
                m18_scrub_sram_mem[{m18_seu_inj_bank_i, m18_seu_inj_addr_i}] <=
                    m18_scrub_sram_mem[{m18_seu_inj_bank_i, m18_seu_inj_addr_i}] ^
                    {m18_seu_inj_mask_hi_i, m18_seu_inj_mask_lo_i};
            end
            m18_scrub_rvalid_q <= m18_scrub_re;
            m18_scrub_rbank_q  <= m18_scrub_bank;
            m18_scrub_raddr_q  <= m18_scrub_addr;
            m18_scrub_rdata_q  <= m18_scrub_sram_mem[{m18_scrub_bank, m18_scrub_addr}];
        end
    end

    taalas_ecc_bist_scrubber #(
        .NUM_BANKS      (16),
        .BANK_DEPTH     (64),
        .DATA_WIDTH     (64),
        .ECC_WIDTH      (8),
        .RAW_WIDTH      (72),
        .ROM_DEPTH      (256),
        .SPARE_ROWS     (8),
        .STRETCH_WINDOW (8),
        .DIDT_THRESH    (64)
    ) u_m18_scrubber (
        .clk                     (clk),
        .rst_n                   (rst_n),
        .active_sram_req_i       (m18_active_req_i),
        .active_sram_bank_i      (m18_active_bank_i),
        .active_sram_addr_i      (m18_active_addr_i),
        .scrub_sram_re_o         (m18_scrub_re),
        .scrub_sram_bank_o       (m18_scrub_bank),
        .scrub_sram_addr_o       (m18_scrub_addr),
        .scrub_sram_rvalid_i     (m18_scrub_rvalid_q),
        .scrub_sram_rbank_i      (m18_scrub_rbank_q),
        .scrub_sram_raddr_i      (m18_scrub_raddr_q),
        .scrub_sram_rdata_i      (m18_scrub_rdata_q),
        .scrub_wb_we_o           (m18_scrub_wb_we),
        .scrub_wb_bank_o         (m18_scrub_wb_bank),
        .scrub_wb_addr_o         (m18_scrub_wb_addr),
        .scrub_wb_data_o         (m18_scrub_wb_data),
        .sbe_scrubbed_cnt_o      (m18_sbe_scrubbed_cnt_o),
        .dbe_detected_cnt_o      (m18_dbe_detected_cnt_o),
        .uncorrectable_dbe_irq_o (m18_uncorrectable_dbe_irq_o),
        .fault_log_reg_o         (),
        .remap_valid_o           (m18_remap_valid_o),
        .remap_src_addr_o        (),
        .remap_dst_row_o         (),
        .active_hit_spare_o      (m18_active_hit_spare_o),
        .active_spare_row_o      (),
        .spare_rows_used_o       (m18_spare_rows_used_o),
        .bist_start_i            (m18_bist_start_i),
        .bist_rom_data_i         (m18_bist_rom_data),
        .expected_crc16_i        (m18_expected_crc16_i),
        .bist_running_o          (),
        .bist_rom_re_o           (),
        .bist_rom_addr_o         (m18_bist_rom_addr),
        .bist_crc16_o            (m18_bist_crc16_o),
        .bist_done_o             (m18_bist_done_o),
        .bist_pass_o             (m18_bist_pass_o),
        .canary_taps_i           (m18_canary_taps_i),
        .mac_active_lanes_i      (m18_mac_active_lanes_i),
        .clk_stretch_en_o        (m18_clk_stretch_en_o),
        .gated_clk_en_o          (m18_gated_clk_en_o),
        .droop_event_cnt_o       (m18_droop_event_cnt_o)
    );

    // -------------------------------------------------------------------------
    // 8. H2: 112G C2C SerDes Link-Layer Retry (LLR) Controller (Loopback Channel)
    // -------------------------------------------------------------------------
    logic        h2_wire_valid;
    logic [87:0] h2_wire_frame;
    logic        h2_wire_cred_ret;
    logic        h2_wire_ack_val;
    logic        h2_wire_ack_nack;
    logic [7:0]  h2_wire_ack_seq;
    logic        h2_wire_valid_q;
    logic [87:0] h2_wire_frame_q;
    logic        h2_wire_err_q;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            h2_wire_valid_q <= 1'b0;
            h2_wire_frame_q <= 88'd0;
            h2_wire_err_q   <= 1'b0;
        end else begin
            h2_wire_valid_q <= h2_wire_valid;
            h2_wire_frame_q <= h2_wire_frame;
            h2_wire_err_q   <= h2_link_err_inj_i && (!h2_replay_active_o);
        end
    end

    taalas_hc2_c2c_llr_serdes_ctrl #(
        .PAYLOAD_W    (64),
        .SEQ_W        (8),
        .CRC_W        (16),
        .REPLAY_DEPTH (16),
        .MAX_CREDITS  (16)
    ) u_h2_c2c_llr (
        .clk                 (clk),
        .rst_n               (rst_n),
        .tx_flit_valid_i     (h2_tx_flit_valid_i),
        .tx_flit_data_i      (h2_tx_flit_data_i),
        .tx_flit_ready_o     (h2_tx_flit_ready_o),
        .rx_flit_valid_o     (h2_rx_flit_valid_o),
        .rx_flit_data_o      (h2_rx_flit_data_o),
        .rx_flit_seq_o       (h2_rx_flit_seq_o),
        .rx_credit_return_i  (h2_rx_flit_valid_o),
        .c2c_tx_valid_o      (h2_wire_valid),
        .c2c_tx_frame_o      (h2_wire_frame),
        .c2c_rx_credit_ret_i (h2_wire_cred_ret),
        .c2c_rx_valid_i      (h2_wire_valid_q),
        .c2c_rx_frame_i      (h2_wire_frame_q),
        .link_err_inj_i      (h2_wire_err_q),
        .c2c_tx_credit_ret_o (h2_wire_cred_ret),
        .c2c_rx_ack_valid_i  (h2_wire_ack_val),
        .c2c_rx_ack_nack_i   (h2_wire_ack_nack),
        .c2c_rx_ack_seq_i    (h2_wire_ack_seq),
        .c2c_tx_ack_valid_o  (h2_wire_ack_val),
        .c2c_tx_ack_nack_o   (h2_wire_ack_nack),
        .c2c_tx_ack_seq_o    (h2_wire_ack_seq),
        .replay_active_o     (h2_replay_active_o),
        .rx_crc_err_o        (h2_rx_crc_err_o),
        .tx_credits_avail_o  (h2_tx_credits_avail_o),
        .unacked_cnt_o       (h2_unacked_cnt_o),
        .tx_frame_cnt_o      (h2_tx_frame_cnt_o),
        .rx_good_cnt_o       (h2_rx_good_cnt_o),
        .llr_replay_cnt_o    (h2_llr_replay_cnt_o),
        .crc_err_cnt_o       (h2_crc_err_cnt_o)
    );

    // -------------------------------------------------------------------------
    // 9. H3: DeepSeek-R1 Top-K MoE & MLA Router (NUM_EXPERTS=16, DIM_GATE=8)
    // -------------------------------------------------------------------------
    logic [16*8*4-1:0] h3_rom_gate_w_mxfp4;
    logic [16*8-1:0]   h3_rom_gate_w_e8m0;
    always_comb begin
        for (int e = 0; e < 16; e++) begin
            h3_rom_gate_w_e8m0[e*8 +: 8] = 8'd127 + 8'(e & 7);
            for (int d = 0; d < 8; d++) begin
                h3_rom_gate_w_mxfp4[(e*8 + d)*4 +: 4] = 4'((e * 3 + d + 1) & 7);
            end
        end
    end

    taalas_hc2_moe_mla_router #(
        .NUM_EXPERTS (16),
        .DIM_GATE    (8),
        .MAX_K       (4),
        .NUM_CHIPS   (4)
    ) u_h3_moe_router (
        .clk                       (clk),
        .rst_n                     (rst_n),
        .valid_i                   (h3_valid_i),
        .topk_mode_i               (h3_topk_mode_i),
        .shared_expert_en_i        (h3_shared_expert_en_i),
        .token_id_i                (h3_token_id_i),
        .act_mxfp4_i               (h3_act_mxfp4_i),
        .act_e8m0_i                (h3_act_e8m0_i),
        .gate_w_mxfp4_i            (h3_rom_gate_w_mxfp4),
        .gate_w_e8m0_i             (h3_rom_gate_w_e8m0),
        .expert_bias_i             ('0),
        .valid_o                   (h3_valid_o),
        .topk_mode_o               (h3_topk_mode_o),
        .shared_expert_active_o    (h3_shared_expert_active_o),
        .sel_expert_id_o           (h3_sel_expert_id_o),
        .dst_chip_id_o             (h3_dst_chip_id_o),
        .gate_weight_q88_o         (h3_gate_weight_q88_o),
        .sel_expert_score_o        (h3_sel_expert_score_o),
        .active_expert_mask_o      (h3_active_expert_mask_o),
        .clock_gated_expert_mask_o (h3_clock_gated_expert_mask_o),
        .active_expert_cnt_o       (h3_active_expert_cnt_o),
        .gated_expert_cnt_o        (h3_gated_expert_cnt_o),
        .routed_token_cnt_o        (h3_routed_token_cnt_o),
        .cum_gated_expert_cycles_o (h3_cum_gated_expert_cycles_o)
    );

endmodule
