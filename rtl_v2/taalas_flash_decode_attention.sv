`timescale 1ns / 1ps
// =============================================================================
// Module:      taalas_flash_decode_attention (M9)
// Project:     Taalas HC1/HC2 Hardwired LLM Inference ASIC
// Description: Streaming Single-Pass Online Softmax (Milakov-Gimelshein Dynamic
//              Max-Rescaling) & Grouped-Query Attention (GQA 4:1) Score-Value
//              Engine with Base-2 16-Segment PWL Exponential & Reciprocal LUT.
//
// Architectural Highlights:
//   1. Single-Pass Flash-Decoding Without Materializing T x T Attention Matrix:
//      Streams Key/Value tokens (k_t, v_t) directly from on-die 6T SRAM (M5/M6)
//      in a single pass, maintaining running maximum m_t, running denominator
//      l_t, and unnormalized value accumulator O_t across GQA_RATIO = 4 heads.
//   2. Hardware-Native Base-2 Exponential (exp2_pwl):
//      Scales Q*K dot-products by (1/sqrt(d_k))*log2(e) and evaluates 2^x on
//      x <= 0 via integer floor decomposition x = I + F, a 16-segment PWL
//      mantissa LUT in Q1.15, and barrel right-shift by (-I).
//   3. Pipelined Final Reciprocal Normalization (O_T / l_T):
//      Normalizes the accumulated output vector upon kv_last_i using CLZ +
//      16-entry Reciprocal Seed LUT + Newton-Raphson refinement.
// =============================================================================

module taalas_flash_decode_attention #(
    parameter int HEAD_DIM  = 16,
    parameter int GQA_RATIO = 4,
    parameter int DATA_W    = 16
) (
    input  logic                                    clk,
    input  logic                                    rst_n,

    // Sequence Control Strobes
    input  logic                                    start_seq_i,
    input  logic                                    kv_valid_i,
    input  logic                                    kv_last_i,

    // GQA 4:1 Query Heads & Shared Broadcast Key/Value Vectors (Q8.8 Signed)
    input  logic [GQA_RATIO*HEAD_DIM*DATA_W-1:0]    q_heads_i,
    input  logic [HEAD_DIM*DATA_W-1:0]              k_shared_i,
    input  logic [HEAD_DIM*DATA_W-1:0]              v_shared_i,
    input  logic [15:0]                             scale_log2e_q8_8_i,

    // Streaming & Final Normalized Outputs
    output logic                                    step_valid_o,
    output logic                                    out_valid_o,
    output logic [GQA_RATIO*HEAD_DIM*DATA_W-1:0]    attn_out_o,
    output logic [GQA_RATIO*16-1:0]                 max_score_o,
    output logic [GQA_RATIO*24-1:0]                 denom_sum_o
);

    // -------------------------------------------------------------------------
    // Helper 1: Base-2 16-Segment Piecewise-Linear Exponential (exp2_pwl_q15)
    // Input x_q8_8 <= 0 in signed Q8.8. Returns 2^(x_q8_8 / 256) in unsigned
    // Q1.15 ([0..32768], where 32768 = 1.000000).
    // Exact LUT values from Stage 2 Specification Section 5.3.
    // -------------------------------------------------------------------------
    function automatic logic [15:0] exp2_pwl_q15(input logic signed [16:0] x_q8_8);
        logic signed [8:0] int_floor;
        logic [7:0]        frac_u8;
        logic [3:0]        seg;
        logic [3:0]        delta;
        logic [15:0]       base_q15;
        logic [15:0]       slope_q15;
        logic [16:0]       mant_q15;
        logic [3:0]        rshift;
        begin
            if (x_q8_8 >= 17'sd0) begin
                exp2_pwl_q15 = 16'd32768;
            end else if (x_q8_8 < -17'sd3840) begin
                // Clamp x < -15.0 to 0
                exp2_pwl_q15 = 16'd0;
            end else begin
                int_floor = 9'(x_q8_8 >>> 8); // in [-15, -1]
                frac_u8   = x_q8_8[7:0];
                seg       = frac_u8[7:4];
                delta     = frac_u8[3:0];
                unique case (seg)
                    4'd0:  begin base_q15 = 16'd32768; slope_q15 = 16'd91;  end
                    4'd1:  begin base_q15 = 16'd34219; slope_q15 = 16'd95;  end
                    4'd2:  begin base_q15 = 16'd35734; slope_q15 = 16'd99;  end
                    4'd3:  begin base_q15 = 16'd37316; slope_q15 = 16'd103; end
                    4'd4:  begin base_q15 = 16'd38968; slope_q15 = 16'd108; end
                    4'd5:  begin base_q15 = 16'd40693; slope_q15 = 16'd113; end
                    4'd6:  begin base_q15 = 16'd42495; slope_q15 = 16'd118; end
                    4'd7:  begin base_q15 = 16'd44376; slope_q15 = 16'd123; end
                    4'd8:  begin base_q15 = 16'd46341; slope_q15 = 16'd128; end
                    4'd9:  begin base_q15 = 16'd48393; slope_q15 = 16'd134; end
                    4'd10: begin base_q15 = 16'd50535; slope_q15 = 16'd140; end
                    4'd11: begin base_q15 = 16'd52773; slope_q15 = 16'd146; end
                    4'd12: begin base_q15 = 16'd55109; slope_q15 = 16'd152; end
                    4'd13: begin base_q15 = 16'd57549; slope_q15 = 16'd159; end
                    4'd14: begin base_q15 = 16'd60097; slope_q15 = 16'd166; end
                    default: begin base_q15 = 16'd62757; slope_q15 = 16'd173; end
                endcase
                mant_q15 = 17'(base_q15) + 17'(slope_q15 * {12'd0, delta});
                rshift   = 4'(-int_floor);
                exp2_pwl_q15 = 16'(mant_q15 >> rshift);
            end
        end
    endfunction

    // -------------------------------------------------------------------------
    // Helper 2: Pipelined Reciprocal LUT + Newton-Raphson (inv_denom_q30)
    // Given denom_q15 >= 32768 (1.0 in Q9.15), returns round(2^30 / denom_q15)
    // using CLZ normalization into [32768..65535], 16-entry seed LUT, and
    // 1-step Newton-Raphson refinement r_1 = r_0 * (2 - m * r_0).
    // -------------------------------------------------------------------------
    function automatic logic [15:0] recip_lut_q15(input logic [3:0] top4);
        begin
            unique case (top4)
                4'd0:  recip_lut_q15 = 16'd63549;
                4'd1:  recip_lut_q15 = 16'd59918;
                4'd2:  recip_lut_q15 = 16'd56680;
                4'd3:  recip_lut_q15 = 16'd53773;
                4'd4:  recip_lut_q15 = 16'd51150;
                4'd5:  recip_lut_q15 = 16'd48771;
                4'd6:  recip_lut_q15 = 16'd46603;
                4'd7:  recip_lut_q15 = 16'd44620;
                4'd8:  recip_lut_q15 = 16'd42800;
                4'd9:  recip_lut_q15 = 16'd41121;
                4'd10: recip_lut_q15 = 16'd39569;
                4'd11: recip_lut_q15 = 16'd38130;
                4'd12: recip_lut_q15 = 16'd36792;
                4'd13: recip_lut_q15 = 16'd35545;
                4'd14: recip_lut_q15 = 16'd34380;
                default: recip_lut_q15 = 16'd33288;
            endcase
        end
    endfunction

    function automatic logic [31:0] compute_recip_q30(input logic [23:0] denom_q15);
        int          msb_idx;
        int          norm_shift;
        logic [15:0] m_q15;
        logic [15:0] r0_q15;
        logic [31:0] mr0_q30;
        logic [31:0] two_minus_mr0_q15;
        logic [31:0] r1_q30;
        int          out_rshift;
        begin
            if (denom_q15 <= 24'd32768) begin
                compute_recip_q30 = 32'd32768; // 1.0 in Q15 multiplier
            end else begin
                msb_idx = 15;
                for (int b = 15; b < 24; b++) begin
                    if (denom_q15[b]) begin
                        msb_idx = b;
                    end
                end
                norm_shift = msb_idx - 15;
                m_q15      = 16'(denom_q15 >> norm_shift); // in [32768, 65535] representing [1.0, 2.0)
                r0_q15     = recip_lut_q15(m_q15[14:11]); // in Q0.16 where 65536 = 1.0
                mr0_q30    = 32'(m_q15) * 32'(r0_q15);    // Q1.15 * Q0.16 = Q1.31
                // [STAGE-10 FIX BUG-HC1-001]: Use (32'd2 << 15) = 65536 (2.0 in Q1.15) instead of (32'd4 << 15)
                two_minus_mr0_q15 = (32'd2 << 15) - (mr0_q30 >> 16); // Q2.15
                r1_q30     = (32'(r0_q15) * two_minus_mr0_q15) >> 16; // Q0.15
                out_rshift = norm_shift;
                compute_recip_q30 = r1_q30 >> out_rshift;
            end
        end
    endfunction

    // =========================================================================
    // Stage 1: GQA 4:1 Scaled Dot-Product Engine (s_t,h = (q_h . k_t) * scale)
    // =========================================================================
    logic signed [15:0] score_s1_d [0:GQA_RATIO-1];

    always_comb begin
        for (int h = 0; h < GQA_RATIO; h++) begin
            logic signed [39:0] dot_acc;
            logic signed [15:0] eff_scale;
            logic signed [47:0] scaled_prod;
            dot_acc = 40'sd0;
            for (int d = 0; d < HEAD_DIM; d++) begin
                logic signed [15:0] q_elem;
                logic signed [15:0] k_elem;
                q_elem  = $signed(q_heads_i[(h*HEAD_DIM + d)*DATA_W +: DATA_W]);
                k_elem  = $signed(k_shared_i[d*DATA_W +: DATA_W]);
                dot_acc = dot_acc + (40'(q_elem) * 40'(k_elem));
            end
            // dot_acc is Q16.16 (from Q8.8 * Q8.8); shift right by 8 -> Q8.8
            eff_scale   = (scale_log2e_q8_8_i == 16'd0) ? 16'sd46 : $signed(scale_log2e_q8_8_i);
            scaled_prod = ((48'(dot_acc) >>> 8) * 48'(eff_scale)) >>> 8;
            if (scaled_prod > 48'sd32767) begin
                score_s1_d[h] = 16'sd32767;
            end else if (scaled_prod < -48'sd32767) begin
                score_s1_d[h] = -16'sd32767;
            end else begin
                score_s1_d[h] = scaled_prod[15:0];
            end
        end
    end

    logic               valid_s1_q;
    logic               last_s1_q;
    logic               first_tok_s1_q;
    logic               seq_active_q;
    logic signed [15:0] score_s1_q [0:GQA_RATIO-1];
    logic signed [15:0] v_vec_s1_q [0:HEAD_DIM-1];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_s1_q     <= 1'b0;
            last_s1_q      <= 1'b0;
            first_tok_s1_q <= 1'b0;
            seq_active_q   <= 1'b0;
            for (int h = 0; h < GQA_RATIO; h++) begin
                score_s1_q[h] <= -16'sd32767;
            end
            for (int d = 0; d < HEAD_DIM; d++) begin
                v_vec_s1_q[d] <= 16'sd0;
            end
        end else begin
            valid_s1_q <= kv_valid_i;
            last_s1_q  <= kv_valid_i && kv_last_i;
            if (start_seq_i && !kv_valid_i) begin
                seq_active_q <= 1'b0;
            end else if (kv_valid_i) begin
                first_tok_s1_q <= start_seq_i || (!seq_active_q);
                seq_active_q   <= kv_last_i ? 1'b0 : 1'b1;
                for (int h = 0; h < GQA_RATIO; h++) begin
                    score_s1_q[h] <= score_s1_d[h];
                end
                for (int d = 0; d < HEAD_DIM; d++) begin
                    v_vec_s1_q[d] <= $signed(v_shared_i[d*DATA_W +: DATA_W]);
                end
            end
        end
    end

    // =========================================================================
    // Stage 2: Online Softmax Running Max, Base-2 Rescale & Value Update
    //   m_t = max(m_{t-1}, s_t)
    //   alpha_t = 2^(m_{t-1} - m_t), beta_t = 2^(s_t - m_t)
    //   l_t = alpha_t * l_{t-1} + beta_t
    //   O_t = alpha_t * O_{t-1} + beta_t * v_t
    // =========================================================================
    logic               valid_s2_q;
    logic               last_s2_q;
    logic signed [15:0] run_max_q   [0:GQA_RATIO-1];
    logic signed [15:0] prev_max_q  [0:GQA_RATIO-1];
    logic [23:0]        run_denom_q [0:GQA_RATIO-1];
    logic signed [31:0] run_acc_q   [0:GQA_RATIO-1][0:HEAD_DIM-1];

    logic signed [15:0] next_max_d   [0:GQA_RATIO-1];
    logic [23:0]        next_denom_d [0:GQA_RATIO-1];
    logic signed [31:0] next_acc_d   [0:GQA_RATIO-1][0:HEAD_DIM-1];

    always_comb begin
        for (int h = 0; h < GQA_RATIO; h++) begin
            logic signed [15:0] m_old;
            logic signed [15:0] s_cur;
            logic signed [15:0] m_new;
            logic [15:0]        alpha_q15;
            logic [15:0]        beta_q15;
            logic [24:0]        l_sum;

            m_old = run_max_q[h];
            s_cur = score_s1_q[h];
            if (first_tok_s1_q) begin
                m_new            = s_cur;
                alpha_q15        = 16'd0;
                beta_q15         = 16'd32768;
                l_sum            = 25'd32768;
                next_max_d[h]    = m_new;
                next_denom_d[h]  = 24'd32768;
            end else begin
                m_new            = (s_cur > m_old) ? s_cur : m_old;
                alpha_q15        = exp2_pwl_q15(17'(m_old) - 17'(m_new));
                beta_q15         = exp2_pwl_q15(17'(s_cur) - 17'(m_new));
                l_sum            = 25'((40'(run_denom_q[h]) * 40'(alpha_q15) + 40'd16384) >> 15) + 25'(beta_q15);
                next_max_d[h]    = m_new;
                next_denom_d[h]  = (l_sum > 25'hFF_FFFF) ? 24'hFF_FFFF : l_sum[23:0];
            end

            for (int d = 0; d < HEAD_DIM; d++) begin
                logic signed [47:0] term_old;
                logic signed [47:0] term_new;
                term_old = (48'(run_acc_q[h][d]) * 48'($signed({1'b0, alpha_q15})) + 48'sd16384) >>> 15;
                term_new = (48'(v_vec_s1_q[d])   * 48'($signed({1'b0, beta_q15}))  + 48'sd16384) >>> 15;
                if (first_tok_s1_q) begin
                    next_acc_d[h][d] = 32'(v_vec_s1_q[d]);
                end else begin
                    next_acc_d[h][d] = 32'(term_old + term_new);
                end
            end
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_s2_q <= 1'b0;
            last_s2_q  <= 1'b0;
            for (int h = 0; h < GQA_RATIO; h++) begin
                run_max_q[h]   <= -16'sd32767;
                prev_max_q[h]  <= -16'sd32767;
                run_denom_q[h] <= 24'd32768;
                for (int d = 0; d < HEAD_DIM; d++) begin
                    run_acc_q[h][d] <= 32'sd0;
                end
            end
        end else begin
            valid_s2_q <= valid_s1_q;
            last_s2_q  <= valid_s1_q && last_s1_q;
            if (start_seq_i && !kv_valid_i && !valid_s1_q) begin
                for (int h = 0; h < GQA_RATIO; h++) begin
                    run_max_q[h]   <= -16'sd32767;
                    prev_max_q[h]  <= -16'sd32767;
                    run_denom_q[h] <= 24'd32768;
                    for (int d = 0; d < HEAD_DIM; d++) begin
                        run_acc_q[h][d] <= 32'sd0;
                    end
                end
            end else if (valid_s1_q) begin
                for (int h = 0; h < GQA_RATIO; h++) begin
                    prev_max_q[h]  <= first_tok_s1_q ? next_max_d[h] : run_max_q[h];
                    run_max_q[h]   <= next_max_d[h];
                    run_denom_q[h] <= next_denom_d[h];
                    for (int d = 0; d < HEAD_DIM; d++) begin
                        run_acc_q[h][d] <= next_acc_d[h][d];
                    end
                end
            end
        end
    end

    // =========================================================================
    // Stage 3: Final Reciprocal Normalization (attn_out = O_T * inv_denom)
    // =========================================================================
    logic               out_valid_q;
    logic signed [15:0] attn_out_q [0:GQA_RATIO-1][0:HEAD_DIM-1];
    logic signed [15:0] attn_out_d [0:GQA_RATIO-1][0:HEAD_DIM-1];

    always_comb begin
        for (int h = 0; h < GQA_RATIO; h++) begin
            logic [31:0] inv_l_q15;
            inv_l_q15 = compute_recip_q30(run_denom_q[h]);
            for (int d = 0; d < HEAD_DIM; d++) begin
                logic signed [47:0] norm_prod;
                logic signed [31:0] norm_shifted;
                norm_prod    = 48'(run_acc_q[h][d]) * 48'($signed({1'b0, inv_l_q15}));
                norm_shifted = 32'((norm_prod + 48'sd16384) >>> 15);
                if (norm_shifted > 32'sd32767) begin
                    attn_out_d[h][d] = 16'sd32767;
                end else if (norm_shifted < -32'sd32768) begin
                    attn_out_d[h][d] = -16'sd32768;
                end else begin
                    attn_out_d[h][d] = norm_shifted[15:0];
                end
            end
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_valid_q <= 1'b0;
            for (int h = 0; h < GQA_RATIO; h++) begin
                for (int d = 0; d < HEAD_DIM; d++) begin
                    attn_out_q[h][d] <= 16'sd0;
                end
            end
        end else begin
            out_valid_q <= last_s2_q;
            if (last_s2_q) begin
                for (int h = 0; h < GQA_RATIO; h++) begin
                    for (int d = 0; d < HEAD_DIM; d++) begin
                        attn_out_q[h][d] <= attn_out_d[h][d];
                    end
                end
            end
        end
    end

    always_comb begin
        step_valid_o = valid_s2_q;
        out_valid_o  = out_valid_q;
        for (int h = 0; h < GQA_RATIO; h++) begin
            max_score_o[h*16 +: 16] = run_max_q[h];
            denom_sum_o[h*24 +: 24] = run_denom_q[h];
            for (int d = 0; d < HEAD_DIM; d++) begin
                attn_out_o[(h*HEAD_DIM + d)*DATA_W +: DATA_W] = attn_out_q[h][d];
            end
        end
    end

    // =========================================================================
    // Formal Verification & Inline SVA Invariants (Yosys SAT & Verilator)
    // =========================================================================
    logic past_valid_q;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            past_valid_q <= 1'b0;
        end else begin
            past_valid_q <= 1'b1;
        end
    end

    always_comb begin
        if (rst_n && past_valid_q && valid_s2_q) begin
            // PROP_M9_DENOM_STRICT_POS: Running denominator l_t is strictly >= 1.0 (32768)
            assert (run_denom_q[0] >= 24'd32768);
            // PROP_M9_MAX_MONOTONIC: Running maximum m_t never decreases across a sequence
            assert (run_max_q[0] >= prev_max_q[0]);
            // PROP_BUG001_RECIP_UNIT_NORM: Newton-Raphson reciprocal is bounded <= 1.0 (32768) and exact at 2.0
            assert (compute_recip_q30(run_denom_q[0]) <= 32'd32768);
            if (run_denom_q[0] >= 24'd65536) begin
                assert (compute_recip_q30(run_denom_q[0]) <= 32'd16384);
            end
        end
    end

endmodule
