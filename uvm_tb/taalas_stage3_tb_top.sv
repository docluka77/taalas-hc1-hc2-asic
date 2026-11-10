// =============================================================================
// Module:      taalas_stage3_tb_top
// Description: Verilator UVM Unit Testbench Top Wrapper instantiating all three
//              Stage 3 Memory & Storage IP Modules:
//              - M1: taalas_via_mask_rom_macro
//              - M5: taalas_sram_6t_banked_macro
//              - M6: taalas_kv_cache_manager
// =============================================================================

`timescale 1ns / 1ps

module taalas_stage3_tb_top (
    input  logic         clk,
    input  logic         rst_n,

    // --- M1: Via-Mask ROM Macro Ports ---
    input  logic         rom_sleep_n,
    input  logic         rom_sleep_i,
    input  logic         rom_iso_en_i,
    input  logic         rom_cs_en,
    input  logic         rom_precharge_en,
    input  logic         rom_sa_en,
    input  logic [2:0]   rom_bank_sel_i,
    input  logic [7:0]   rom_addr_i,
    input  logic         rom_prog_en_i,
    input  logic [2:0]   rom_prog_bank_i,
    input  logic [7:0]   rom_prog_row_i,
    input  logic [511:0] rom_prog_wdata_i,
    input  logic         rom_bist_start_i,
    output logic         rom_bist_busy_o,
    output logic         rom_bist_done_o,
    output logic [15:0]  rom_bist_crc16_o,
    output logic         rom_bist_pass_o,
    output logic [511:0] rom_rdata_o,
    output logic [191:0] rom_weights_3b_o,
    output logic [47:0]  rom_outlier_idx_o,
    output logic [47:0]  rom_outlier_val6b_o,
    output logic [15:0]  rom_group_scale_fp16_o,
    output logic [7:0]   rom_group_zp_int8_o,
    output logic         rom_rvalid_o,
    output logic [9:0]   rom_active_vias_o,
    output logic [7:0]   rom_bank_active_o,
    output logic         rom_bl_precharged_o,

    // --- M5: 16-Bank 6T SRAM Macro Ports ---
    input  logic         sram_ret_sleep_i,
    input  logic [15:0]  sram_bank_cg_en_i,
    input  logic         sram_req_valid_i,
    input  logic         sram_req_we_i,
    input  logic [3:0]   sram_req_bank_i,
    input  logic [7:0]   sram_req_row_i,
    input  logic [63:0]  sram_req_wdata_i,
    input  logic [7:0]   sram_req_wmask_i,
    input  logic [15:0]  sram_vec_req_valid_i,
    input  logic [127:0] sram_vec_req_row_i,
    output logic [15:0]  sram_bank_conflict_mask_o,
    output logic         sram_conflict_free_o,
    input  logic         sram_err_inj_en_i,
    input  logic [71:0]  sram_err_inj_mask_i,
    output logic         sram_resp_valid_o,
    output logic [63:0]  sram_resp_rdata_o,
    output logic [71:0]  sram_resp_raw_codeword_o,
    output logic [3:0]   sram_phys_bank_o,
    output logic         sram_sec_err_o,
    output logic         sram_ded_err_o,
    output logic [7:0]   sram_err_syndrome_o,
    output logic [15:0]  sram_sec_err_cnt_o,
    output logic [15:0]  sram_ded_err_cnt_o,

    // --- M6: GQA 4:1 KV-Cache Manager Ports ---
    input  logic [2:0]   kv_slot_id_i,
    input  logic [2:0]   kv_head_id_i,
    input  logic         kv_append_en_i,
    input  logic         kv_read_seq_en_i,
    input  logic         kv_clear_slot_i,
    input  logic         kv_sliding_win_en_i,
    input  logic [3:0]   kv_sink_tokens_cfg_i,
    input  logic [63:0]  kv_k_vec_in_i,
    input  logic [63:0]  kv_v_vec_in_i,
    input  logic [15:0]  kv_k_scale_in_i,
    input  logic [15:0]  kv_v_scale_in_i,
    input  logic [3:0]   kv_k_zp_in_i,
    input  logic [3:0]   kv_v_zp_in_i,
    output logic         kv_sram_req_valid_o,
    output logic         kv_sram_req_we_o,
    output logic [3:0]   kv_sram_req_bank_o,
    output logic [9:0]   kv_sram_req_row_o,
    output logic [63:0]  kv_sram_req_wdata_o,
    output logic [127:0] kv_k_dequant_o,
    output logic [127:0] kv_v_dequant_o,
    output logic [511:0] kv_gqa_k_bcast_o,
    output logic [511:0] kv_gqa_v_bcast_o,
    output logic [4:0]   kv_wr_ptr_o,
    output logic [4:0]   kv_rd_ptr_o,
    output logic [11:0]  kv_seq_pos_o,
    output logic [12:0]  kv_curr_seq_len_o,
    output logic [7:0]   kv_slot_active_mask_o,
    output logic [15:0]  kv_eviction_cnt_o,
    output logic         kv_valid_o,
    output logic         kv_last_o,
    output logic         kv_seq_done_o,
    output logic [2:0]   kv_fsm_state_o
);

    // -------------------------------------------------------------------------
    // 1. M1: Two-Mask Via-Programmable Hardwired Weight ROM Macro
    // -------------------------------------------------------------------------
    taalas_via_mask_rom_macro #(
        .NUM_BANKS     (8),
        .ROWS          (256),
        .COLS          (512),
        .COLS_3B       (64),
        .OUTLIER_SLOTS (8)
    ) u_rom (
        .clk                (clk),
        .rst_n              (rst_n),
        .sleep_n            (rom_sleep_n),
        .sleep_i            (rom_sleep_i),
        .iso_en_i           (rom_iso_en_i),
        .cs_en              (rom_cs_en),
        .precharge_en       (rom_precharge_en),
        .sa_en              (rom_sa_en),
        .bank_sel_i         (rom_bank_sel_i),
        .addr_i             (rom_addr_i),
        .prog_en_i          (rom_prog_en_i),
        .prog_bank_i        (rom_prog_bank_i),
        .prog_row_i         (rom_prog_row_i),
        .prog_wdata_i       (rom_prog_wdata_i),
        .bist_start_i       (rom_bist_start_i),
        .bist_busy_o        (rom_bist_busy_o),
        .bist_done_o        (rom_bist_done_o),
        .bist_crc16_o       (rom_bist_crc16_o),
        .bist_pass_o        (rom_bist_pass_o),
        .rdata_o            (rom_rdata_o),
        .weights_3b_o       (rom_weights_3b_o),
        .outlier_idx_o      (rom_outlier_idx_o),
        .outlier_val6b_o    (rom_outlier_val6b_o),
        .group_scale_fp16_o (rom_group_scale_fp16_o),
        .group_zp_int8_o    (rom_group_zp_int8_o),
        .rvalid_o           (rom_rvalid_o),
        .active_vias_o      (rom_active_vias_o),
        .bank_active_o      (rom_bank_active_o),
        .bl_precharged_o    (rom_bl_precharged_o)
    );

    // -------------------------------------------------------------------------
    // 2. M5: 16-Bank 6T SRAM Macro w/ GF(2^4) Swizzling & (72,64) SECDED ECC
    // -------------------------------------------------------------------------
    taalas_sram_6t_banked_macro #(
        .NUM_BANKS  (16),
        .BANK_DEPTH (256),
        .DATA_WIDTH (64),
        .ECC_WIDTH  (8),
        .RAW_WIDTH  (72)
    ) u_sram (
        .clk                  (clk),
        .rst_n                (rst_n),
        .ret_sleep_i          (sram_ret_sleep_i),
        .bank_cg_en_i         (sram_bank_cg_en_i),
        .req_valid_i          (sram_req_valid_i),
        .req_we_i             (sram_req_we_i),
        .req_bank_i           (sram_req_bank_i),
        .req_row_i            (sram_req_row_i),
        .req_wdata_i          (sram_req_wdata_i),
        .req_wmask_i          (sram_req_wmask_i),
        .vec_req_valid_i      (sram_vec_req_valid_i),
        .vec_req_row_i        (sram_vec_req_row_i),
        .bank_conflict_mask_o (sram_bank_conflict_mask_o),
        .conflict_free_o      (sram_conflict_free_o),
        .err_inj_en_i         (sram_err_inj_en_i),
        .err_inj_mask_i       (sram_err_inj_mask_i),
        .resp_valid_o         (sram_resp_valid_o),
        .resp_rdata_o         (sram_resp_rdata_o),
        .resp_raw_codeword_o  (sram_resp_raw_codeword_o),
        .phys_bank_o          (sram_phys_bank_o),
        .sec_err_o            (sram_sec_err_o),
        .ded_err_o            (sram_ded_err_o),
        .err_syndrome_o       (sram_err_syndrome_o),
        .sec_err_cnt_o        (sram_sec_err_cnt_o),
        .ded_err_cnt_o        (sram_ded_err_cnt_o)
    );

    // -------------------------------------------------------------------------
    // 3. M6: Grouped-Query Attention (GQA 4:1) Ring-Buffer KV-Cache Manager
    // -------------------------------------------------------------------------
    taalas_kv_cache_manager #(
        .MAX_USERS    (8),
        .MAX_SEQ_LEN  (32),
        .NUM_KV_HEADS (8),
        .GQA_RATIO    (4),
        .HEAD_DIM     (16)
    ) u_kv (
        .clk               (clk),
        .rst_n             (rst_n),
        .slot_id_i         (kv_slot_id_i),
        .kv_head_id_i      (kv_head_id_i),
        .append_en_i       (kv_append_en_i),
        .read_seq_en_i     (kv_read_seq_en_i),
        .clear_slot_i      (kv_clear_slot_i),
        .sliding_win_en_i  (kv_sliding_win_en_i),
        .sink_tokens_cfg_i (kv_sink_tokens_cfg_i),
        .k_vec_in_i        (kv_k_vec_in_i),
        .v_vec_in_i        (kv_v_vec_in_i),
        .k_scale_in_i      (kv_k_scale_in_i),
        .v_scale_in_i      (kv_v_scale_in_i),
        .k_zp_in_i         (kv_k_zp_in_i),
        .v_zp_in_i         (kv_v_zp_in_i),
        .sram_req_valid_o  (kv_sram_req_valid_o),
        .sram_req_we_o     (kv_sram_req_we_o),
        .sram_req_bank_o   (kv_sram_req_bank_o),
        .sram_req_row_o    (kv_sram_req_row_o),
        .sram_req_wdata_o  (kv_sram_req_wdata_o),
        .k_dequant_o       (kv_k_dequant_o),
        .v_dequant_o       (kv_v_dequant_o),
        .gqa_k_bcast_o     (kv_gqa_k_bcast_o),
        .gqa_v_bcast_o     (kv_gqa_v_bcast_o),
        .wr_ptr_o          (kv_wr_ptr_o),
        .rd_ptr_o          (kv_rd_ptr_o),
        .seq_pos_o         (kv_seq_pos_o),
        .curr_seq_len_o    (kv_curr_seq_len_o),
        .slot_active_mask_o(kv_slot_active_mask_o),
        .eviction_cnt_o    (kv_eviction_cnt_o),
        .kv_valid_o        (kv_valid_o),
        .kv_last_o         (kv_last_o),
        .seq_done_o        (kv_seq_done_o),
        .fsm_state_o       (kv_fsm_state_o)
    );

endmodule
