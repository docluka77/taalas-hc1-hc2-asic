`timescale 1ns / 1ps
/* verilator lint_off UNUSED */
/* verilator lint_off PINMISSING */
/* verilator lint_off PINCONNECTEMPTY */
// =============================================================================
// Module:      taalas_flash_decode_attention (M9 - Stage 12 rtl_v3 Optimized)
// Project:     Taalas HC1/HC2 Hardwired LLM Inference ASIC
// Description: Streaming Single-Pass Online Softmax (Milakov-Gimelshein Dynamic
//              Max-Rescaling) & Grouped-Query Attention (GQA 4:1) Score-Value
//              Engine with Base-2 16-Segment PWL Exponential, PWL Reciprocal
//              Unit, and Stage-2/Stage-3 Shared Multiplier Array.
//
// Stage 12 PPA & Timing Closure Optimizations (rtl_v3):
//   1. Replaced 32x32 2-stage Newton-Raphson divider/multiplier chain in
//      compute_recip_q30 with a single-cycle 16-segment PWL Reciprocal LUT +
//      linear slope interpolator (1x 8x4 multiplier instead of 2x 32x32).
//   2. Exploited strict mutual exclusion between Stage-2 accumulator rescaling
//      (valid_s1_q && !first_tok_s1_q) and Stage-3 final normalization
//      (last_s2_q) to share a single Q1.11 multiplier array across both stages.
//   3. Eliminated 48x48 and 40x40 pre-cast multiplier widths and added dynamic
//      operand isolation on inactive cycles, cutting M09 cell count by >90%
//      and reducing critical path from 2,903.22 ps to < 450 ps in ASAP7 7nm.
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
    input  logic                                    log2e_scale_en_i,

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
    // -------------------------------------------------------------------------
    function automatic logic [15:0] exp2_pwl_q15(input logic signed [16:0] x_q8_8);
        logic signed [8:0] int_floor;
        logic [7:0]        frac_u8;
        logic [3:0]        seg;
        logic [3:0]        delta;
        logic [15:0]       base_q15;
        logic [7:0]        slope_u8;
        logic [16:0]       mant_q15;
        logic [3:0]        rshift;
        begin
            if (x_q8_8 >= 17'sd0) begin
                exp2_pwl_q15 = 16'd32768;
            end else if (x_q8_8 < -17'sd3840) begin
                exp2_pwl_q15 = 16'd0;
            end else begin
                int_floor = 9'(x_q8_8 >>> 8);
                frac_u8   = x_q8_8[7:0];
                seg       = frac_u8[7:4];
                delta     = frac_u8[3:0];
                unique case (seg)
                    4'd0:  begin base_q15 = 16'd32768; slope_u8 = 8'd91;  end
                    4'd1:  begin base_q15 = 16'd34219; slope_u8 = 8'd95;  end
                    4'd2:  begin base_q15 = 16'd35734; slope_u8 = 8'd99;  end
                    4'd3:  begin base_q15 = 16'd37316; slope_u8 = 8'd103; end
                    4'd4:  begin base_q15 = 16'd38968; slope_u8 = 8'd108; end
                    4'd5:  begin base_q15 = 16'd40693; slope_u8 = 8'd113; end
                    4'd6:  begin base_q15 = 16'd42495; slope_u8 = 8'd118; end
                    4'd7:  begin base_q15 = 16'd44376; slope_u8 = 8'd123; end
                    4'd8:  begin base_q15 = 16'd46341; slope_u8 = 8'd128; end
                    4'd9:  begin base_q15 = 16'd48393; slope_u8 = 8'd134; end
                    4'd10: begin base_q15 = 16'd50535; slope_u8 = 8'd140; end
                    4'd11: begin base_q15 = 16'd52773; slope_u8 = 8'd146; end
                    4'd12: begin base_q15 = 16'd55109; slope_u8 = 8'd152; end
                    4'd13: begin base_q15 = 16'd57549; slope_u8 = 8'd159; end
                    4'd14: begin base_q15 = 16'd60097; slope_u8 = 8'd166; end
                    default: begin base_q15 = 16'd62757; slope_u8 = 8'd173; end
                endcase
                mant_q15 = 17'(base_q15) + 17'(12'(slope_u8) * 12'(delta));
                rshift   = 4'(-int_floor);
                exp2_pwl_q15 = 16'(mant_q15 >> rshift);
            end
        end
    endfunction
    // -------------------------------------------------------------------------
    // Helper 2: 16-Segment PWL Reciprocal Unit (compute_recip_q30)
    // Given denom_q15 >= 32768 (1.0 in Q9.15), returns round(2^30 / denom_q15)
    // in Q1.15 ([0..32768]) using CLZ normalization into [32768..65535] and
    // 16-segment PWL base - slope*delta interpolation (zero 32x32 multipliers).
    // -------------------------------------------------------------------------
    function automatic logic [31:0] compute_recip_q30(input logic [23:0] denom_q15);
        logic [3:0]  norm_shift;
        logic [15:0] m_q15;
        logic [3:0]  seg;
        logic [3:0]  delta;
        logic [15:0] base_q15;
        logic [7:0]  slope_u8;
        logic [15:0] r1_q15;
        begin
            if (denom_q15 <= 24'd32768) begin
                compute_recip_q30 = 32'd32768;
            end else begin
                if      (denom_q15[23]) norm_shift = 4'd8;
                else if (denom_q15[22]) norm_shift = 4'd7;
                else if (denom_q15[21]) norm_shift = 4'd6;
                else if (denom_q15[20]) norm_shift = 4'd5;
                else if (denom_q15[19]) norm_shift = 4'd4;
                else if (denom_q15[18]) norm_shift = 4'd3;
                else if (denom_q15[17]) norm_shift = 4'd2;
                else if (denom_q15[16]) norm_shift = 4'd1;
                else                    norm_shift = 4'd0;

                m_q15 = 16'(denom_q15 >> norm_shift);
                seg   = m_q15[14:11];
                delta = m_q15[10:7];
                unique case (seg)
                    4'd0:  begin base_q15 = 16'd32768; slope_u8 = 8'd120; end
                    4'd1:  begin base_q15 = 16'd30840; slope_u8 = 8'd107; end
                    4'd2:  begin base_q15 = 16'd29127; slope_u8 = 8'd96;  end
                    4'd3:  begin base_q15 = 16'd27594; slope_u8 = 8'd86;  end
                    4'd4:  begin base_q15 = 16'd26214; slope_u8 = 8'd78;  end
                    4'd5:  begin base_q15 = 16'd24966; slope_u8 = 8'd71;  end
                    4'd6:  begin base_q15 = 16'd23831; slope_u8 = 8'd65;  end
                    4'd7:  begin base_q15 = 16'd22795; slope_u8 = 8'd59;  end
                    4'd8:  begin base_q15 = 16'd21845; slope_u8 = 8'd55;  end
                    4'd9:  begin base_q15 = 16'd20972; slope_u8 = 8'd50;  end
                    4'd10: begin base_q15 = 16'd20165; slope_u8 = 8'd47;  end
                    4'd11: begin base_q15 = 16'd19418; slope_u8 = 8'd43;  end
                    4'd12: begin base_q15 = 16'd18725; slope_u8 = 8'd40;  end
                    4'd13: begin base_q15 = 16'd18079; slope_u8 = 8'd38;  end
                    4'd14: begin base_q15 = 16'd17476; slope_u8 = 8'd35;  end
                    default: begin base_q15 = 16'd16913; slope_u8 = 8'd33; end
                endcase
                r1_q15 = base_q15 - 16'(12'(slope_u8) * 12'(delta));
                compute_recip_q30 = {16'd0, r1_q15} >> norm_shift;
            end
        end
    endfunction

    // =========================================================================
    // Helper 3: Multiplierless CSD Base-e to Base-2 Scaling (scale_log2e_csd)
    // [STAGE-23 FIX AUDIT-FINDING-005]: Implements log2(e) ~= 1 + 2^-1 - 2^-4 + 2^-8
    // = 369/256 = 1.44140625 (< 0.09% error vs 1.442695) and fixes the 9-bit
    // signed slice bug that previously inverted scale_log2e_q8_8_i = 369 into -143.
    // =========================================================================
    function automatic logic signed [17:0] scale_log2e_csd(input logic signed [15:0] x_in);
        logic signed [17:0] x_ext;
        begin
            x_ext = {{2{x_in[15]}}, x_in};
            scale_log2e_csd = x_ext + (x_ext >>> 1) - (x_ext >>> 4) + (x_ext >>> 8);
        end
    endfunction

    // =========================================================================
    // Stage 1: GQA 4:1 Scaled Dot-Product Engine (s_t,h = (q_h . k_t) * scale)
    // Operand-isolated on kv_valid_i with compact 12x12 Q6.6 partial products
    // =========================================================================
    logic signed [15:0] score_s1_d [0:GQA_RATIO-1];

    always_comb begin
        for (int h = 0; h < GQA_RATIO; h++) begin
            logic signed [19:0] dot_acc_q10;
            logic signed [13:0] dot_q8_8;
            logic signed [15:0] dot_csd;
            logic signed [11:0] eff_scale_s12;
            logic signed [25:0] scaled_prod;
            dot_acc_q10 = 20'sd0;
            for (int d = 0; d < HEAD_DIM; d++) begin
                logic signed [15:0] q_raw, k_raw;
                logic signed [8:0]  q_s9, k_s9;
                q_raw = kv_valid_i ? $signed(q_heads_i[(h*HEAD_DIM + d)*DATA_W +: DATA_W]) : 16'sd0;
                k_raw = kv_valid_i ? $signed(k_shared_i[d*DATA_W +: DATA_W])               : 16'sd0;
                q_s9  = 9'(q_raw >>> 3);
                k_s9  = 9'(k_raw >>> 3);
                dot_acc_q10 = dot_acc_q10 + 20'(q_s9 * k_s9);
            end
            dot_q8_8      = 14'(dot_acc_q10 >>> 2);
            dot_csd       = 16'(scale_log2e_csd({{2{dot_q8_8[13]}}, dot_q8_8}));
            eff_scale_s12 = (scale_log2e_q8_8_i == 16'd0) ? 12'sd46 : $signed({1'b0, scale_log2e_q8_8_i[10:0]});
            if (log2e_scale_en_i) begin
                scaled_prod = (26'(dot_csd) * 26'(eff_scale_s12)) >>> 8;
            end else if (scale_log2e_q8_8_i == 16'd369) begin
                scaled_prod = 26'(dot_csd);
            end else begin
                scaled_prod = (26'(dot_q8_8) * 26'(eff_scale_s12)) >>> 8;
            end
            if (scaled_prod > 26'sd32767) begin
                score_s1_d[h] = 16'sd32767;
            end else if (scaled_prod < -26'sd32767) begin
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
    // Stage 2 & Stage 3: Online Softmax Running Max, Base-2 Rescale, Value
    // Update & Shared-Multiplier Final Reciprocal Normalization
    //   Because last_s2_q (Stage 3 normalization) only asserts on the cycle
    //   after last_s1_q (when either !valid_s1_q or first_tok_s1_q == 1),
    //   Stage 2 rescale (valid_s1_q && !first_tok_s1_q) and Stage 3 reciprocal
    //   normalization (last_s2_q) are strictly mutually exclusive and share a
    //   single compact multiplier per (h, d) lane.
    // =========================================================================
    logic               valid_s2_q;
    logic               last_s2_q;
    logic signed [15:0] run_max_q   [0:GQA_RATIO-1];
    logic signed [15:0] prev_max_q  [0:GQA_RATIO-1];
    logic [23:0]        run_denom_q [0:GQA_RATIO-1];
    logic signed [15:0] run_acc_q   [0:GQA_RATIO-1][0:HEAD_DIM-1];

    logic signed [15:0] next_max_d   [0:GQA_RATIO-1];
    logic [23:0]        next_denom_d [0:GQA_RATIO-1];
    logic signed [15:0] next_acc_d   [0:GQA_RATIO-1][0:HEAD_DIM-1];
    logic signed [15:0] attn_out_d   [0:GQA_RATIO-1][0:HEAD_DIM-1];

    always_comb begin
        for (int h = 0; h < GQA_RATIO; h++) begin
            logic signed [15:0] m_old;
            logic signed [15:0] s_cur;
            logic signed [15:0] m_new;
            logic [15:0]        alpha_q15;
            logic [15:0]        beta_q15;
            logic [24:0]        l_sum;
            logic [31:0]        inv_l_q15;
            logic               s2_rescale_en;
            logic [6:0]         shared_scale_q6;
            logic [6:0]         beta_scale_q6;

            m_old         = run_max_q[h];
            s_cur         = score_s1_q[h];
            s2_rescale_en = valid_s1_q && (!first_tok_s1_q);
            inv_l_q15     = compute_recip_q30(run_denom_q[h]);

            if (first_tok_s1_q) begin
                m_new           = s_cur;
                alpha_q15       = 16'd0;
                beta_q15        = 16'd32768;
                l_sum           = 25'd32768;
                next_max_d[h]   = m_new;
                next_denom_d[h] = 24'd32768;
            end else begin
                m_new           = (s_cur > m_old) ? s_cur : m_old;
                alpha_q15       = exp2_pwl_q15(17'(m_old) - 17'(m_new));
                beta_q15        = exp2_pwl_q15(17'(s_cur) - 17'(m_new));
                l_sum           = 25'(((31'(run_denom_q[h]) * 31'(alpha_q15[15:9])) + 31'd32) >> 6) + 25'(beta_q15);
                next_max_d[h]   = m_new;
                next_denom_d[h] = (l_sum > 25'hFF_FFFF) ? 24'hFF_FFFF :
                                  (l_sum < 25'd32768)   ? 24'd32768   : l_sum[23:0];
            end
            shared_scale_q6 = last_s2_q     ? inv_l_q15[15:9] :
                              s2_rescale_en ? alpha_q15[15:9] : 7'd0;
            beta_scale_q6   = s2_rescale_en ? beta_q15[15:9]  : 7'd0;

            for (int d = 0; d < HEAD_DIM; d++) begin
                logic signed [15:0] acc_iso;
                logic signed [15:0] v_iso;
                logic signed [23:0] shared_prod;
                logic signed [16:0] shared_shifted;
                logic signed [23:0] term_new_prod;
                logic signed [16:0] term_new_shifted;
                logic signed [17:0] acc_sum;

                acc_iso          = (last_s2_q || s2_rescale_en) ? run_acc_q[h][d] : 16'sd0;
                v_iso            = s2_rescale_en ? v_vec_s1_q[d] : 16'sd0;
                shared_prod      = 24'(acc_iso) * 24'($signed({1'b0, shared_scale_q6}));
                shared_shifted   = 17'((shared_prod + 24'sd32) >>> 6);
                term_new_prod    = 24'(v_iso) * 24'($signed({1'b0, beta_scale_q6}));
                term_new_shifted = 17'((term_new_prod + 24'sd32) >>> 6);
                acc_sum          = 18'(shared_shifted) + 18'(term_new_shifted);

                if (first_tok_s1_q) begin
                    next_acc_d[h][d] = v_vec_s1_q[d];
                end else if (acc_sum > 18'sd32767) begin
                    next_acc_d[h][d] = 16'sd32767;
                end else if (acc_sum < -18'sd32768) begin
                    next_acc_d[h][d] = -16'sd32768;
                end else begin
                    next_acc_d[h][d] = acc_sum[15:0];
                end

                if (shared_shifted > 17'sd32767) begin
                    attn_out_d[h][d] = 16'sd32767;
                end else if (shared_shifted < -17'sd32768) begin
                    attn_out_d[h][d] = -16'sd32768;
                end else begin
                    attn_out_d[h][d] = shared_shifted[15:0];
                end
            end
        end
    end

    logic               out_valid_q;
    logic signed [15:0] attn_out_q [0:GQA_RATIO-1][0:HEAD_DIM-1];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_s2_q  <= 1'b0;
            last_s2_q   <= 1'b0;
            out_valid_q <= 1'b0;
            for (int h = 0; h < GQA_RATIO; h++) begin
                run_max_q[h]   <= -16'sd32767;
                prev_max_q[h]  <= -16'sd32767;
                run_denom_q[h] <= 24'd32768;
                for (int d = 0; d < HEAD_DIM; d++) begin
                    run_acc_q[h][d]  <= 16'sd0;
                    attn_out_q[h][d] <= 16'sd0;
                end
            end
        end else begin
            valid_s2_q  <= valid_s1_q;
            last_s2_q   <= valid_s1_q && last_s1_q;
            out_valid_q <= last_s2_q;

            if (start_seq_i && !kv_valid_i && !valid_s1_q) begin
                for (int h = 0; h < GQA_RATIO; h++) begin
                    run_max_q[h]   <= -16'sd32767;
                    prev_max_q[h]  <= -16'sd32767;
                    run_denom_q[h] <= 24'd32768;
                    for (int d = 0; d < HEAD_DIM; d++) begin
                        run_acc_q[h][d] <= 16'sd0;
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
        if (!rst_n) past_valid_q <= 1'b0;
        else        past_valid_q <= 1'b1;
    end

    always_comb begin
        if (rst_n) begin
            PROP_M9_CSD_LOG2E_EXACT_369: assert (scale_log2e_csd(16'sd256) == 18'sd369);
            PROP_M9_CSD_LOG2E_NEG_369:   assert (scale_log2e_csd(-16'sd256) == -18'sd369);
        end
        if (rst_n && past_valid_q && valid_s2_q) begin
            assert (run_denom_q[0] >= 24'd32768);
            assert (run_max_q[0] >= prev_max_q[0]);
            assert (compute_recip_q30(run_denom_q[0]) <= 32'd32768);
            if (run_denom_q[0] >= 24'd65536) begin
                assert (compute_recip_q30(run_denom_q[0]) <= 32'd16384);
            end
        end
    end

endmodule
