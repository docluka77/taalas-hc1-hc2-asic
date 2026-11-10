`timescale 1ns / 1ps
// =============================================================================
// Module:      taalas_uvm_all_modules_top
// Project:     Taalas HC1/HC2 Hardwired LLM Inference ASIC
// Description: Unified Full-Hierarchy Multi-Module UVM Verification Wrapper
//              Instantiating All 14 Subsystem IP Modules (M1..M14) + Full-Chip
//              Top (`taalas_hc1_chip_top`, M15) + SVA Protocol Monitors for
//              Simultaneous Code Coverage, SVA Checking, and Adversarial Audit.
// =============================================================================

module taalas_uvm_all_modules_top (
    input  logic         clk,
    input  logic         rst_n,

    // Global UVM Stimulus Seed & Broadcast Vector Generator
    input  logic [63:0]  stim_seed_lo_i,
    input  logic [63:0]  stim_seed_hi_i,
    input  logic [3:0]   stim_fill_mode_i, // 0=LFSR, 1=ALL_ZERO, 2=ALL_ONES, 3=MAX_POS, 4=MIN_NEG, 5=ALT_AA55

    // M1: Via-Mask ROM Controls & Outputs
    input  logic         m1_sleep_n_i,
    input  logic         m1_sleep_i,
    input  logic         m1_iso_en_i,
    input  logic         m1_cs_en_i,
    input  logic         m1_prech_en_i,
    input  logic         m1_sa_en_i,
    input  logic [1:0]   m1_bank_sel_i,
    input  logic [3:0]   m1_addr_i,
    input  logic         m1_prog_en_i,
    input  logic [1:0]   m1_prog_bank_i,
    input  logic [3:0]   m1_prog_row_i,
    input  logic         m1_bist_start_i,
    output logic         m1_bist_busy_o,
    output logic         m1_bist_done_o,
    output logic [15:0]  m1_bist_crc16_o,
    output logic         m1_bist_pass_o,
    output logic         m1_rvalid_o,
    output logic [9:0]   m1_active_vias_o,
    output logic [63:0]  m1_rdata_lo_o,

    // M2: 3b/6b CSD Wired MAC Controls & Outputs
    input  logic         m2_valid_i,
    input  logic         m2_zero_skip_en_i,
    input  logic [2:0]   m2_force_w3b_i,
    input  logic         m2_use_force_w_i,
    output logic         m2_valid_o,
    output logic signed [23:0] m2_acc_ch0_o,
    output logic signed [15:0] m2_act_sum_o,
    output logic [15:0]  m2_zero_ops_saved_o,

    // M3: HC2 MXFP4 MAC Lane Controls & Outputs
    input  logic         m3_valid_i,
    input  logic [7:0]   m3_act_e8m0_i,
    input  logic [7:0]   m3_w_e8m0_i,
    input  logic [3:0]   m3_force_act_code_i,
    input  logic [3:0]   m3_force_w_code_i,
    input  logic         m3_use_force_code_i,
    output logic         m3_valid_o,
    output logic signed [15:0] m3_dot_l0_o,
    output logic signed [9:0]  m3_exp_l0_o,
    output logic [31:0]  m3_fp32_l0_o,

    // M4: Group Dequantizer & Scale Unit Controls & Outputs
    input  logic         m4_valid_i,
    input  logic         m4_first_grp_i,
    input  logic         m4_last_grp_i,
    input  logic signed [23:0] m4_raw_acc_ch0_i,
    input  logic signed [15:0] m4_act_sum_i,
    input  logic signed [15:0] m4_w_scale_ch0_i,
    input  logic signed [15:0] m4_act_scale_i,
    input  logic signed [7:0]  m4_w_zp_ch0_i,
    input  logic signed [15:0] m4_lora_delta_ch0_i,
    input  logic         m4_lora_en_i,
    output logic         m4_valid_o,
    output logic signed [15:0] m4_deq_ch0_o,
    output logic         m4_sat_flag_o,

    // M5: 16-Bank 6T SECDED SRAM Controls & Outputs
    input  logic         m5_ret_sleep_i,
    input  logic [15:0]  m5_bank_cg_en_i,
    input  logic         m5_req_valid_i,
    input  logic         m5_req_we_i,
    input  logic [3:0]   m5_req_bank_i,
    input  logic [4:0]   m5_req_row_i,
    input  logic [63:0]  m5_req_wdata_i,
    input  logic [7:0]   m5_req_wmask_i,
    input  logic [15:0]  m5_vec_req_valid_i,
    input  logic         m5_err_inj_en_i,
    input  logic [63:0]  m5_err_inj_lo_i,
    input  logic [7:0]   m5_err_inj_hi_i,
    output logic         m5_resp_valid_o,
    output logic [63:0]  m5_resp_rdata_o,
    output logic [3:0]   m5_phys_bank_o,
    output logic         m5_sec_err_o,
    output logic         m5_ded_err_o,
    output logic [7:0]   m5_err_syndrome_o,
    output logic [15:0]  m5_sec_cnt_o,
    output logic [15:0]  m5_ded_cnt_o,
    output logic         m5_conflict_free_o,
    // M6: KV-Cache Manager Controls & Outputs
    input  logic [1:0]   m6_slot_id_i,
    input  logic [2:0]   m6_kv_head_id_i,
    input  logic         m6_append_en_i,
    input  logic         m6_read_seq_en_i,
    input  logic         m6_clear_slot_i,
    input  logic         m6_sliding_win_en_i,
    input  logic [3:0]   m6_sink_tokens_cfg_i,
    input  logic [15:0]  m6_k_scale_i,
    input  logic [15:0]  m6_v_scale_i,
    input  logic [3:0]   m6_k_zp_i,
    input  logic [3:0]   m6_v_zp_i,
    output logic         m6_kv_valid_o,
    output logic         m6_kv_last_o,
    output logic         m6_seq_done_o,
    output logic [2:0]   m6_fsm_state_o,
    output logic [3:0]   m6_wr_ptr_o,
    output logic [3:0]   m6_rd_ptr_o,
    output logic [12:0]  m6_curr_seq_len_o,
    output logic [15:0]  m6_eviction_cnt_o,
    output logic [63:0]  m6_k_deq_lo_o,
    output logic [63:0]  m6_v_deq_lo_o,

    // M7: LoRA SRAM Overlay Engine Controls & Outputs
    input  logic         m7_valid_i,
    input  logic         m7_lora_en_i,
    input  logic [7:0]   m7_active_rank_i,
    input  logic signed [15:0] m7_alpha_q88_i,
    input  logic [2:0]   m7_skew_delay_i,
    input  logic         m7_ext_weights_en_i,
    input  logic         m7_sram_we_i,
    input  logic         m7_sram_sel_b_i,
    input  logic [5:0]   m7_sram_row_addr_i,
    output logic         m7_valid_o,
    output logic signed [15:0] m7_delta_ch0_o,
    output logic signed [23:0] m7_latent_r0_o,
    output logic [15:0]  m7_stall_cycles_o,

    // M8: RoPE CORDIC / LUT Complex Rotation Controls & Outputs
    input  logic         m8_valid_i,
    input  logic         m8_is_key_i,
    input  logic [5:0]   m8_head_id_i,
    input  logic [2:0]   m8_pair_chunk_idx_i,
    input  logic [16:0]  m8_token_pos_i,
    input  logic         m8_ntk_scale_en_i,
    input  logic         m8_bypass_en_i,
    output logic         m8_valid_o,
    output logic signed [15:0] m8_y_re0_o,
    output logic signed [15:0] m8_y_im0_o,
    output logic signed [15:0] m8_cos0_o,
    output logic signed [15:0] m8_sin0_o,
    output logic         m8_zero_pos_id_o,
    output logic [3:0]   m8_sat_cnt_o,

    // M9: Flash-Decode Online Softmax Attention Controls & Outputs
    input  logic         m9_start_seq_i,
    input  logic         m9_kv_valid_i,
    input  logic         m9_kv_last_i,
    input  logic [15:0]  m9_scale_log2e_i,
    input  logic signed [15:0] m9_q_elem_i,
    input  logic signed [15:0] m9_k_elem_i,
    input  logic signed [15:0] m9_v_elem_i,
    output logic         m9_step_valid_o,
    output logic         m9_out_valid_o,
    output logic signed [15:0] m9_attn_h0_d0_o,
    output logic signed [15:0] m9_max_score_h0_o,
    output logic [23:0]  m9_denom_sum_h0_o,

    // M10: RMSNorm Engine Controls & Outputs
    input  logic         m10_start_i,
    input  logic         m10_in_valid_i,
    input  logic [15:0]  m10_eps_q16_i,
    input  logic         m10_ext_gamma_en_i,
    input  logic signed [15:0] m10_x_elem_i,
    input  logic signed [15:0] m10_gamma_elem_i,
    input  logic         m10_use_uniform_x_i,
    output logic         m10_busy_o,
    output logic         m10_out_valid_o,
    output logic         m10_out_last_o,
    output logic         m10_done_o,
    output logic signed [15:0] m10_y_elem0_o,
    output logic [31:0]  m10_var_eps_o,
    output logic [15:0]  m10_inv_rms_o,
    output logic [2:0]   m10_fsm_state_o,

    // M11: SwiGLU FFN Pipe Controls & Outputs
    input  logic         m11_valid_i,
    input  logic         m11_first_grp_i,
    input  logic         m11_last_grp_i,
    input  logic signed [15:0] m11_gate_elem_i,
    input  logic signed [15:0] m11_up_elem_i,
    input  logic [2:0]   m11_w_down_3b_i,
    input  logic         m11_use_uniform_i,
    output logic         m11_silu_valid_o,
    output logic signed [15:0] m11_silu_c0_o,
    output logic         m11_had_valid_o,
    output logic signed [15:0] m11_had_c0_o,
    output logic signed [7:0]  m11_had_int8_c0_o,
    output logic         m11_down_valid_o,
    output logic         m11_down_done_o,
    output logic signed [23:0] m11_down_acc0_o,
    // M12: Token-Pipe NoC Router Controls & Outputs
    input  logic         m12_bcast_en_i,
    input  logic         m12_c2c_en_i,
    input  logic         m12_in_valid_i,
    output logic         m12_in_ready_o,
    input  logic [31:0]  m12_in_hdr_i,
    input  logic [63:0]  m12_in_pay_lo_i,
    output logic         m12_up_credit_ret_o,
    input  logic         m12_loc_tx_valid_i,
    output logic         m12_loc_tx_ready_o,
    output logic         m12_loc_rx_valid_o,
    input  logic         m12_loc_rx_ready_i,
    output logic         m12_out_valid_o,
    input  logic         m12_out_ready_i,
    input  logic         m12_dn_credit_ret_i,
    output logic         m12_c2c_tx_valid_o,
    input  logic         m12_c2c_tx_ready_i,
    input  logic         m12_c2c_rx_valid_i,
    output logic         m12_c2c_rx_ready_o,
    output logic [3:0]   m12_avail_credits_o,
    output logic [3:0]   m12_inflight_flits_o,
    output logic [1:0]   m12_skid_occ_o,
    output logic [3:0]   m12_fifo_occ_o,
    output logic [31:0]  m12_rx_cnt_o,
    output logic [31:0]  m12_tx_cnt_o,
    output logic [31:0]  m12_stall_cnt_o,
    output logic         m12_crc_err_o,

    // M13 & M15: Host AXI4-Lite CSR + Full-Chip Top Controls & Outputs
    input  logic [15:0]  axi_awaddr_i,
    input  logic         axi_awvalid_i,
    output logic         axi_awready_o,
    input  logic [31:0]  axi_wdata_i,
    input  logic [3:0]   axi_wstrb_i,
    input  logic         axi_wvalid_i,
    output logic         axi_wready_o,
    output logic [1:0]   axi_bresp_o,
    output logic         axi_bvalid_o,
    input  logic         axi_bready_i,
    input  logic [15:0]  axi_araddr_i,
    input  logic         axi_arvalid_i,
    output logic         axi_arready_o,
    output logic [31:0]  axi_rdata_o,
    output logic [1:0]   axi_rresp_o,
    output logic         axi_rvalid_o,
    input  logic         axi_rready_i,

    // M13 Standalone Extra Ports
    input  logic         m13_tok_in_ready_i,
    output logic         m13_tok_in_valid_o,
    output logic [19:0]  m13_tok_in_id_o,
    input  logic         m13_tok_out_valid_i,
    output logic         m13_tok_out_ready_o,
    input  logic [19:0]  m13_tok_out_id_i,
    output logic         m13_dma_busy_o,
    output logic         m13_dma_done_o,

    // M14 Standalone Layer Tile Controls & Outputs
    input  logic         m14_tile_cg_en_i,
    input  logic         m14_rom_sleep_en_i,
    input  logic         m14_hc2_mode_i,
    input  logic         m14_zero_skip_en_i,
    input  logic         m14_lora_en_i,
    input  logic [7:0]   m14_lora_rank_i,
    input  logic signed [15:0] m14_lora_alpha_i,
    input  logic         m14_ntk_rope_en_i,
    input  logic         m14_bcast_en_i,
    input  logic [2:0]   m14_slot_id_i,
    input  logic [11:0]  m14_token_pos_i,
    input  logic         m14_kv_clear_i,
    input  logic         m14_dma_we_i,
    input  logic [7:0]   m14_dma_layer_i,
    input  logic [11:0]  m14_dma_row_i,
    input  logic         m14_noc_in_valid_i,
    output logic         m14_noc_in_ready_o,
    input  logic [31:0]  m14_noc_in_hdr_i,
    input  logic         m14_noc_out_ready_i,
    output logic         m14_noc_out_valid_o,
    input  logic         m14_noc_dn_credit_i,
    output logic         m14_tile_busy_o,
    output logic         m14_tile_done_o,
    output logic [3:0]   m14_tile_fsm_o,

    // M15 Full-Chip Top Extra C2C & Telemetry Ports
    input  logic         m15_c2c_ext_en_i,
    output logic         m15_c2c_tx_valid_o,
    input  logic         m15_c2c_tx_ready_i,
    input  logic         m15_c2c_rx_valid_i,
    output logic         m15_c2c_rx_ready_o,
    output logic [31:0]  m15_chip_id_o,
    output logic         m15_chip_busy_o,
    output logic [31:0]  m15_active_tiles_o,
    output logic [31:0]  m15_cg_tiles_o,
    output logic [19:0]  m15_last_token_o,
    output logic         m15_token_pulse_o,
    output logic [63:0]  m15_perf_cycles_o,
    output logic [31:0]  m15_perf_tokens_o,
    output logic [31:0]  m15_perf_rom_o,
    output logic [31:0]  m15_perf_zskip_o,
    output logic [31:0]  sva_total_checks_o,
    output logic [15:0]  sva_total_violations_o
);
    import taalas_uvm_pkg::*;

    // -------------------------------------------------------------------------
    // Wide Stimulus Bus Generator (Toggle-Complete & Corner-Case Aware)
    // -------------------------------------------------------------------------
    logic [511:0] stim_wide_512;
    always_comb begin
        unique case (stim_fill_mode_i)
            4'd1: stim_wide_512 = '0;
            4'd2: stim_wide_512 = '1;
            4'd3: stim_wide_512 = {32{16'h7FFF}};
            4'd4: stim_wide_512 = {32{16'h8000}};
            4'd5: stim_wide_512 = {16{32'hAAAA_5555}};
            4'd6: stim_wide_512 = {16{32'h5555_AAAA}};
            default: begin
                for (int w = 0; w < 4; w++) begin
                    stim_wide_512[w*128 +: 128] = {
                        stim_seed_hi_i ^ (64'h9E37_79B9_7F4A_7C15 * 64'(w)),
                        stim_seed_lo_i ^ (64'hBF58_476D_1CE4_E5B9 * 64'(w + 1))
                    };
                end
            end
        endcase
    end

    // -------------------------------------------------------------------------
    // M1: Via-Mask ROM Macro Instance
    // -------------------------------------------------------------------------
    logic [511:0] m1_rdata_full;
    taalas_via_mask_rom_macro #(
        .NUM_BANKS     (4),
        .ROWS          (16),
        .COLS          (512),
        .COLS_3B       (64),
        .OUTLIER_SLOTS (8)
    ) u_m1_rom (
        .clk                (clk),
        .rst_n              (rst_n),
        .sleep_n            (m1_sleep_n_i),
        .sleep_i            (m1_sleep_i),
        .iso_en_i           (m1_iso_en_i),
        .cs_en              (m1_cs_en_i),
        .precharge_en       (m1_prech_en_i),
        .sa_en              (m1_sa_en_i),
        .bank_sel_i         (m1_bank_sel_i),
        .addr_i             (m1_addr_i),
        .prog_en_i          (m1_prog_en_i),
        .prog_bank_i        (m1_prog_bank_i),
        .prog_row_i         (m1_prog_row_i),
        .prog_wdata_i       (stim_wide_512),
        .bist_start_i       (m1_bist_start_i),
        .bist_busy_o        (m1_bist_busy_o),
        .bist_done_o        (m1_bist_done_o),
        .bist_crc16_o       (m1_bist_crc16_o),
        .bist_pass_o        (m1_bist_pass_o),
        .rdata_o            (m1_rdata_full),
        .weights_3b_o       (),
        .outlier_idx_o      (),
        .outlier_val6b_o    (),
        .group_scale_fp16_o (),
        .group_zp_int8_o    (),
        .rvalid_o           (m1_rvalid_o),
        .active_vias_o      (m1_active_vias_o),
        .bank_active_o      (),
        .bl_precharged_o    ()
    );
    assign m1_rdata_lo_o = m1_rdata_full[63:0];

    // -------------------------------------------------------------------------
    // M2: 3b/6b CSD Wired MAC Array Instance
    // -------------------------------------------------------------------------
    logic [4*24-1:0]  m2_acc_full;
    logic [4*16*3-1:0] m2_w3b_bus;
    assign m2_w3b_bus = m2_use_force_w_i ? {64{m2_force_w3b_i}} : stim_wide_512[191:0];

    taalas_3b6b_wired_mac_array #(
        .VEC_LEN      (16),
        .OUT_CHANNELS (4),
        .NUM_OUTLIERS (4)
    ) u_m2_csd_mac (
        .clk              (clk),
        .rst_n            (rst_n),
        .valid_i          (m2_valid_i),
        .act_vec_i        (stim_wide_512[127:0]),
        .w_base_3b_i      (m2_w3b_bus),
        .w_out_val_6b_i   (stim_wide_512[287:192]),
        .w_out_idx_6b_i   (stim_wide_512[383:288]),
        .zero_skip_en_i   (m2_zero_skip_en_i),
        .valid_o          (m2_valid_o),
        .acc_out_o        (m2_acc_full),
        .act_sum_o        (m2_act_sum_o),
        .zero_ops_saved_o (m2_zero_ops_saved_o)
    );
    assign m2_acc_ch0_o = $signed(m2_acc_full[23:0]);
    // -------------------------------------------------------------------------
    // M3: HC2 OCP MXFP4 MAC Lane Instance
    // -------------------------------------------------------------------------
    logic [63:0]     m3_act_bus;
    logic [4*64-1:0] m3_w_bus;
    logic [4*16-1:0] m3_dot_full;
    logic [4*10-1:0] m3_exp_full;
    logic [4*32-1:0] m3_fp32_full;

    assign m3_act_bus = m3_use_force_code_i ? {16{m3_force_act_code_i}} : stim_wide_512[63:0];
    assign m3_w_bus   = m3_use_force_code_i ? {64{m3_force_w_code_i}}   : stim_wide_512[255:0];

    taalas_mxfp4_hc2_mac_lane #(
        .BLOCK_SIZE (16),
        .NUM_LANES  (4)
    ) u_m3_mxfp4_mac (
        .clk         (clk),
        .rst_n       (rst_n),
        .valid_i     (m3_valid_i),
        .act_mxfp4_i (m3_act_bus),
        .act_e8m0_i  (m3_act_e8m0_i),
        .w_mxfp4_i   (m3_w_bus),
        .w_e8m0_i    ({4{m3_w_e8m0_i}}),
        .valid_o     (m3_valid_o),
        .dot_int16_o (m3_dot_full),
        .exp_comb_o  (m3_exp_full),
        .fp32_out_o  (m3_fp32_full)
    );
    assign m3_dot_l0_o  = $signed(m3_dot_full[15:0]);
    assign m3_exp_l0_o  = $signed(m3_exp_full[9:0]);
    assign m3_fp32_l0_o = m3_fp32_full[31:0];

    // -------------------------------------------------------------------------
    // M4: Per-Group Zero-Point & Scale Dequantizer Instance
    // -------------------------------------------------------------------------
    logic [4*16-1:0] m4_deq_full;
    taalas_group_dequant_scale_unit #(
        .OUT_CHANNELS (4),
        .ACC_WIDTH    (24),
        .SCALE_WIDTH  (16),
        .OUT_WIDTH    (16)
    ) u_m4_dequant (
        .clk           (clk),
        .rst_n         (rst_n),
        .valid_i       (m4_valid_i),
        .first_group_i (m4_first_grp_i),
        .last_group_i  (m4_last_grp_i),
        .raw_acc_i     ({stim_wide_512[71:0], m4_raw_acc_ch0_i}),
        .act_sum_i     (m4_act_sum_i),
        .w_scale_i     ({stim_wide_512[119:72], m4_w_scale_ch0_i}),
        .act_scale_i   (m4_act_scale_i),
        .w_zp_i        ({stim_wide_512[143:120], m4_w_zp_ch0_i}),
        .lora_delta_i  ({stim_wide_512[191:144], m4_lora_delta_ch0_i}),
        .lora_en_i     (m4_lora_en_i),
        .valid_o       (m4_valid_o),
        .dequant_out_o (m4_deq_full),
        .acc_fp32_o    (),
        .sat_flag_o    (m4_sat_flag_o)
    );
    assign m4_deq_ch0_o = $signed(m4_deq_full[15:0]);

    // -------------------------------------------------------------------------
    // M5: 16-Bank On-Die 6T SECDED SRAM Macro Instance
    // -------------------------------------------------------------------------
    taalas_sram_6t_banked_macro #(
        .NUM_BANKS  (16),
        .BANK_DEPTH (32),
        .DATA_WIDTH (64),
        .ECC_WIDTH  (8),
        .RAW_WIDTH  (72)
    ) u_m5_sram (
        .clk                  (clk),
        .rst_n                (rst_n),
        .ret_sleep_i          (m5_ret_sleep_i),
        .bank_cg_en_i         (m5_bank_cg_en_i),
        .req_valid_i          (m5_req_valid_i),
        .req_we_i             (m5_req_we_i),
        .req_bank_i           (m5_req_bank_i),
        .req_row_i            (m5_req_row_i),
        .req_wdata_i          (m5_req_wdata_i),
        .req_wmask_i          (m5_req_wmask_i),
        .vec_req_valid_i      (m5_vec_req_valid_i),
        .vec_req_row_i        (stim_wide_512[127:0]),
        .bank_conflict_mask_o (),
        .conflict_free_o      (m5_conflict_free_o),
        .err_inj_en_i         (m5_err_inj_en_i),
        .err_inj_mask_i       ({m5_err_inj_hi_i, m5_err_inj_lo_i}),
        .resp_valid_o         (m5_resp_valid_o),
        .resp_rdata_o         (m5_resp_rdata_o),
        .resp_raw_codeword_o  (),
        .phys_bank_o          (m5_phys_bank_o),
        .sec_err_o            (m5_sec_err_o),
        .ded_err_o            (m5_ded_err_o),
        .err_syndrome_o       (m5_err_syndrome_o),
        .sec_err_cnt_o        (m5_sec_cnt_o),
        .ded_err_cnt_o        (m5_ded_cnt_o)
    );
    // -------------------------------------------------------------------------
    // M6: GQA 4:1 KV-Cache Manager Instance
    // -------------------------------------------------------------------------
    logic [127:0] m6_k_deq_full, m6_v_deq_full;
    taalas_kv_cache_manager #(
        .MAX_USERS    (4),
        .MAX_SEQ_LEN  (16),
        .NUM_KV_HEADS (8),
        .GQA_RATIO    (4),
        .HEAD_DIM     (16)
    ) u_m6_kv_cache (
        .clk                (clk),
        .rst_n              (rst_n),
        .slot_id_i          (m6_slot_id_i),
        .kv_head_id_i       (m6_kv_head_id_i),
        .append_en_i        (m6_append_en_i),
        .read_seq_en_i      (m6_read_seq_en_i),
        .clear_slot_i       (m6_clear_slot_i),
        .sliding_win_en_i   (m6_sliding_win_en_i),
        .sink_tokens_cfg_i  (m6_sink_tokens_cfg_i),
        .k_vec_in_i         (stim_wide_512[63:0]),
        .v_vec_in_i         (stim_wide_512[127:64]),
        .k_scale_in_i       (m6_k_scale_i),
        .v_scale_in_i       (m6_v_scale_i),
        .k_zp_in_i          (m6_k_zp_i),
        .v_zp_in_i          (m6_v_zp_i),
        .sram_req_valid_o   (),
        .sram_req_we_o      (),
        .sram_req_bank_o    (),
        .sram_req_row_o     (),
        .sram_req_wdata_o   (),
        .k_dequant_o        (m6_k_deq_full),
        .v_dequant_o        (m6_v_deq_full),
        .gqa_k_bcast_o      (),
        .gqa_v_bcast_o      (),
        .wr_ptr_o           (m6_wr_ptr_o),
        .rd_ptr_o           (m6_rd_ptr_o),
        .seq_pos_o          (),
        .curr_seq_len_o     (m6_curr_seq_len_o),
        .slot_active_mask_o (),
        .eviction_cnt_o     (m6_eviction_cnt_o),
        .kv_valid_o         (m6_kv_valid_o),
        .kv_last_o          (m6_kv_last_o),
        .seq_done_o         (m6_seq_done_o),
        .fsm_state_o        (m6_fsm_state_o)
    );
    assign m6_k_deq_lo_o = m6_k_deq_full[63:0];
    assign m6_v_deq_lo_o = m6_v_deq_full[63:0];

    // -------------------------------------------------------------------------
    // M7: Zero-Stall SRAM-Backed LoRA Overlay Engine Instance
    // -------------------------------------------------------------------------
    logic [8*24-1:0] m7_latent_full;
    logic [4*16-1:0] m7_delta_full;
    taalas_lora_sram_overlay_engine #(
        .IN_DIM       (16),
        .OUT_CHANNELS (4),
        .MAX_RANK     (8),
        .MAX_SKEW     (8)
    ) u_m7_lora (
        .clk                 (clk),
        .rst_n               (rst_n),
        .valid_i             (m7_valid_i),
        .lora_en_i           (m7_lora_en_i),
        .active_rank_i       (m7_active_rank_i),
        .alpha_over_r_q8_8_i (m7_alpha_q88_i),
        .skew_delay_i        (m7_skew_delay_i),
        .act_vec_i           (stim_wide_512[127:0]),
        .ext_weights_en_i    (m7_ext_weights_en_i),
        .lora_a_flat_i       ({2{stim_wide_512}}),
        .lora_b_flat_i       (stim_wide_512[255:0]),
        .sram_we_i           (m7_sram_we_i),
        .sram_sel_b_i        (m7_sram_sel_b_i),
        .sram_row_addr_i     (m7_sram_row_addr_i),
        .sram_wdata_i        (stim_wide_512[127:0]),
        .valid_o             (m7_valid_o),
        .latent_h_o          (m7_latent_full),
        .lora_delta_o        (m7_delta_full),
        .stall_cycles_o      (m7_stall_cycles_o)
    );
    assign m7_delta_ch0_o = $signed(m7_delta_full[15:0]);
    assign m7_latent_r0_o = $signed(m7_latent_full[23:0]);

    // -------------------------------------------------------------------------
    // M8: Llama-3.1 Frequency-Scaled RoPE Complex Rotator Instance
    // -------------------------------------------------------------------------
    logic [255:0] m8_vec_out_full;
    logic [127:0] m8_cos_full, m8_sin_full;
    taalas_rope_cordic_unit #(
        .HEAD_DIM        (64),
        .PAIR_LANES      (8),
        .DATA_W          (16),
        .TRIG_W          (16),
        .THETA_BASE      (500000),
        .SCALE_FACTOR_X8 (8)
    ) u_m8_rope (
        .clk                 (clk),
        .rst_n               (rst_n),
        .valid_i             (m8_valid_i),
        .is_key_i            (m8_is_key_i),
        .head_id_i           (m8_head_id_i),
        .pair_chunk_idx_i    (m8_pair_chunk_idx_i),
        .token_pos_i         (m8_token_pos_i),
        .ntk_scale_en_i      (m8_ntk_scale_en_i),
        .bypass_en_i         (m8_bypass_en_i),
        .vec_in_i            (stim_wide_512[255:0]),
        .valid_o             (m8_valid_o),
        .is_key_o            (),
        .head_id_o           (),
        .pair_chunk_idx_o    (),
        .vec_out_o           (m8_vec_out_full),
        .cos_monitor_o       (m8_cos_full),
        .sin_monitor_o       (m8_sin_full),
        .zero_pos_identity_o (m8_zero_pos_id_o),
        .sat_count_o         (m8_sat_cnt_o)
    );
    assign m8_y_re0_o = $signed(m8_vec_out_full[15:0]);
    assign m8_y_im0_o = $signed(m8_vec_out_full[31:16]);
    assign m8_cos0_o  = $signed(m8_cos_full[15:0]);
    assign m8_sin0_o  = $signed(m8_sin_full[15:0]);
    // -------------------------------------------------------------------------
    // M9: Streaming Single-Pass Online Softmax Flash-Decode Attention Instance
    // -------------------------------------------------------------------------
    logic [1023:0] m9_attn_full;
    logic [63:0]   m9_max_full;
    logic [95:0]   m9_denom_full;

    taalas_flash_decode_attention #(
        .HEAD_DIM  (16),
        .GQA_RATIO (4),
        .DATA_W    (16)
    ) u_m9_flash_attn (
        .clk                (clk),
        .rst_n              (rst_n),
        .start_seq_i        (m9_start_seq_i),
        .kv_valid_i         (m9_kv_valid_i),
        .kv_last_i          (m9_kv_last_i),
        .q_heads_i          ({64{m9_q_elem_i}}),
        .k_shared_i         ({16{m9_k_elem_i}}),
        .v_shared_i         ({16{m9_v_elem_i}}),
        .scale_log2e_q8_8_i (m9_scale_log2e_i),
        .step_valid_o       (m9_step_valid_o),
        .out_valid_o        (m9_out_valid_o),
        .attn_out_o         (m9_attn_full),
        .max_score_o        (m9_max_full),
        .denom_sum_o        (m9_denom_full)
    );
    assign m9_attn_h0_d0_o   = $signed(m9_attn_full[15:0]);
    assign m9_max_score_h0_o = $signed(m9_max_full[15:0]);
    assign m9_denom_sum_h0_o = m9_denom_full[23:0];

    // -------------------------------------------------------------------------
    // M10: Fast Newton-Raphson RMSNorm Engine Instance
    // -------------------------------------------------------------------------
    logic [255:0] m10_x_bus, m10_y_full;
    assign m10_x_bus = m10_use_uniform_x_i ? {16{m10_x_elem_i}} : stim_wide_512[255:0];

    taalas_rmsnorm_engine #(
        .HIDDEN_DIM  (64),
        .VEC_W       (16),
        .DATA_W      (16),
        .EPS_DEFAULT (4)
    ) u_m10_rmsnorm (
        .clk            (clk),
        .rst_n          (rst_n),
        .start_i        (m10_start_i),
        .in_valid_i     (m10_in_valid_i),
        .x_vec_i        (m10_x_bus),
        .eps_q16_i      (m10_eps_q16_i),
        .ext_gamma_en_i (m10_ext_gamma_en_i),
        .gamma_vec_i    ({16{m10_gamma_elem_i}}),
        .busy_o         (m10_busy_o),
        .out_valid_o    (m10_out_valid_o),
        .out_last_o     (m10_out_last_o),
        .done_o         (m10_done_o),
        .y_vec_o        (m10_y_full),
        .var_eps_o      (m10_var_eps_o),
        .inv_rms_q8_8_o (m10_inv_rms_o),
        .fsm_state_o    (m10_fsm_state_o)
    );
    assign m10_y_elem0_o = $signed(m10_y_full[15:0]);

    // -------------------------------------------------------------------------
    // M11: Fused SwiGLU Feed-Forward Network Pipe Instance
    // -------------------------------------------------------------------------
    logic [255:0] m11_gate_bus, m11_up_bus, m11_silu_full, m11_had_full;
    logic [127:0] m11_had_int8_full;
    logic [4*24-1:0] m11_down_full;

    assign m11_gate_bus = m11_use_uniform_i ? {16{m11_gate_elem_i}} : stim_wide_512[255:0];
    assign m11_up_bus   = m11_use_uniform_i ? {16{m11_up_elem_i}}   : stim_wide_512[511:256];

    taalas_swiglu_ffn_pipe #(
        .CHANNELS    (16),
        .DOWN_OUT_CH (4),
        .DATA_W      (16)
    ) u_m11_swiglu (
        .clk              (clk),
        .rst_n            (rst_n),
        .valid_i          (m11_valid_i),
        .first_ffn_grp_i  (m11_first_grp_i),
        .last_ffn_grp_i   (m11_last_grp_i),
        .gate_vec_i       (m11_gate_bus),
        .up_vec_i         (m11_up_bus),
        .w_down_3b_i      (m11_use_uniform_i ? {64{m11_w_down_3b_i}} : stim_wide_512[191:0]),
        .silu_valid_o     (m11_silu_valid_o),
        .silu_vec_o       (m11_silu_full),
        .hadamard_valid_o (m11_had_valid_o),
        .hadamard_vec_o   (m11_had_full),
        .hadamard_int8_o  (m11_had_int8_full),
        .down_valid_o     (m11_down_valid_o),
        .down_done_o      (m11_down_done_o),
        .down_acc_o       (m11_down_full)
    );
    assign m11_silu_c0_o     = $signed(m11_silu_full[15:0]);
    assign m11_had_c0_o      = $signed(m11_had_full[15:0]);
    assign m11_had_int8_c0_o = $signed(m11_had_int8_full[7:0]);
    assign m11_down_acc0_o   = $signed(m11_down_full[23:0]);
    // -------------------------------------------------------------------------
    // M12: Credit-Based Wormhole Token-Pipe NoC Router Instance
    // -------------------------------------------------------------------------
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
        .in_flit_i               ({m12_in_hdr_i, stim_wide_512[95:64], m12_in_pay_lo_i}),
        .upstream_credit_ret_o   (m12_up_credit_ret_o),
        .local_tx_valid_i        (m12_loc_tx_valid_i),
        .local_tx_ready_o        (m12_loc_tx_ready_o),
        .local_tx_flit_i         ({m12_in_hdr_i, stim_wide_512[95:0]}),
        .local_rx_valid_o        (m12_loc_rx_valid_o),
        .local_rx_ready_i        (m12_loc_rx_ready_i),
        .local_rx_flit_o         (),
        .out_valid_o             (m12_out_valid_o),
        .out_ready_i             (m12_out_ready_i),
        .out_flit_o              (),
        .downstream_credit_ret_i (m12_dn_credit_ret_i),
        .c2c_tx_valid_o          (m12_c2c_tx_valid_o),
        .c2c_tx_ready_i          (m12_c2c_tx_ready_i),
        .c2c_tx_flit_o           (),
        .c2c_rx_valid_i          (m12_c2c_rx_valid_i),
        .c2c_rx_ready_o          (m12_c2c_rx_ready_o),
        .c2c_rx_flit_i           ({m12_in_hdr_i, stim_wide_512[95:0]}),
        .avail_credits_o         (m12_avail_credits_o),
        .inflight_flits_o        (m12_inflight_flits_o),
        .skid_occupancy_o        (m12_skid_occ_o),
        .fifo_occupancy_o        (m12_fifo_occ_o),
        .flits_rx_cnt_o          (m12_rx_cnt_o),
        .flits_tx_cnt_o          (m12_tx_cnt_o),
        .stall_cycles_cnt_o      (m12_stall_cnt_o),
        .crc_err_o               (m12_crc_err_o)
    );

    // -------------------------------------------------------------------------
    // M13: Standalone Host PCIe / AXI4-Lite CSR & DMA Controller Instance
    // -------------------------------------------------------------------------
    taalas_pcie_csr_ctrl #(
        .ADDR_WIDTH       (16),
        .DATA_WIDTH       (32),
        .TOKEN_FIFO_DEPTH (8),
        .CHIP_ID_VAL      (32'h5441_0100)
    ) u_m13_csr (
        .clk                   (clk),
        .rst_n                 (rst_n),
        .s_axi_awaddr          (axi_awaddr_i),
        .s_axi_awvalid         (axi_awvalid_i),
        .s_axi_awready         (),
        .s_axi_wdata           (axi_wdata_i),
        .s_axi_wstrb           (axi_wstrb_i),
        .s_axi_wvalid          (axi_wvalid_i),
        .s_axi_wready          (),
        .s_axi_bresp           (),
        .s_axi_bvalid          (),
        .s_axi_bready          (axi_bready_i),
        .s_axi_araddr          (axi_araddr_i),
        .s_axi_arvalid         (axi_arvalid_i),
        .s_axi_arready         (),
        .s_axi_rdata           (),
        .s_axi_rresp           (),
        .s_axi_rvalid          (),
        .s_axi_rready          (axi_rready_i),
        .chip_id_o             (),
        .chip_en_o             (),
        .soft_rst_o            (),
        .lora_en_o             (),
        .hc2_mxfp4_mode_o      (),
        .zero_skip_en_o        (),
        .rom_sleep_en_o        (),
        .ntk_rope_en_o         (),
        .bcast_en_o            (),
        .layer_cg_mask_o       (),
        .slot_id_o             (),
        .token_pos_o           (),
        .kv_clear_slot_o       (),
        .lora_rank_o           (),
        .lora_alpha_q8_8_o     (),
        .dma_src_addr_o        (),
        .dma_dst_sram_addr_o   (),
        .dma_len_o             (),
        .dma_start_o           (),
        .dma_busy_o            (m13_dma_busy_o),
        .dma_done_o            (m13_dma_done_o),
        .dma_sram_we_o         (),
        .dma_sram_layer_o      (),
        .dma_sram_row_o        (),
        .dma_sram_wdata_o      (),
        .tok_in_valid_o        (m13_tok_in_valid_o),
        .tok_in_ready_i        (m13_tok_in_ready_i),
        .tok_in_id_o           (m13_tok_in_id_o),
        .tok_out_valid_i       (m13_tok_out_valid_i),
        .tok_out_ready_o       (m13_tok_out_ready_o),
        .tok_out_id_i          (m13_tok_out_id_i),
        .tiles_busy_mask_i     (stim_wide_512[31:0]),
        .inc_rom_reads_i       (stim_wide_512[47:32]),
        .inc_sram_conflicts_i  (stim_wide_512[55:48]),
        .inc_ecc_sec_i         (stim_wide_512[63:56]),
        .inc_ecc_ded_i         (stim_wide_512[71:64]),
        .inc_zero_skip_i       (stim_wide_512[87:72]),
        .inc_noc_stall_i       (stim_wide_512[95:88]),
        .perf_cycle_cnt_o      (),
        .perf_token_cnt_o      (),
        .perf_rom_reads_o      (),
        .perf_sram_conflicts_o (),
        .perf_ecc_sec_cnt_o    (),
        .perf_zero_skip_cnt_o  ()
    );
    // -------------------------------------------------------------------------
    // M14: Complete Hardwired Transformer Layer Tile Instance
    // -------------------------------------------------------------------------
    taalas_hc1_layer_tile #(
        .TILE_ID        (1),
        .FLIT_WIDTH     (128),
        .HIDDEN_DIM     (16),
        .HEAD_DIM       (16),
        .GQA_RATIO      (4),
        .HC2_MXFP4_MODE (1'b0)
    ) u_m14_tile (
        .clk                 (clk),
        .rst_n               (rst_n),
        .tile_cg_en_i        (m14_tile_cg_en_i),
        .rom_sleep_en_i      (m14_rom_sleep_en_i),
        .hc2_mxfp4_mode_i    (m14_hc2_mode_i),
        .zero_skip_en_i      (m14_zero_skip_en_i),
        .lora_en_i           (m14_lora_en_i),
        .lora_rank_i         (m14_lora_rank_i),
        .lora_alpha_q8_8_i   (m14_lora_alpha_i),
        .ntk_rope_en_i       (m14_ntk_rope_en_i),
        .bcast_en_i          (m14_bcast_en_i),
        .slot_id_i           (m14_slot_id_i),
        .token_pos_i         (m14_token_pos_i),
        .kv_clear_slot_i     (m14_kv_clear_i),
        .dma_sram_we_i       (m14_dma_we_i),
        .dma_sram_layer_i    (m14_dma_layer_i),
        .dma_sram_row_i      (m14_dma_row_i),
        .dma_sram_wdata_i    (stim_wide_512[63:0]),
        .noc_in_valid_i      (m14_noc_in_valid_i),
        .noc_in_ready_o      (m14_noc_in_ready_o),
        .noc_in_flit_i       ({m14_noc_in_hdr_i, stim_wide_512[95:0]}),
        .noc_up_credit_ret_o (),
        .noc_out_valid_o     (m14_noc_out_valid_o),
        .noc_out_ready_i     (m14_noc_out_ready_i),
        .noc_out_flit_o      (),
        .noc_dn_credit_ret_i (m14_noc_dn_credit_i),
        .tile_busy_o         (m14_tile_busy_o),
        .tile_done_pulse_o   (m14_tile_done_o),
        .tile_fsm_state_o    (m14_tile_fsm_o),
        .layer_out_vec_o     (),
        .rom_reads_inc_o     (),
        .sram_conflict_inc_o (),
        .ecc_sec_pulse_o     (),
        .ecc_ded_pulse_o     (),
        .zero_skip_inc_o     (),
        .noc_stall_pulse_o   ()
    );

    // -------------------------------------------------------------------------
    // M15: Full-Chip Top-Level ASIC Hierarchy Instance (4-Layer Daisy Chain)
    // -------------------------------------------------------------------------
    taalas_hc1_chip_top #(
        .NUM_LAYERS_PARAM (4),
        .FLIT_WIDTH       (128),
        .HIDDEN_DIM       (16),
        .HEAD_DIM         (16),
        .GQA_RATIO        (4),
        .HC2_MXFP4_MODE   (1'b0)
    ) u_m15_chip_top (
        .clk                     (clk),
        .rst_n                   (rst_n),
        .s_axi_awaddr            (axi_awaddr_i),
        .s_axi_awvalid           (axi_awvalid_i),
        .s_axi_awready           (axi_awready_o),
        .s_axi_wdata             (axi_wdata_i),
        .s_axi_wstrb             (axi_wstrb_i),
        .s_axi_wvalid            (axi_wvalid_i),
        .s_axi_wready            (axi_wready_o),
        .s_axi_bresp             (axi_bresp_o),
        .s_axi_bvalid            (axi_bvalid_o),
        .s_axi_bready            (axi_bready_i),
        .s_axi_araddr            (axi_araddr_i),
        .s_axi_arvalid           (axi_arvalid_i),
        .s_axi_arready           (axi_arready_o),
        .s_axi_rdata             (axi_rdata_o),
        .s_axi_rresp             (axi_rresp_o),
        .s_axi_rvalid            (axi_rvalid_o),
        .s_axi_rready            (axi_rready_i),
        .c2c_ext_en_i            (m15_c2c_ext_en_i),
        .c2c_tx_valid_o          (m15_c2c_tx_valid_o),
        .c2c_tx_ready_i          (m15_c2c_tx_ready_i),
        .c2c_tx_flit_o           (),
        .c2c_rx_valid_i          (m15_c2c_rx_valid_i),
        .c2c_rx_ready_o          (m15_c2c_rx_ready_o),
        .c2c_rx_flit_i           ({m14_noc_in_hdr_i, stim_wide_512[95:0]}),
        .chip_id_o               (m15_chip_id_o),
        .chip_busy_o             (m15_chip_busy_o),
        .active_tile_mask_o      (m15_active_tiles_o),
        .clock_gated_tile_mask_o (m15_cg_tiles_o),
        .last_sampled_token_o    (m15_last_token_o),
        .token_sampled_pulse_o   (m15_token_pulse_o),
        .perf_cycle_cnt_o        (m15_perf_cycles_o),
        .perf_token_cnt_o        (m15_perf_tokens_o),
        .perf_rom_reads_o        (m15_perf_rom_o),
        .perf_zero_skip_cnt_o    (m15_perf_zskip_o)
    );

    // -------------------------------------------------------------------------
    // Concurrent UVM SVA Protocol Monitors
    // -------------------------------------------------------------------------
    logic [31:0] sva_axi_checks, sva_noc_checks;
    taalas_uvm_axi_sva_mon u_axi_sva (
        .clk(clk), .rst_n(rst_n),
        .awvalid(axi_awvalid_i), .awready(axi_awready_o),
        .wvalid(axi_wvalid_i),   .wready(axi_wready_o),
        .bvalid(axi_bvalid_o),   .bready(axi_bready_i), .bresp(axi_bresp_o),
        .arvalid(axi_arvalid_i), .arready(axi_arready_o),
        .rvalid(axi_rvalid_o),   .rready(axi_rready_i), .rresp(axi_rresp_o),
        .sva_axi_checks_o(sva_axi_checks), .sva_axi_violations_o(sva_total_violations_o)
    );

    taalas_uvm_noc_sram_sva_mon #(.MAX_CREDITS(8)) u_noc_sram_sva (
        .clk(clk), .rst_n(rst_n),
        .noc_avail_credits_i(m12_avail_credits_o),
        .noc_inflight_flits_i(m12_inflight_flits_o),
        .noc_skid_occ_i(m12_skid_occ_o),
        .sram_sec_err_i(m5_sec_err_o), .sram_ded_err_i(m5_ded_err_o),
        .sva_noc_sram_checks_o(sva_noc_checks)
    );
    assign sva_total_checks_o = sva_axi_checks + sva_noc_checks;

endmodule
