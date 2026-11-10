`timescale 1ns / 1ps
// =============================================================================
// Module: taalas_stage23_audit_verif_top
// Description:
//   Unified Verification Wrapper for Stage 23/24 60-Source Audit Remediation:
//     1. M01 (taalas_via_mask_rom_macro): Bitline Precharge vs WL Interlock
//     2. M03 (taalas_mxfp4_hc2_mac_lane): OCP MX v1.0 E8M0=0xFF NaN & RNE Subnormal
//     3. M05 (taalas_sram_6t_banked_macro): 72-bit SECDED + Unmapped MBU DED Guard
//     4. H1  (taalas_hc2_disagg_sram_fabric): 72-bit SECDED + Unmapped MBU DED Guard
//     5. M08 (taalas_rope_cordic_unit): Meta Llama-3.1 Per-Lane RoPE Stride & /8
//     6. M09 (taalas_flash_decode_attention): Base-e CSD log2(e) Softmax Scaling
//     7. H3  (taalas_hc2_moe_mla_router): DeepSeek-V3/R1 Biased Top-K Unbiased Gate
// =============================================================================

module taalas_stage23_audit_verif_top (
    input  logic         clk,
    input  logic         rst_n,

    // --- 1. M01: Via-Mask ROM Macro ---
    input  logic         m01_cs_en_i,
    input  logic         m01_precharge_en_i,
    input  logic         m01_sa_en_i,
    input  logic         m01_sleep_i,
    input  logic [3:0]   m01_bank_sel_i,
    input  logic [5:0]   m01_row_addr_i,
    output logic         m01_rvalid_o,
    output logic         m01_bl_precharged_o,
    output logic         m01_bl_contention_prevented_o,
    output logic [15:0]  m01_bank_active_o,

    // --- 2. M03: OCP MXFP4 MAC Lane (BLOCK_SIZE=16, NUM_LANES=4) ---
    input  logic         m03_valid_i,
    input  logic [63:0]  m03_act_mxfp4_i,
    input  logic [7:0]   m03_act_e8m0_i,
    input  logic [255:0] m03_w_mxfp4_i,
    input  logic [31:0]  m03_w_e8m0_i,
    output logic         m03_valid_o,
    output logic [63:0]  m03_dot_int16_o,
    output logic [39:0]  m03_exp_comb_o,
    output logic [127:0] m03_fp32_out_o,
    output logic [3:0]   m03_nan_flag_o,

    // --- 3. M05: 6T Banked SECDED SRAM Macro ---
    input  logic         m05_req_valid_i,
    input  logic         m05_req_we_i,
    input  logic [3:0]   m05_req_bank_i,
    input  logic [5:0]   m05_req_row_i,
    input  logic [63:0]  m05_req_wdata_i,
    input  logic         m05_err_inj_en_i,
    input  logic [71:0]  m05_err_inj_mask_i,
    output logic         m05_resp_valid_o,
    output logic [63:0]  m05_resp_rdata_o,
    output logic         m05_sec_err_o,
    output logic         m05_ded_err_o,
    output logic [7:0]   m05_err_syndrome_o,

    // --- 4. M08: RoPE CORDIC Unit (PAIR_LANES=4) ---
    input  logic         m08_valid_i,
    input  logic [16:0]  m08_token_pos_i,
    input  logic [2:0]   m08_pair_chunk_idx_i,
    input  logic [1:0]   m08_llama31_scale_mode_i,
    input  logic [127:0] m08_vec_in_i,
    output logic         m08_valid_o,
    output logic [127:0] m08_vec_out_o,
    output logic [63:0]  m08_cos_monitor_o,
    output logic [63:0]  m08_sin_monitor_o,
    output logic         m08_zero_pos_identity_o,

    // --- 5. M09: Flash-Decode Attention (HEAD_DIM=4, GQA_RATIO=2) ---
    input  logic         m09_start_seq_i,
    input  logic         m09_kv_valid_i,
    input  logic         m09_kv_last_i,
    input  logic [127:0] m09_q_heads_i,
    input  logic [63:0]  m09_k_shared_i,
    input  logic [63:0]  m09_v_shared_i,
    input  logic [15:0]  m09_scale_log2e_q8_8_i,
    input  logic         m09_log2e_scale_en_i,
    output logic         m09_step_valid_o,
    output logic         m09_out_valid_o,
    output logic [127:0] m09_attn_out_o,
    output logic [31:0]  m09_max_score_o,
    output logic [47:0]  m09_denom_sum_o,
    // --- 6. H3: DeepSeek-R1 MoE Router (NUM_EXPERTS=16, DIM_GATE=8, MAX_K=4) ---
    input  logic         h3_valid_i,
    input  logic         h3_topk_mode_i,
    input  logic         h3_shared_expert_en_i,
    input  logic [7:0]   h3_token_id_i,
    input  logic [31:0]  h3_act_mxfp4_i,
    input  logic [7:0]   h3_act_e8m0_i,
    input  logic [511:0] h3_gate_w_mxfp4_i,
    input  logic [127:0] h3_gate_w_e8m0_i,
    input  logic [127:0] h3_expert_bias_i,
    output logic         h3_valid_o,
    output logic [15:0]  h3_sel_expert_id_o,
    output logic [63:0]  h3_gate_weight_q88_o,
    output logic [63:0]  h3_sel_expert_score_o,
    output logic [15:0]  h3_active_expert_mask_o,
    output logic [15:0]  h3_clock_gated_expert_mask_o
);

    taalas_via_mask_rom_macro #(
        .NUM_BANKS(16), .ROWS(64), .COLS(320), .COLS_3B(64), .OUTLIER_SLOTS(8)
    ) u_m01 (
        .clk                      (clk),
        .rst_n                    (rst_n),
        .cs_en                    (m01_cs_en_i),
        .precharge_en             (m01_precharge_en_i),
        .sa_en                    (m01_sa_en_i),
        .sleep_n                  (~m01_sleep_i),
        .sleep_i                  (m01_sleep_i),
        .iso_en_i                 (1'b0),
        .bank_sel_i               (m01_bank_sel_i),
        .addr_i                   (m01_row_addr_i),
        .prog_en_i                (1'b0),
        .prog_bank_i              ('0),
        .prog_row_i               ('0),
        .prog_wdata_i             ('0),
        .bist_start_i             (1'b0),
        .bist_busy_o              (),
        .bist_done_o              (),
        .bist_crc16_o             (),
        .bist_pass_o              (),
        .rdata_o                  (),
        .weights_3b_o             (),
        .outlier_idx_o            (),
        .outlier_val6b_o          (),
        .group_scale_fp16_o       (),
        .group_zp_int8_o          (),
        .rvalid_o                 (m01_rvalid_o),
        .active_vias_o            (),
        .bank_active_o            (m01_bank_active_o),
        .bl_precharged_o          (m01_bl_precharged_o),
        .bl_contention_prevented_o(m01_bl_contention_prevented_o)
    );

    taalas_mxfp4_hc2_mac_lane #(
        .BLOCK_SIZE(16), .NUM_LANES(4)
    ) u_m03 (
        .clk        (clk),
        .rst_n      (rst_n),
        .valid_i    (m03_valid_i),
        .act_mxfp4_i(m03_act_mxfp4_i),
        .act_e8m0_i (m03_act_e8m0_i),
        .w_mxfp4_i  (m03_w_mxfp4_i),
        .w_e8m0_i   (m03_w_e8m0_i),
        .valid_o    (m03_valid_o),
        .dot_int16_o(m03_dot_int16_o),
        .exp_comb_o (m03_exp_comb_o),
        .fp32_out_o (m03_fp32_out_o),
        .nan_flag_o (m03_nan_flag_o)
    );
    taalas_sram_6t_banked_macro #(
        .NUM_BANKS(16), .BANK_DEPTH(64), .DATA_WIDTH(64), .ECC_WIDTH(8), .RAW_WIDTH(72)
    ) u_m05 (
        .clk                 (clk),
        .rst_n               (rst_n),
        .ret_sleep_i         (1'b0),
        .bank_cg_en_i        (16'hFFFF),
        .req_valid_i         (m05_req_valid_i),
        .req_we_i            (m05_req_we_i),
        .req_bank_i          (m05_req_bank_i),
        .req_row_i           (m05_req_row_i),
        .req_wdata_i         (m05_req_wdata_i),
        .req_wmask_i         (8'hFF),
        .vec_req_valid_i     (16'h0000),
        .vec_req_row_i       ('0),
        .bank_conflict_mask_o(),
        .conflict_free_o     (),
        .err_inj_en_i        (m05_err_inj_en_i),
        .err_inj_mask_i      (m05_err_inj_mask_i),
        .resp_valid_o        (m05_resp_valid_o),
        .resp_rdata_o        (m05_resp_rdata_o),
        .resp_raw_codeword_o (),
        .phys_bank_o         (),
        .sec_err_o           (m05_sec_err_o),
        .ded_err_o           (m05_ded_err_o),
        .err_syndrome_o      (m05_err_syndrome_o),
        .sec_err_cnt_o       (),
        .ded_err_cnt_o       ()
    );

    taalas_rope_cordic_unit #(
        .HEAD_DIM(64), .PAIR_LANES(4), .DATA_W(16), .TRIG_W(16)
    ) u_m08 (
        .clk                 (clk),
        .rst_n               (rst_n),
        .valid_i             (m08_valid_i),
        .is_key_i            (1'b0),
        .head_id_i           (6'd0),
        .pair_chunk_idx_i    (m08_pair_chunk_idx_i),
        .token_pos_i         (m08_token_pos_i),
        .ntk_scale_en_i      (1'b0),
        .bypass_en_i         (1'b0),
        .llama31_scale_mode_i(m08_llama31_scale_mode_i),
        .vec_in_i            (m08_vec_in_i),
        .valid_o             (m08_valid_o),
        .is_key_o            (),
        .head_id_o           (),
        .pair_chunk_idx_o    (),
        .vec_out_o           (m08_vec_out_o),
        .cos_monitor_o       (m08_cos_monitor_o),
        .sin_monitor_o       (m08_sin_monitor_o),
        .zero_pos_identity_o (m08_zero_pos_identity_o),
        .sat_count_o         ()
    );

    taalas_flash_decode_attention #(
        .HEAD_DIM(4), .GQA_RATIO(2), .DATA_W(16)
    ) u_m09 (
        .clk               (clk),
        .rst_n             (rst_n),
        .start_seq_i       (m09_start_seq_i),
        .kv_valid_i        (m09_kv_valid_i),
        .kv_last_i         (m09_kv_last_i),
        .q_heads_i         (m09_q_heads_i),
        .k_shared_i        (m09_k_shared_i),
        .v_shared_i        (m09_v_shared_i),
        .scale_log2e_q8_8_i(m09_scale_log2e_q8_8_i),
        .log2e_scale_en_i  (m09_log2e_scale_en_i),
        .step_valid_o      (m09_step_valid_o),
        .out_valid_o       (m09_out_valid_o),
        .attn_out_o        (m09_attn_out_o),
        .max_score_o       (m09_max_score_o),
        .denom_sum_o       (m09_denom_sum_o)
    );

    taalas_hc2_moe_mla_router #(
        .NUM_EXPERTS(16), .DIM_GATE(8), .MAX_K(4), .NUM_CHIPS(4)
    ) u_h3 (
        .clk                      (clk),
        .rst_n                    (rst_n),
        .valid_i                  (h3_valid_i),
        .topk_mode_i              (h3_topk_mode_i),
        .shared_expert_en_i       (h3_shared_expert_en_i),
        .token_id_i               (h3_token_id_i),
        .act_mxfp4_i              (h3_act_mxfp4_i),
        .act_e8m0_i               (h3_act_e8m0_i),
        .gate_w_mxfp4_i           (h3_gate_w_mxfp4_i),
        .gate_w_e8m0_i            (h3_gate_w_e8m0_i),
        .expert_bias_i            (h3_expert_bias_i),
        .valid_o                  (h3_valid_o),
        .topk_mode_o              (),
        .shared_expert_active_o   (),
        .sel_expert_id_o          (h3_sel_expert_id_o),
        .dst_chip_id_o            (),
        .gate_weight_q88_o        (h3_gate_weight_q88_o),
        .sel_expert_score_o       (h3_sel_expert_score_o),
        .active_expert_mask_o     (h3_active_expert_mask_o),
        .clock_gated_expert_mask_o(h3_clock_gated_expert_mask_o),
        .active_expert_cnt_o      (),
        .gated_expert_cnt_o       (),
        .routed_token_cnt_o       (),
        .cum_gated_expert_cycles_o()
    );

endmodule
