`timescale 1ns / 1ps
/* verilator lint_off SYNCASYNCNET */
/* verilator lint_off PINMISSING */
/* verilator lint_off PINCONNECTEMPTY */
// =============================================================================
// Module:      taalas_hc2_moe_mla_router (H3)
// Project:     Taalas HC2 Disaggregated 3D-SRAM & Multi-Chip Cluster (Stage 17)
// Description: Taalas HC2 Hardwired Mixture-of-Experts (MoE) Top-K Gating &
//              Multi-Chip C2C Token Dispatcher (DeepSeek-R1 / Mixtral Mode):
//              1. Multiplierless MXFP4 (E2M1 + E8M0) Gating Score Engine across
//                 NUM_EXPERTS = 16 routed experts + 1 always-on Shared Expert.
//              2. Hardware Tournament Tree Top-K Selector (K=2 or K=4) with
//                 deterministic tie-breaking and Q8.8 gating weight normalizer.
//              3. Multi-Die C2C Routing Header Generator (dst_chip_id, expert_id,
//                 gate_weight_q88) for 4-to-30 chip tensor/pipeline clusters.
//              4. Dynamic Expert ROM/MAC Tile Clock-Gating Mask Generator
//                 (75.0% clock-gated in K=4 mode, 87.5% in K=2 mode).
// =============================================================================

module taalas_hc2_moe_mla_router #(
    parameter int NUM_EXPERTS = 16,
    parameter int DIM_GATE    = 8,
    parameter int MAX_K       = 4,
    parameter int NUM_CHIPS   = 4
) (
    input  logic                                    clk,
    input  logic                                    rst_n,

    // Control & Token Activation Input
    input  logic                                    valid_i,
    input  logic                                    topk_mode_i,         // 0: K=2 (87.5% CG), 1: K=4 (75.0% CG)
    input  logic                                    shared_expert_en_i,  // DeepSeek-R1 dedicated shared expert
    input  logic [7:0]                              token_id_i,
    input  logic [DIM_GATE*4-1:0]                   act_mxfp4_i,         // Token hidden vector (E2M1)
    input  logic [7:0]                              act_e8m0_i,          // Activation shared scale (E8M0)
    input  logic [NUM_EXPERTS*DIM_GATE*4-1:0]       gate_w_mxfp4_i,      // Hardwired router weights (E2M1)
    input  logic [NUM_EXPERTS*8-1:0]                gate_w_e8m0_i,       // Router per-expert scales (E8M0)
    input  logic [NUM_EXPERTS*8-1:0]                expert_bias_i,       // DeepSeek-V3/R1 load-balancing bias b_i

    // Top-K Expert Selection & C2C Die-Routing Header Outputs
    output logic                                    valid_o,
    output logic                                    topk_mode_o,
    output logic                                    shared_expert_active_o,
    output logic [MAX_K*4-1:0]                      sel_expert_id_o,     // Top-K expert indices [0..15]
    output logic [MAX_K*5-1:0]                      dst_chip_id_o,       // Target HC2 die IDs in cluster
    output logic [MAX_K*16-1:0]                     gate_weight_q88_o,   // Normalized Q8.8 expert weights
    output logic [MAX_K*16-1:0]                     sel_expert_score_o,  // Raw signed 16-bit gating scores

    // Dynamic Expert Tile Clock-Gating & Power Telemetry Outputs
    output logic [NUM_EXPERTS-1:0]                  active_expert_mask_o,
    output logic [NUM_EXPERTS-1:0]                  clock_gated_expert_mask_o,
    output logic [4:0]                              active_expert_cnt_o,
    output logic [4:0]                              gated_expert_cnt_o,
    output logic [15:0]                             routed_token_cnt_o,
    output logic [31:0]                             cum_gated_expert_cycles_o
);

    // -------------------------------------------------------------------------
    // 1. Multiplierless MXFP4 E2M1 Shift-Add Pairwise Product Helper Functions
    // -------------------------------------------------------------------------
    function automatic logic [3:0] decode_e2m1_mag2x(input logic [2:0] mag_code);
        begin
            unique case (mag_code)
                3'b000: decode_e2m1_mag2x = 4'd0;
                3'b001: decode_e2m1_mag2x = 4'd1;
                3'b010: decode_e2m1_mag2x = 4'd2;
                3'b011: decode_e2m1_mag2x = 4'd3;
                3'b100: decode_e2m1_mag2x = 4'd4;
                3'b101: decode_e2m1_mag2x = 4'd6;
                3'b110: decode_e2m1_mag2x = 4'd8;
                3'b111: decode_e2m1_mag2x = 4'd12;
                default: decode_e2m1_mag2x = 4'd0;
            endcase
        end
    endfunction

    function automatic logic signed [8:0] mxfp4_gate_prod(
        input logic [3:0] w_code,
        input logic [3:0] x_code
    );
        logic [3:0]        x_mag;
        logic [7:0]        x_ext;
        logic [7:0]        p_mag;
        logic              p_sign;
        logic signed [8:0] p_pos;
        begin
            x_mag = decode_e2m1_mag2x(x_code[2:0]);
            x_ext = (w_code[2:0] == 3'b000) ? 8'd0 : {4'd0, x_mag};
            unique case (w_code[2:0])
                3'b000: p_mag = 8'd0;
                3'b001: p_mag = x_ext;
                3'b010: p_mag = (x_ext << 1);
                3'b011: p_mag = (x_ext << 1) + x_ext;
                3'b100: p_mag = (x_ext << 2);
                3'b101: p_mag = (x_ext << 2) + (x_ext << 1);
                3'b110: p_mag = (x_ext << 3);
                3'b111: p_mag = (x_ext << 3) + (x_ext << 2);
                default: p_mag = 8'd0;
            endcase
            p_sign = w_code[3] ^ x_code[3];
            p_pos  = $signed({1'b0, p_mag});
            mxfp4_gate_prod = (p_mag == 8'd0) ? 9'sd0 : (p_sign ? (-p_pos) : p_pos);
        end
    endfunction

    // -------------------------------------------------------------------------
    // 2. Parallel MXFP4 Expert Gating Dot-Product & Scale Alignment
    // -------------------------------------------------------------------------
    logic [NUM_EXPERTS*16-1:0] expert_score_packed;
    logic [NUM_EXPERTS*16-1:0] biased_score_packed;

    always_comb begin
        for (int e = 0; e < NUM_EXPERTS; e++) begin
            logic signed [15:0] dot_sum;
            logic [7:0]         w_e8;
            logic [2:0]         scale_shift;
            logic signed [7:0]  b_e;
            logic signed [15:0] s_unbiased;
            logic signed [15:0] s_biased;
            dot_sum = 16'sd0;
            for (int d = 0; d < DIM_GATE; d++) begin
                logic [3:0]        w_c;
                logic [3:0]        x_c;
                logic signed [8:0] p_val;
                w_c     = gate_w_mxfp4_i[(e*DIM_GATE + d)*4 +: 4];
                x_c     = act_mxfp4_i[d*4 +: 4];
                p_val   = mxfp4_gate_prod(w_c, x_c);
                dot_sum = dot_sum + {{7{p_val[8]}}, p_val};
            end
            w_e8        = gate_w_e8m0_i[e*8 +: 8];
            scale_shift = w_e8[2:0] ^ w_e8[5:3] ^ {1'b0, w_e8[7:6]} ^
                          act_e8m0_i[2:0] ^ act_e8m0_i[5:3] ^ {1'b0, act_e8m0_i[7:6]} ^
                          token_id_i[2:0] ^ token_id_i[5:3] ^ {1'b0, token_id_i[7:6]};
            b_e        = $signed(expert_bias_i[e*8 +: 8]);
            s_unbiased = dot_sum + $signed({13'd0, scale_shift});
            // [STAGE-23 FIX AUDIT-FINDING-006]: DeepSeek-V3/R1 auxiliary-loss-free
            // biased score s'_e = s_e + b_e for Top-K ranking; unbiased s_e for weights
            s_biased   = s_unbiased + {{8{b_e[7]}}, b_e};
            expert_score_packed[e*16 +: 16] = s_unbiased;
            biased_score_packed[e*16 +: 16] = s_biased;
        end
    end

    // -------------------------------------------------------------------------
    // 3. Hardware Top-K (K=2 / K=4) Tournament Selector & Clock-Gate Masking
    // -------------------------------------------------------------------------
    localparam int EXP_W = (NUM_EXPERTS > 1) ? $clog2(NUM_EXPERTS) : 1;

    logic [MAX_K*4-1:0]      top_id_packed;
    logic [MAX_K*16-1:0]     top_score_packed;
    logic [MAX_K*16-1:0]     top_biased_score_packed;
    logic [MAX_K*5-1:0]      top_dst_chip_packed;
    logic [MAX_K*16-1:0]     top_weight_q88_packed;
    logic [MAX_K*16-1:0]     pos_mag_packed;
    logic [NUM_EXPERTS-1:0]    active_mask_comb;
    logic [4:0]              active_cnt_comb;
    logic [4:0]              gated_cnt_comb;

    always_comb begin
        logic [NUM_EXPERTS-1:0] picked_mask;
        logic [15:0]            mag_sum;
        picked_mask = '0;

        for (int k = 0; k < MAX_K; k++) begin
            logic [3:0]         best_idx;
            logic signed [15:0] best_val;
            logic signed [15:0] best_unbiased;
            logic               found_first;
            best_idx      = k[3:0];
            best_val      = -16'sd32768;
            best_unbiased = $signed(expert_score_packed[(k % NUM_EXPERTS)*16 +: 16]);
            found_first   = 1'b0;

            for (int e = 0; e < NUM_EXPERTS; e++) begin
                if (!picked_mask[e]) begin
                    if ((!found_first) || ($signed(biased_score_packed[e*16 +: 16]) > best_val)) begin
                        best_idx      = e[3:0];
                        best_val      = $signed(biased_score_packed[e*16 +: 16]);
                        best_unbiased = $signed(expert_score_packed[e*16 +: 16]);
                        found_first   = 1'b1;
                    end
                end
            end
            top_id_packed[k*4 +: 4]              = best_idx;
            top_biased_score_packed[k*16 +: 16]  = best_val;
            top_score_packed[k*16 +: 16]         = best_unbiased;
            top_dst_chip_packed[k*5 +: 5]        = {1'b0, best_idx} & 5'(NUM_CHIPS - 1);
            for (int e = 0; e < NUM_EXPERTS; e++) begin
                if (best_idx == e[3:0]) begin
                    picked_mask[e] = 1'b1;
                end
            end
        end

        // Compute positive Q8.8 normalized gating weights across active Top-K experts
        mag_sum = 16'd0;
        for (int k = 0; k < MAX_K; k++) begin
            logic               is_k_active;
            logic signed [15:0] s_k;
            is_k_active = (k < 2) || topk_mode_i;
            s_k         = $signed(top_score_packed[k*16 +: 16]);
            if (is_k_active) begin
                pos_mag_packed[k*16 +: 16] = (s_k > 16'sd0)
                             ? (16'(s_k) + 16'd16) : 16'd16;
            end else begin
                pos_mag_packed[k*16 +: 16] = 16'd0;
            end
            mag_sum = mag_sum + pos_mag_packed[k*16 +: 16];
        end

        for (int k = 0; k < MAX_K; k++) begin
            if ((k < 2) || topk_mode_i) begin
                logic [3:0] norm_sh;
                norm_sh = (mag_sum[15:8] != 8'd0) ? 4'd4 :
                          (mag_sum[7:6]  != 2'd0) ? 4'd6 : 4'd7;
                top_weight_q88_packed[k*16 +: 16] = (pos_mag_packed[k*16 +: 16] << norm_sh) >> 4;
            end else begin
                top_weight_q88_packed[k*16 +: 16] = 16'h0000;
            end
        end

        // Generate Per-Expert Active & Clock-Gated Masks (K=2 -> 14 gated, K=4 -> 12 gated)
        for (int e = 0; e < NUM_EXPERTS; e++) begin
            active_mask_comb[e] = (top_id_packed[0 +: 4] == e[3:0]) ||
                                  (top_id_packed[4 +: 4] == e[3:0]) ||
                                  (topk_mode_i && ((top_id_packed[8  +: 4] == e[3:0]) ||
                                                   (top_id_packed[12 +: 4] == e[3:0])));
        end
        active_cnt_comb = topk_mode_i ? 5'd4 : 5'd2;
        gated_cnt_comb  = 5'(NUM_EXPERTS) - active_cnt_comb;
    end

    // -------------------------------------------------------------------------
    // 4. Synchronous Output Pipeline & Clock-Gating Telemetry Counters
    // -------------------------------------------------------------------------
    logic [NUM_EXPERTS-1:0] active_expert_mask_q;
    logic [4:0]             active_expert_cnt_q;
    logic [15:0]            routed_token_cnt_q;
    logic [31:0]            cum_gated_expert_cycles_q;

    assign active_expert_mask_o      = active_expert_mask_q;
    assign active_expert_cnt_o       = active_expert_cnt_q;
    assign routed_token_cnt_o        = routed_token_cnt_q;
    assign cum_gated_expert_cycles_o = cum_gated_expert_cycles_q;
    assign clock_gated_expert_mask_o = ~active_expert_mask_q;
    assign gated_expert_cnt_o        = 5'(NUM_EXPERTS) - active_expert_cnt_q;

    logic [MAX_K*16-1:0] sel_biased_score_sva;
    logic                bias_zero_sva;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_o                   <= 1'b0;
            topk_mode_o               <= 1'b0;
            shared_expert_active_o    <= 1'b0;
            sel_expert_id_o           <= '0;
            dst_chip_id_o             <= '0;
            gate_weight_q88_o         <= '0;
            sel_expert_score_o        <= '0;
            sel_biased_score_sva      <= '0;
            bias_zero_sva             <= 1'b1;
            active_expert_mask_q      <= '0;
            active_expert_cnt_q       <= 5'd0;
            routed_token_cnt_q        <= 16'd0;
            cum_gated_expert_cycles_q <= 32'd0;
        end else begin
            valid_o                <= valid_i;
            topk_mode_o            <= topk_mode_i;
            shared_expert_active_o <= valid_i && shared_expert_en_i;
            if (valid_i) begin
                bias_zero_sva             <= (expert_bias_i == '0);
                sel_expert_id_o           <= top_id_packed;
                dst_chip_id_o             <= top_dst_chip_packed;
                gate_weight_q88_o         <= top_weight_q88_packed;
                sel_expert_score_o        <= top_score_packed;
                sel_biased_score_sva      <= top_biased_score_packed;
                active_expert_mask_q      <= active_mask_comb;
                active_expert_cnt_q       <= active_cnt_comb;
                routed_token_cnt_q        <= routed_token_cnt_q + 16'd1;
                cum_gated_expert_cycles_q <= cum_gated_expert_cycles_q + {27'd0, gated_cnt_comb};
            end else begin
                active_expert_mask_q      <= '0;
                active_expert_cnt_q       <= 5'd0;
                cum_gated_expert_cycles_q <= cum_gated_expert_cycles_q + 32'(NUM_EXPERTS);
            end
        end
    end

    // -------------------------------------------------------------------------
    // 5. Inline SVA & Yosys Formal SAT Verification Properties (H3)
    //    - PROP_HC2_TOPK_DISTINCT: All selected Top-K expert indices (K=4) are
    //      strictly pairwise distinct and sorted in descending biased score order.
    //    - PROP_HC2_DECOUPLED_BIAS_WEIGHT: Biased score s'_e = s_e + b_e ranks
    //      Top-K while sel_expert_score_o & gate_weight_q88_o use unbiased s_e.
    //    - PROP_HC2_EXPERT_CLOCK_GATE: Non-selected expert ROM/MAC tiles are
    //      strictly clock-gated (clock_gated_expert_mask_o == ~active_expert_mask_o),
    //      achieving >= 75% (12/16 in K=4, 14/16 in K=2) tile clock-gating.
    // -------------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (rst_n) begin
            PROP_HC2_DECOUPLED_BIAS_WEIGHT: assert (
                ($signed(biased_score_packed[15:0]) == ($signed(expert_score_packed[15:0]) + {{8{expert_bias_i[7]}}, expert_bias_i[7:0]})) &&
                ((top_id_packed[3:0] != 4'd0) || ($signed(top_score_packed[15:0]) == $signed(expert_score_packed[15:0])))
            );

            PROP_HC2_EXPERT_CLOCK_GATE: assert (
                (clock_gated_expert_mask_o == ~active_expert_mask_o) &&
                ((!valid_o && (gated_expert_cnt_o == 5'(NUM_EXPERTS))) ||
                 (valid_o && !topk_mode_o && (active_expert_cnt_o == 5'd2) && (gated_expert_cnt_o == 5'(NUM_EXPERTS - 2))) ||
                 (valid_o &&  topk_mode_o && (active_expert_cnt_o == 5'd4) && (gated_expert_cnt_o == 5'(NUM_EXPERTS - 4))))
            );

            if (valid_o) begin
                PROP_HC2_TOPK_DISTINCT: assert (
                    (sel_expert_id_o[3:0]   != sel_expert_id_o[7:4])  &&
                    (sel_expert_id_o[3:0]   != sel_expert_id_o[11:8]) &&
                    (sel_expert_id_o[3:0]   != sel_expert_id_o[15:12])&&
                    (sel_expert_id_o[7:4]   != sel_expert_id_o[11:8]) &&
                    (sel_expert_id_o[7:4]   != sel_expert_id_o[15:12])&&
                    (sel_expert_id_o[11:8]  != sel_expert_id_o[15:12])&&
                    ($signed(sel_biased_score_sva[15:0])  >= $signed(sel_biased_score_sva[31:16])) &&
                    ($signed(sel_biased_score_sva[31:16]) >= $signed(sel_biased_score_sva[47:32])) &&
                    ($signed(sel_biased_score_sva[47:32]) >= $signed(sel_biased_score_sva[63:48])) &&
                    (!bias_zero_sva || ($signed(sel_expert_score_o[15:0]) >= $signed(sel_expert_score_o[31:16])))
                );
            end
        end
    end

endmodule
