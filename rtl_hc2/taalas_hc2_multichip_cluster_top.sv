`timescale 1ns / 1ps
/* verilator lint_off SYNCASYNCNET */
// =============================================================================
// Module:      taalas_hc2_multichip_cluster_top (H4)
// Project:     Taalas HC2 Disaggregated 3D-SRAM & Multi-Chip Cluster (Stage 17)
// Description: Top-Level Multi-Chip Taalas HC2 Cluster Integrator (NUM_CHIPS=4,
//              scalable to 30-Chip DeepSeek-R1 671B Pipeline/Tensor Ring):
//              Integrates per HC2 Die:
//                1. taalas_hc2_disagg_sram_fabric (H1) - 4-Port x 16-Bank
//                   Disaggregated 3D-SRAM MLA Latent & GQA KV Cache + SECDED
//                2. taalas_hc2_c2c_llr_serdes_ctrl (H2) - 112G SerDes C2C
//                   Link-Layer Retry (LLR) with 16-Entry Replay & CRC-16-CCITT
//                3. taalas_hc2_moe_mla_router (H3) - Hardwired MXFP4 Top-K
//                   (K=2 / K=4) MoE Gating & Expert Clock-Gating Controller
//                4. taalas_mxfp4_hc2_mac_lane (M3) - Multiplierless OCP MXFP4
//                   E2M1 + E8M0 Spatial Dot-Product Compute Array
// =============================================================================

module taalas_hc2_multichip_cluster_top #(
    parameter int NUM_CHIPS   = 4,
    parameter int NUM_PORTS   = 4,
    parameter int NUM_BANKS   = 16,
    parameter int BANK_DEPTH  = 16,
    parameter int NUM_EXPERTS = 16,
    parameter int DIM_GATE    = 8,
    parameter int BLOCK_SIZE  = 8,
    parameter int NUM_LANES   = 2
) (
    input  logic                                clk,
    input  logic                                rst_n,

    // Global Cluster Architectural Mode Controls
    input  logic                                mla_mode_en_i,        // 1=DeepSeek-R1 MLA 8x Compression
    input  logic                                topk_mode_i,          // 0=Top-2 (87.5% CG), 1=Top-4 (75% CG)
    input  logic                                shared_expert_en_i,   // 1=Enable Dedicated Shared Expert

    // Cluster Ingress Token Stream (Into Die 0 of Multi-Chip Pipeline)
    input  logic                                cluster_tok_valid_i,
    input  logic [7:0]                          cluster_tok_id_i,
    input  logic [3:0]                          cluster_user_id_i,
    input  logic [7:0]                          cluster_tok_pos_i,
    input  logic [63:0]                         cluster_tok_latent_i, // {k_t^R[15:0], c_t^KV[47:0]}
    input  logic [DIM_GATE*4-1:0]               cluster_act_mxfp4_i,
    input  logic [7:0]                          cluster_act_e8m0_i,
    output logic                                cluster_tok_ready_o,

    // Per-Link C2C 112G SerDes Bit-Error Injection (Links 0..NUM_CHIPS-1)
    input  logic [NUM_CHIPS-1:0]                c2c_link_err_inj_i,

    // Direct 4-Port 3D-SRAM Fabric & SECDED Diagnostic Access (Die 0)
    input  logic                                sram_diag_en_i,
    input  logic [NUM_PORTS-1:0]                sram_port_req_valid_i,
    input  logic [NUM_PORTS-1:0]                sram_port_req_we_i,
    input  logic [NUM_PORTS*4-1:0]              sram_port_user_id_i,
    input  logic [NUM_PORTS*8-1:0]              sram_port_token_pos_i,
    input  logic [NUM_PORTS*4-1:0]              sram_port_head_sub_i,
    input  logic [NUM_PORTS*64-1:0]             sram_port_wdata_i,
    input  logic                                sram_err_inj_en_i,
    input  logic [1:0]                          sram_err_inj_port_i,
    input  logic [5:0]                          sram_err_inj_bit_i,
    input  logic                                sram_err_inj_double_i,

    // Direct 4-Port 3D-SRAM Diagnostic Outputs
    output logic [NUM_PORTS-1:0]                sram_port_grant_o,
    output logic [NUM_PORTS*4-1:0]              sram_port_phys_bank_o,
    output logic [NUM_PORTS-1:0]                sram_port_resp_valid_o,
    output logic [NUM_PORTS*64-1:0]             sram_port_resp_rdata_o,
    output logic [NUM_PORTS-1:0]                sram_port_sec_err_o,
    output logic [NUM_PORTS-1:0]                sram_port_ded_err_o,
    output logic [3:0]                          sram_kv_compress_ratio_o,

    // Cluster Egress Token Stream (From Final Die NUM_CHIPS-1)
    output logic                                cluster_out_valid_o,
    output logic [63:0]                         cluster_out_flit_o,
    output logic [7:0]                          cluster_out_seq_o,
    output logic [31:0]                         cluster_out_fp32_o,

    // Per-Die MoE & C2C LLR Cluster Telemetry Outputs
    output logic [NUM_CHIPS*16-1:0]             die_active_experts_o,
    output logic [NUM_CHIPS*16-1:0]             die_gated_experts_o,
    output logic [NUM_CHIPS*16-1:0]             die_sel_expert_ids_o,
    output logic [NUM_CHIPS-1:0]                die_c2c_replay_active_o,
    output logic [NUM_CHIPS-1:0]                die_c2c_crc_err_o,
    output logic [15:0]                         cluster_tx_frames_o,
    output logic [15:0]                         cluster_rx_good_o,
    output logic [15:0]                         cluster_llr_replays_o,
    output logic [15:0]                         cluster_crc_errors_o,
    output logic [15:0]                         cluster_sec_fixes_o,
    output logic [31:0]                         cluster_gated_expert_cycles_o
);

    // -------------------------------------------------------------------------
    // 1. Inter-Die Pipeline Signals & Hardwired Via-ROM Weight Constants
    // -------------------------------------------------------------------------
    logic                  die_in_valid      [0:NUM_CHIPS-1];
    logic [63:0]           die_in_flit       [0:NUM_CHIPS-1];
    logic [7:0]            die_in_seq        [0:NUM_CHIPS-1];

    // Per-Die H1 Disaggregated 3D-SRAM Signals
    logic [NUM_PORTS-1:0]  die_sram_grant    [0:NUM_CHIPS-1];
    logic [NUM_PORTS*4-1:0] die_sram_pbank   [0:NUM_CHIPS-1];
    logic [NUM_PORTS-1:0]  die_sram_rvalid   [0:NUM_CHIPS-1];
    logic [NUM_PORTS*64-1:0] die_sram_rdata  [0:NUM_CHIPS-1];
    logic [NUM_PORTS-1:0]  die_sram_sec      [0:NUM_CHIPS-1];
    logic [NUM_PORTS-1:0]  die_sram_ded      [0:NUM_CHIPS-1];
    logic [3:0]            die_sram_words_tok[0:NUM_CHIPS-1];
    logic [3:0]            die_sram_comp_rat [0:NUM_CHIPS-1];
    logic [15:0]           die_sram_gcnt     [0:NUM_CHIPS-1];
    logic [15:0]           die_sram_scnt     [0:NUM_CHIPS-1];
    logic [15:0]           die_sram_sec_cnt  [0:NUM_CHIPS-1];
    logic [15:0]           die_sram_ded_cnt  [0:NUM_CHIPS-1];

    // Per-Die H3 MoE Router Signals
    logic                  die_moe_valid     [0:NUM_CHIPS-1];
    logic                  die_moe_topk_m    [0:NUM_CHIPS-1];
    logic                  die_moe_shared_a  [0:NUM_CHIPS-1];
    logic [15:0]           die_moe_sel_ids   [0:NUM_CHIPS-1];
    logic [19:0]           die_moe_dst_chips [0:NUM_CHIPS-1];
    logic [63:0]           die_moe_weights   [0:NUM_CHIPS-1];
    logic [63:0]           die_moe_scores    [0:NUM_CHIPS-1];
    logic [15:0]           die_moe_act_mask  [0:NUM_CHIPS-1];
    logic [15:0]           die_moe_cg_mask   [0:NUM_CHIPS-1];
    logic [4:0]            die_moe_act_cnt   [0:NUM_CHIPS-1];
    logic [4:0]            die_moe_cg_cnt    [0:NUM_CHIPS-1];
    logic [15:0]           die_moe_tok_cnt   [0:NUM_CHIPS-1];
    logic [31:0]           die_moe_cg_cycles [0:NUM_CHIPS-1];

    // Per-Die M3 MXFP4 Compute Macro Signals
    logic                  die_mac_valid     [0:NUM_CHIPS-1];
    logic [NUM_LANES*16-1:0] die_mac_dot16   [0:NUM_CHIPS-1];
    logic [NUM_LANES*10-1:0] die_mac_exp10   [0:NUM_CHIPS-1];
    logic [NUM_LANES*32-1:0] die_mac_fp32    [0:NUM_CHIPS-1];

    // Per-Die H2 C2C LLR SerDes Link Signals
    logic                  die_c2c_tx_ready  [0:NUM_CHIPS-1];
    logic                  die_c2c_rx_valid  [0:NUM_CHIPS-1];
    logic [63:0]           die_c2c_rx_data   [0:NUM_CHIPS-1];
    logic [7:0]            die_c2c_rx_seq    [0:NUM_CHIPS-1];
    logic                  c2c_wire_valid    [0:NUM_CHIPS-1];
    logic [87:0]           c2c_wire_frame    [0:NUM_CHIPS-1];
    logic                  c2c_wire_cred_ret [0:NUM_CHIPS-1];
    logic                  c2c_wire_ack_val  [0:NUM_CHIPS-1];
    logic                  c2c_wire_ack_nack [0:NUM_CHIPS-1];
    logic [7:0]            c2c_wire_ack_seq  [0:NUM_CHIPS-1];
    logic [4:0]            die_c2c_creds     [0:NUM_CHIPS-1];
    logic [4:0]            die_c2c_unacked   [0:NUM_CHIPS-1];
    logic [15:0]           die_c2c_tx_cnt    [0:NUM_CHIPS-1];
    logic [15:0]           die_c2c_rx_cnt    [0:NUM_CHIPS-1];
    logic [15:0]           die_c2c_rep_cnt   [0:NUM_CHIPS-1];
    logic [15:0]           die_c2c_crc_cnt   [0:NUM_CHIPS-1];

    logic [NUM_CHIPS-1:0]  die_fifo_ready;
    logic [NUM_CHIPS-1:0]  die_tx_rdy_vec;
    always_comb begin
        for (int i = 0; i < NUM_CHIPS; i++) begin
            die_tx_rdy_vec[i] = die_c2c_tx_ready[i] && (die_c2c_unacked[i] == 5'd0);
        end
    end
    assign cluster_tok_ready_o = (&die_fifo_ready) && (&die_tx_rdy_vec);

    // -------------------------------------------------------------------------
    // 2. Multi-Chip Spatial Pipeline Generation (NUM_CHIPS HC2 Dies)
    // -------------------------------------------------------------------------
    genvar c;
    generate
        for (c = 0; c < NUM_CHIPS; c++) begin : gen_hc2_dies
            // Per-Die Elastic Ingress FIFO (8-deep) to absorb downstream C2C LLR replays
            logic [63:0] hop_fifo_mem [0:7];
            logic [2:0]  hop_wr_ptr_q, hop_rd_ptr_q;
            logic [3:0]  hop_cnt_q;
            logic        hop_push_comb, hop_pop_comb;

            assign die_fifo_ready[c] = (hop_cnt_q < 4'd2);

            if (c == 0) begin : gen_die0_in
                assign die_in_valid[0] = cluster_tok_valid_i && cluster_tok_ready_o;
                assign die_in_flit[0]  = cluster_tok_latent_i;
                assign die_in_seq[0]   = cluster_tok_id_i;
            end else begin : gen_dieN_in
                assign die_in_valid[c] = die_c2c_rx_valid[c-1];
                assign die_in_flit[c]  = die_c2c_rx_data[c-1];
                assign die_in_seq[c]   = die_c2c_rx_seq[c-1];
            end

            assign hop_push_comb = die_in_valid[c] && (hop_cnt_q < 4'd8);
            assign hop_pop_comb  = (hop_cnt_q > 4'd0) && die_c2c_tx_ready[c] && (die_c2c_unacked[c] == 5'd0);

            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    hop_wr_ptr_q <= 3'd0;
                    hop_rd_ptr_q <= 3'd0;
                    hop_cnt_q    <= 4'd0;
                end else begin
                    if (hop_push_comb) begin
                        hop_fifo_mem[hop_wr_ptr_q] <= die_in_flit[c];
                        hop_wr_ptr_q               <= hop_wr_ptr_q + 3'd1;
                    end
                    if (hop_pop_comb) begin
                        hop_rd_ptr_q <= hop_rd_ptr_q + 3'd1;
                    end
                    case ({hop_push_comb, hop_pop_comb})
                        2'b10: hop_cnt_q <= hop_cnt_q + 4'd1;
                        2'b01: hop_cnt_q <= hop_cnt_q - 4'd1;
                        default: hop_cnt_q <= hop_cnt_q;
                    endcase
                end
            end

            // H1: Disaggregated 3D-SRAM KV & DeepSeek-R1 MLA Latent Cache Fabric
            logic [NUM_PORTS-1:0]    loc_sram_val;
            logic [NUM_PORTS-1:0]    loc_sram_we;
            logic [NUM_PORTS*4-1:0]  loc_sram_usr;
            logic [NUM_PORTS*8-1:0]  loc_sram_pos;
            logic [NUM_PORTS*4-1:0]  loc_sram_head;
            logic [NUM_PORTS*64-1:0] loc_sram_wdat;
            logic                    loc_err_en;
            logic [1:0]              loc_err_port;
            logic [5:0]              loc_err_bit;
            logic                    loc_err_dbl;

            assign loc_sram_val  = (c == 0 && sram_diag_en_i) ? sram_port_req_valid_i : {3'b000, hop_pop_comb};
            assign loc_sram_we   = (c == 0 && sram_diag_en_i) ? sram_port_req_we_i    : 4'b0001;
            assign loc_sram_usr  = (c == 0 && sram_diag_en_i) ? sram_port_user_id_i   : {4{cluster_user_id_i}};
            assign loc_sram_pos  = (c == 0 && sram_diag_en_i) ? sram_port_token_pos_i : {4{cluster_tok_pos_i}};
            assign loc_sram_head = (c == 0 && sram_diag_en_i) ? sram_port_head_sub_i  : 16'h3210;
            assign loc_sram_wdat = (c == 0 && sram_diag_en_i) ? sram_port_wdata_i     : {4{hop_fifo_mem[hop_rd_ptr_q]}};
            assign loc_err_en    = (c == 0 && sram_diag_en_i) ? sram_err_inj_en_i     : 1'b0;
            assign loc_err_port  = (c == 0 && sram_diag_en_i) ? sram_err_inj_port_i   : 2'd0;
            assign loc_err_bit   = (c == 0 && sram_diag_en_i) ? sram_err_inj_bit_i    : 6'd0;
            assign loc_err_dbl   = (c == 0 && sram_diag_en_i) ? sram_err_inj_double_i : 1'b0;

            taalas_hc2_disagg_sram_fabric #(
                .NUM_PORTS (NUM_PORTS),
                .NUM_BANKS (NUM_BANKS),
                .BANK_DEPTH(BANK_DEPTH)
            ) u_disagg_sram (
                .clk                  (clk),
                .rst_n                (rst_n),
                .mla_mode_en_i        (mla_mode_en_i),
                .ret_sleep_i          (1'b0),
                .user_slot_clear_i    (16'h0000),
                .port_req_valid_i     (loc_sram_val),
                .port_req_we_i        (loc_sram_we),
                .port_user_id_i       (loc_sram_usr),
                .port_token_pos_i     (loc_sram_pos),
                .port_head_sub_i      (loc_sram_head),
                .port_wdata_i         (loc_sram_wdat),
                .err_inj_en_i         (loc_err_en),
                .err_inj_port_i       (loc_err_port),
                .err_inj_bit_i        (loc_err_bit),
                .err_inj_double_i     (loc_err_dbl),
                .port_grant_o         (die_sram_grant[c]),
                .port_phys_bank_o     (die_sram_pbank[c]),
                .port_resp_valid_o    (die_sram_rvalid[c]),
                .port_resp_rdata_o    (die_sram_rdata[c]),
                .port_sec_err_o       (die_sram_sec[c]),
                .port_ded_err_o       (die_sram_ded[c]),
                .kv_words_per_token_o (die_sram_words_tok[c]),
                .kv_compress_ratio_x_o(die_sram_comp_rat[c]),
                .total_grant_cnt_o    (die_sram_gcnt[c]),
                .bank_stall_cnt_o     (die_sram_scnt[c]),
                .sec_fix_cnt_o        (die_sram_sec_cnt[c]),
                .ded_det_cnt_o        (die_sram_ded_cnt[c])
            );

            // H3: Hardwired MoE Top-K Gating & Expert Tile Clock-Gating Router
            logic [NUM_EXPERTS*DIM_GATE*4-1:0] rom_gate_w_mxfp4;
            logic [NUM_EXPERTS*8-1:0]          rom_gate_w_e8m0;
            always_comb begin
                for (int e = 0; e < NUM_EXPERTS; e++) begin
                    rom_gate_w_e8m0[e*8 +: 8] = 8'd127 + 8'((e + c) & 32'h7);
                    for (int d = 0; d < DIM_GATE; d++) begin
                        rom_gate_w_mxfp4[(e*DIM_GATE + d)*4 +: 4] = 4'((e * 3 + d + c + 1) & 32'h7);
                    end
                end
            end

            taalas_hc2_moe_mla_router #(
                .NUM_EXPERTS(NUM_EXPERTS),
                .DIM_GATE   (DIM_GATE),
                .MAX_K      (4),
                .NUM_CHIPS  (NUM_CHIPS)
            ) u_moe_router (
                .clk                      (clk),
                .rst_n                    (rst_n),
                .valid_i                  (hop_pop_comb || cluster_tok_valid_i),
                .topk_mode_i              (topk_mode_i),
                .shared_expert_en_i       (shared_expert_en_i),
                .token_id_i               (cluster_tok_id_i ^ 8'(c)),
                .act_mxfp4_i              (cluster_act_mxfp4_i),
                .act_e8m0_i               (cluster_act_e8m0_i),
                .gate_w_mxfp4_i           (rom_gate_w_mxfp4),
                .gate_w_e8m0_i            (rom_gate_w_e8m0),
                .expert_bias_i            ('0),
                .valid_o                  (die_moe_valid[c]),
                .topk_mode_o              (die_moe_topk_m[c]),
                .shared_expert_active_o   (die_moe_shared_a[c]),
                .sel_expert_id_o          (die_moe_sel_ids[c]),
                .dst_chip_id_o            (die_moe_dst_chips[c]),
                .gate_weight_q88_o        (die_moe_weights[c]),
                .sel_expert_score_o       (die_moe_scores[c]),
                .active_expert_mask_o     (die_moe_act_mask[c]),
                .clock_gated_expert_mask_o(die_moe_cg_mask[c]),
                .active_expert_cnt_o      (die_moe_act_cnt[c]),
                .gated_expert_cnt_o       (die_moe_cg_cnt[c]),
                .routed_token_cnt_o       (die_moe_tok_cnt[c]),
                .cum_gated_expert_cycles_o(die_moe_cg_cycles[c])
            );

            // M3: Multiplierless OCP MXFP4 Active Expert Dot-Product Compute Lane
            taalas_mxfp4_hc2_mac_lane #(
                .BLOCK_SIZE(BLOCK_SIZE),
                .NUM_LANES (NUM_LANES)
            ) u_mxfp4_mac (
                .clk        (clk),
                .rst_n      (rst_n),
                .valid_i    (hop_pop_comb || cluster_tok_valid_i),
                .act_mxfp4_i(cluster_act_mxfp4_i[BLOCK_SIZE*4-1:0]),
                .act_e8m0_i (cluster_act_e8m0_i),
                .w_mxfp4_i  (rom_gate_w_mxfp4[NUM_LANES*BLOCK_SIZE*4-1:0]),
                .w_e8m0_i   (rom_gate_w_e8m0[NUM_LANES*8-1:0]),
                .valid_o    (die_mac_valid[c]),
                .dot_int16_o(die_mac_dot16[c]),
                .exp_comb_o (die_mac_exp10[c]),
                .fp32_out_o (die_mac_fp32[c]),
                .nan_flag_o ()
            );

            // 1-Cycle Registered Physical C2C SerDes Inter-Die Channel (Die c TX -> Die c+1 RX)
            logic        c2c_wire_valid_q;
            logic [87:0] c2c_wire_frame_q;
            logic        c2c_wire_err_q;
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    c2c_wire_valid_q <= 1'b0;
                    c2c_wire_frame_q <= 88'd0;
                    c2c_wire_err_q   <= 1'b0;
                end else begin
                    c2c_wire_valid_q <= c2c_wire_valid[c];
                    c2c_wire_frame_q <= c2c_wire_frame[c];
                    c2c_wire_err_q   <= c2c_link_err_inj_i[c] && (!die_c2c_replay_active_o[c]);
                end
            end

            // H2: C2C 112G SerDes Link-Layer Retry (LLR) Controller (Hop c -> c+1)
            taalas_hc2_c2c_llr_serdes_ctrl #(
                .PAYLOAD_W   (64),
                .SEQ_W       (8),
                .CRC_W       (16),
                .REPLAY_DEPTH(16),
                .MAX_CREDITS (16)
            ) u_c2c_llr (
                .clk                (clk),
                .rst_n              (rst_n),
                .tx_flit_valid_i    (hop_pop_comb),
                .tx_flit_data_i     (hop_fifo_mem[hop_rd_ptr_q]),
                .tx_flit_ready_o    (die_c2c_tx_ready[c]),
                .rx_flit_valid_o    (die_c2c_rx_valid[c]),
                .rx_flit_data_o     (die_c2c_rx_data[c]),
                .rx_flit_seq_o      (die_c2c_rx_seq[c]),
                .rx_credit_return_i (die_c2c_rx_valid[c]),
                .c2c_tx_valid_o     (c2c_wire_valid[c]),
                .c2c_tx_frame_o     (c2c_wire_frame[c]),
                .c2c_rx_credit_ret_i(c2c_wire_cred_ret[c]),
                .c2c_rx_valid_i     (c2c_wire_valid_q),
                .c2c_rx_frame_i     (c2c_wire_frame_q),
                .link_err_inj_i     (c2c_wire_err_q),
                .c2c_tx_credit_ret_o(c2c_wire_cred_ret[c]),
                .c2c_rx_ack_valid_i (c2c_wire_ack_val[c]),
                .c2c_rx_ack_nack_i  (c2c_wire_ack_nack[c]),
                .c2c_rx_ack_seq_i   (c2c_wire_ack_seq[c]),
                .c2c_tx_ack_valid_o (c2c_wire_ack_val[c]),
                .c2c_tx_ack_nack_o  (c2c_wire_ack_nack[c]),
                .c2c_tx_ack_seq_o   (c2c_wire_ack_seq[c]),
                .replay_active_o    (die_c2c_replay_active_o[c]),
                .rx_crc_err_o       (die_c2c_crc_err_o[c]),
                .tx_credits_avail_o (die_c2c_creds[c]),
                .unacked_cnt_o      (die_c2c_unacked[c]),
                .tx_frame_cnt_o     (die_c2c_tx_cnt[c]),
                .rx_good_cnt_o      (die_c2c_rx_cnt[c]),
                .llr_replay_cnt_o   (die_c2c_rep_cnt[c]),
                .crc_err_cnt_o      (die_c2c_crc_cnt[c])
            );
        end
    endgenerate

    // -------------------------------------------------------------------------
    // 3. Cluster Egress, 3D-SRAM Diagnostic Mux & Multi-Die Telemetry Reduction
    // -------------------------------------------------------------------------
    assign sram_port_grant_o        = die_sram_grant[0];
    assign sram_port_phys_bank_o    = die_sram_pbank[0];
    assign sram_port_resp_valid_o   = die_sram_rvalid[0];
    assign sram_port_resp_rdata_o   = die_sram_rdata[0];
    assign sram_port_sec_err_o      = die_sram_sec[0];
    assign sram_port_ded_err_o      = die_sram_ded[0];
    assign sram_kv_compress_ratio_o = die_sram_comp_rat[0];

    assign cluster_out_valid_o = die_c2c_rx_valid[NUM_CHIPS-1];
    assign cluster_out_flit_o  = die_c2c_rx_data[NUM_CHIPS-1];
    assign cluster_out_seq_o   = die_c2c_rx_seq[NUM_CHIPS-1];
    assign cluster_out_fp32_o  = die_mac_fp32[NUM_CHIPS-1][31:0];

    logic unused_sub_telemetry_q;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            unused_sub_telemetry_q <= 1'b0;
        end else begin
            logic red_xor;
            red_xor = 1'b0;
            for (int i = 0; i < NUM_CHIPS; i++) begin
                red_xor = red_xor ^ (^die_in_seq[i]) ^ (^die_sram_words_tok[i]) ^
                          (^die_sram_gcnt[i]) ^ (^die_sram_scnt[i]) ^ (^die_sram_ded_cnt[i]) ^
                          die_moe_valid[i] ^ die_moe_topk_m[i] ^ die_moe_shared_a[i] ^
                          (^die_moe_dst_chips[i]) ^ (^die_moe_weights[i]) ^ (^die_moe_scores[i]) ^
                          (^die_moe_act_cnt[i]) ^ (^die_moe_cg_cnt[i]) ^ (^die_moe_tok_cnt[i]) ^
                          die_mac_valid[i] ^ (^die_mac_dot16[i]) ^ (^die_mac_exp10[i]) ^
                          (^die_mac_fp32[i]) ^ (^die_c2c_creds[i]) ^ (^die_c2c_unacked[i]);
            end
            unused_sub_telemetry_q <= red_xor;
        end
    end

    always_comb begin
        cluster_tx_frames_o           = 16'd0;
        cluster_rx_good_o             = 16'd0;
        cluster_llr_replays_o         = 16'd0;
        cluster_crc_errors_o          = 16'd0;
        cluster_sec_fixes_o           = 16'd0;
        cluster_gated_expert_cycles_o = 32'd0;
        for (int i = 0; i < NUM_CHIPS; i++) begin
            die_active_experts_o[i*16 +: 16] = die_moe_act_mask[i];
            die_gated_experts_o[i*16 +: 16]  = die_moe_cg_mask[i];
            die_sel_expert_ids_o[i*16 +: 16] = die_moe_sel_ids[i];
            cluster_tx_frames_o              = cluster_tx_frames_o   + die_c2c_tx_cnt[i];
            cluster_rx_good_o                = cluster_rx_good_o     + die_c2c_rx_cnt[i];
            cluster_llr_replays_o            = cluster_llr_replays_o + die_c2c_rep_cnt[i];
            cluster_crc_errors_o             = cluster_crc_errors_o  + die_c2c_crc_cnt[i];
            cluster_sec_fixes_o              = cluster_sec_fixes_o   + die_sram_sec_cnt[i];
            cluster_gated_expert_cycles_o    = cluster_gated_expert_cycles_o + die_moe_cg_cycles[i];
        end
    end

    // -------------------------------------------------------------------------
    // 4. Inline SVA & Yosys Formal SAT Verification Properties (H4)
    //    - PROP_HC2_CLUSTER_NO_CORRUPT_HOP: No C2C link ever forwards a frame
    //      on the cycle following a CRC error.
    //    - PROP_HC2_CLUSTER_MLA_8X_INVARIANT: In DeepSeek-R1 MLA mode, every
    //      die's disaggregated 3D-SRAM reports an 8x KV compression ratio.
    //    - PROP_HC2_CLUSTER_MOE_SAVINGS: Every die's MoE router maintains
    //      clock_gated_experts == ~active_experts across all 16 expert tiles.
    // -------------------------------------------------------------------------
    logic [NUM_CHIPS-1:0] crc_err_prev_q;
    logic                 formal_no_corrupt_hop;
    logic                 formal_moe_savings_ok;
    logic                 formal_mla_8x_ok;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) crc_err_prev_q <= '0;
        else        crc_err_prev_q <= die_c2c_crc_err_o;
    end

    always_comb begin
        formal_no_corrupt_hop = 1'b1;
        formal_moe_savings_ok = 1'b1;
        formal_mla_8x_ok      = 1'b1;
        for (int i = 0; i < NUM_CHIPS; i++) begin
            if (crc_err_prev_q[i] && die_c2c_rx_valid[i]) formal_no_corrupt_hop = 1'b0;
            if (die_moe_cg_mask[i] != ~die_moe_act_mask[i]) formal_moe_savings_ok = 1'b0;
            if (mla_mode_en_i && (die_sram_comp_rat[i] != 4'd8)) formal_mla_8x_ok = 1'b0;
        end
    end

    always_ff @(posedge clk) begin
        if (rst_n) begin
            PROP_HC2_CLUSTER_NO_CORRUPT_HOP: assert (formal_no_corrupt_hop);
            PROP_HC2_CLUSTER_MOE_SAVINGS: assert (formal_moe_savings_ok);
            PROP_HC2_CLUSTER_MLA_8X_INVARIANT: assert (
                formal_mla_8x_ok && (unused_sub_telemetry_q || !unused_sub_telemetry_q)
            );
        end
    end

endmodule
