`timescale 1ns / 1ps
// =============================================================================
// Module: stage4_compute_ips_top
// Description:
//   Unified Verilator UVM Verification Top Wrapper instantiating all 4
//   Stage 4 Hardwired Compute Fabric IP Modules at full architectural scale:
//     1. M2: taalas_3b6b_wired_mac_array      (VEC_LEN=64, OUT_CHANNELS=16, NUM_OUTLIERS=4)
//     2. M3: taalas_mxfp4_hc2_mac_lane        (BLOCK_SIZE=32, NUM_LANES=8)
//     3. M4: taalas_group_dequant_scale_unit  (OUT_CHANNELS=16)
//     4. M7: taalas_lora_sram_overlay_engine  (IN_DIM=64, OUT_CHANNELS=16, MAX_RANK=16)
// =============================================================================

module stage4_compute_ips_top (
    input  logic          clk,
    input  logic          rst_n,

    // --- M2: taalas_3b6b_wired_mac_array Ports ---
    input  logic          m2_valid_i,
    input  logic [511:0]  m2_act_vec_i,
    input  logic [3071:0] m2_w_base_3b_i,
    input  logic [383:0]  m2_w_out_val_6b_i,
    input  logic [383:0]  m2_w_out_idx_6b_i,
    input  logic          m2_zero_skip_en_i,
    output logic          m2_valid_o,
    output logic [383:0]  m2_acc_out_o,
    output logic signed [15:0] m2_act_sum_o,
    output logic [15:0]   m2_zero_ops_saved_o,

    // --- M3: taalas_mxfp4_hc2_mac_lane Ports ---
    input  logic          m3_valid_i,
    input  logic [127:0]  m3_act_mxfp4_i,
    input  logic [7:0]    m3_act_e8m0_i,
    input  logic [1023:0] m3_w_mxfp4_i,
    input  logic [63:0]   m3_w_e8m0_i,
    output logic          m3_valid_o,
    output logic [127:0]  m3_dot_int16_o,
    output logic [79:0]   m3_exp_comb_o,
    output logic [255:0]  m3_fp32_out_o,

    // --- M4: taalas_group_dequant_scale_unit Ports ---
    input  logic          m4_valid_i,
    input  logic          m4_first_group_i,
    input  logic          m4_last_group_i,
    input  logic [383:0]  m4_raw_acc_i,
    input  logic signed [15:0] m4_act_sum_i,
    input  logic [255:0]  m4_w_scale_i,
    input  logic signed [15:0] m4_act_scale_i,
    input  logic [127:0]  m4_w_zp_i,
    input  logic [255:0]  m4_lora_delta_i,
    input  logic          m4_lora_en_i,
    output logic          m4_valid_o,
    output logic [255:0]  m4_dequant_out_o,
    output logic [511:0]  m4_acc_fp32_o,
    output logic          m4_sat_flag_o,

    // --- M7: taalas_lora_sram_overlay_engine Ports ---
    input  logic          m7_valid_i,
    input  logic          m7_lora_en_i,
    input  logic [7:0]    m7_active_rank_i,
    input  logic signed [15:0] m7_alpha_over_r_q8_8_i,
    input  logic [2:0]    m7_skew_delay_i,
    input  logic [511:0]  m7_act_vec_i,
    input  logic          m7_ext_weights_en_i,
    input  logic [8191:0] m7_lora_a_flat_i,
    input  logic [2047:0] m7_lora_b_flat_i,
    input  logic          m7_sram_we_i,
    input  logic          m7_sram_sel_b_i,
    input  logic [5:0]    m7_sram_row_addr_i,
    input  logic [511:0]  m7_sram_wdata_i,
    output logic          m7_valid_o,
    output logic [383:0]  m7_latent_h_o,
    output logic [255:0]  m7_lora_delta_o,
    output logic [15:0]   m7_stall_cycles_o
);

    taalas_3b6b_wired_mac_array #(
        .VEC_LEN(64), .OUT_CHANNELS(16), .NUM_OUTLIERS(4)
    ) u_m2_mac_array (
        .clk(clk), .rst_n(rst_n), .valid_i(m2_valid_i),
        .act_vec_i(m2_act_vec_i), .w_base_3b_i(m2_w_base_3b_i),
        .w_out_val_6b_i(m2_w_out_val_6b_i), .w_out_idx_6b_i(m2_w_out_idx_6b_i),
        .zero_skip_en_i(m2_zero_skip_en_i), .valid_o(m2_valid_o),
        .acc_out_o(m2_acc_out_o), .act_sum_o(m2_act_sum_o),
        .zero_ops_saved_o(m2_zero_ops_saved_o)
    );

    taalas_mxfp4_hc2_mac_lane #(
        .BLOCK_SIZE(32), .NUM_LANES(8)
    ) u_m3_mxfp4_lane (
        .clk(clk), .rst_n(rst_n), .valid_i(m3_valid_i),
        .act_mxfp4_i(m3_act_mxfp4_i), .act_e8m0_i(m3_act_e8m0_i),
        .w_mxfp4_i(m3_w_mxfp4_i), .w_e8m0_i(m3_w_e8m0_i),
        .valid_o(m3_valid_o), .dot_int16_o(m3_dot_int16_o),
        .exp_comb_o(m3_exp_comb_o), .fp32_out_o(m3_fp32_out_o)
    );

    taalas_group_dequant_scale_unit #(
        .OUT_CHANNELS(16), .ACC_WIDTH(24), .SCALE_WIDTH(16), .OUT_WIDTH(16)
    ) u_m4_dequant (
        .clk(clk), .rst_n(rst_n), .valid_i(m4_valid_i),
        .first_group_i(m4_first_group_i), .last_group_i(m4_last_group_i),
        .raw_acc_i(m4_raw_acc_i), .act_sum_i(m4_act_sum_i),
        .w_scale_i(m4_w_scale_i), .act_scale_i(m4_act_scale_i),
        .w_zp_i(m4_w_zp_i), .lora_delta_i(m4_lora_delta_i), .lora_en_i(m4_lora_en_i),
        .valid_o(m4_valid_o), .dequant_out_o(m4_dequant_out_o),
        .acc_fp32_o(m4_acc_fp32_o), .sat_flag_o(m4_sat_flag_o)
    );

    taalas_lora_sram_overlay_engine #(
        .IN_DIM(64), .OUT_CHANNELS(16), .MAX_RANK(16), .MAX_SKEW(8)
    ) u_m7_lora (
        .clk(clk), .rst_n(rst_n), .valid_i(m7_valid_i),
        .lora_en_i(m7_lora_en_i), .active_rank_i(m7_active_rank_i),
        .alpha_over_r_q8_8_i(m7_alpha_over_r_q8_8_i), .skew_delay_i(m7_skew_delay_i),
        .act_vec_i(m7_act_vec_i), .ext_weights_en_i(m7_ext_weights_en_i),
        .lora_a_flat_i(m7_lora_a_flat_i), .lora_b_flat_i(m7_lora_b_flat_i),
        .sram_we_i(m7_sram_we_i), .sram_sel_b_i(m7_sram_sel_b_i),
        .sram_row_addr_i(m7_sram_row_addr_i), .sram_wdata_i(m7_sram_wdata_i),
        .valid_o(m7_valid_o), .latent_h_o(m7_latent_h_o),
        .lora_delta_o(m7_lora_delta_o), .stall_cycles_o(m7_stall_cycles_o)
    );

endmodule
