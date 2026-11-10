`timescale 1ns / 1ps
// =============================================================================
// Module:      taalas_swiglu_ffn_pipe (M11)
// Project:     Taalas HC1/HC2 Hardwired LLM Inference ASIC
// Description: Fused SwiGLU Feed-Forward Network Pipeline Combining Interleaved
//              Gate/Up Projections, 16-Segment Piecewise-Linear Sigmoid/SiLU
//              Non-Linearity, Element-Wise Hadamard Product (SiLU(g) * u),
//              Dynamic INT8 Re-Quantization, and Streaming Down-Projection Tree.
//
// Architectural Highlights:
//   1. Zero-Intermediate-SRAM Fused SwiGLU Execution:
//      Eliminates the 14,336-element intermediate FFN activation buffer in
//      Llama-3.1-8B by fusing Gate (W_gate * x) and Up (W_up * x) streams
//      directly into the PWL SiLU + Hadamard multiplier and W_down accumulator.
//   2. 16-Segment Piecewise-Linear Sigmoid & SiLU Engine (Q8.8 -> Q1.15 -> Q8.8):
//      Evaluates sigma(g) across [-8.0, +8.0] using 17 symmetric knot values
//      from Section 3.11.1 of the Microarchitecture Specification. Guarantees
//      SiLU(0) == 0, SiLU(g >= +8.0) == g (pass-through), and SiLU(g <= -8.0) == 0.
//   3. Integrated Multiplierless 3-Bit CSD Down-Projection Accumulator:
//      Streams Hadamard outputs h_c directly into a parallel W_down CSD tree.
// =============================================================================

module taalas_swiglu_ffn_pipe #(
    parameter int CHANNELS    = 16,
    parameter int DOWN_OUT_CH = 8,
    parameter int DATA_W      = 16
) (
    input  logic                                    clk,
    input  logic                                    rst_n,

    // Pipeline Control & Group Framing
    input  logic                                    valid_i,
    input  logic                                    first_ffn_grp_i,
    input  logic                                    last_ffn_grp_i,

    // Matched 16-Channel Gate (W_gate * x) and Up (W_up * x) Vectors in Q8.8
    input  logic [CHANNELS*DATA_W-1:0]              gate_vec_i,
    input  logic [CHANNELS*DATA_W-1:0]              up_vec_i,

    // Hardwired 3-Bit Signed CSD Weights for Streaming W_down Projection
    input  logic [DOWN_OUT_CH*CHANNELS*3-1:0]       w_down_3b_i,
    input  logic                                    rne_en_i = 1'b0,

    // Pipelined Outputs (Stage 1: SiLU, Stage 2: Hadamard, Stage 3: W_down Acc)
    output logic                                    silu_valid_o,
    output logic [CHANNELS*DATA_W-1:0]              silu_vec_o,
    output logic                                    hadamard_valid_o,
    output logic [CHANNELS*DATA_W-1:0]              hadamard_vec_o,
    output logic [CHANNELS*8-1:0]                   hadamard_int8_o,
    output logic                                    down_valid_o,
    output logic                                    down_done_o,
    output logic [DOWN_OUT_CH*24-1:0]               down_acc_o
);

    // -------------------------------------------------------------------------
    // Helper 1: 17-Knot Symmetric Sigmoid LUT on [-8.0, +8.0] in Q1.15
    // Exact values from Section 3.11.1 of Stage 2 Microarchitecture Spec:
    // LUT_sigma(-8..+8) = {0.0003, 0.0009, 0.0025, 0.0067, 0.0180, 0.0474,
    //   0.1192, 0.2689, 0.5000, 0.7311, 0.8808, 0.9526, 0.9820, 0.9933,
    //   0.9975, 0.9991, 0.9997} scaled by 32768.
    // -------------------------------------------------------------------------
    function automatic logic [15:0] sigmoid_knot_q15(input logic [4:0] knot_idx);
        begin
            unique case (knot_idx)
                5'd0:  sigmoid_knot_q15 = 16'd10;
                5'd1:  sigmoid_knot_q15 = 16'd29;
                5'd2:  sigmoid_knot_q15 = 16'd82;
                5'd3:  sigmoid_knot_q15 = 16'd220;
                5'd4:  sigmoid_knot_q15 = 16'd590;
                5'd5:  sigmoid_knot_q15 = 16'd1553;
                5'd6:  sigmoid_knot_q15 = 16'd3906;
                5'd7:  sigmoid_knot_q15 = 16'd8811;
                5'd8:  sigmoid_knot_q15 = 16'd16384; // sigma(0.0) = 0.500000
                5'd9:  sigmoid_knot_q15 = 16'd23957;
                5'd10: sigmoid_knot_q15 = 16'd28862;
                5'd11: sigmoid_knot_q15 = 16'd31215;
                5'd12: sigmoid_knot_q15 = 16'd32178;
                5'd13: sigmoid_knot_q15 = 16'd32548;
                5'd14: sigmoid_knot_q15 = 16'd32686;
                5'd15: sigmoid_knot_q15 = 16'd32739;
                default: sigmoid_knot_q15 = 16'd32758;
            endcase
        end
    endfunction

    // -------------------------------------------------------------------------
    // Helper 2: 16-Segment Piecewise-Linear Sigmoid & SiLU Evaluator (Q8.8)
    // For g <= -8.0 (-2048): sigma = 0     -> SiLU(g) = 0
    // For g >= +8.0 (+2048): sigma = 32768 -> SiLU(g) = g
    // For g in (-8.0, +8.0): linear interpolation between knot[seg] and knot[seg+1]
    // -------------------------------------------------------------------------
    function automatic logic [15:0] eval_sigmoid_pwl_q15(input logic signed [15:0] g_q8_8);
        logic [11:0]        shifted_g;
        logic [3:0]         seg_idx;
        logic [7:0]         frac_u8;
        logic [15:0]        y0_q15;
        logic [15:0]        y1_q15;
        logic [15:0]        interp_term;
        begin
            if (g_q8_8 <= -16'sd2048) begin
                eval_sigmoid_pwl_q15 = 16'd0;
            end else if (g_q8_8 >= 16'sd2048) begin
                eval_sigmoid_pwl_q15 = 16'd32768;
            end else begin
                shifted_g   = 12'(g_q8_8 + 16'sd2048); // in [1, 4095]
                seg_idx     = shifted_g[11:8];         // in [0, 15]
                frac_u8     = shifted_g[7:0];          // in [0, 255]
                y0_q15      = sigmoid_knot_q15({1'b0, seg_idx});
                y1_q15      = sigmoid_knot_q15({1'b0, seg_idx} + 5'd1);
                interp_term = 16'(((25'(y1_q15) - 25'(y0_q15)) * 25'(frac_u8) + 25'd128) >> 8);
                eval_sigmoid_pwl_q15 = y0_q15 + interp_term;
            end
        end
    endfunction

    function automatic logic signed [15:0] eval_silu_pwl_q8_8(input logic signed [15:0] g_q8_8);
        logic [15:0]        sig_q15;
        logic signed [32:0] prod_q23;
        begin
            if (g_q8_8 == 16'sd0 || g_q8_8 <= -16'sd2048) begin
                eval_silu_pwl_q8_8 = 16'sd0;
            end else if (g_q8_8 >= 16'sd2048) begin
                eval_silu_pwl_q8_8 = g_q8_8;
            end else begin
                sig_q15  = eval_sigmoid_pwl_q15(g_q8_8);
                prod_q23 = 33'(g_q8_8) * 33'($signed({1'b0, sig_q15}));
                eval_silu_pwl_q8_8 = 16'((prod_q23 + 33'sd16384) >>> 15);
            end
        end
    endfunction

    // -------------------------------------------------------------------------
    // Helper 3: Multiplierless 3-Bit CSD Shift-Add Product for W_down
    // -------------------------------------------------------------------------
    function automatic logic signed [18:0] csd3_shift_add(
        input logic signed [15:0] act_val,
        input logic [2:0]         w_code3b
    );
        logic signed [18:0] x_ext;
        begin
            x_ext = 19'(act_val);
            unique case (w_code3b)
                3'b000: csd3_shift_add = 19'sd0;                   //  0
                3'b001: csd3_shift_add = x_ext;                    // +1
                3'b010: csd3_shift_add = (x_ext <<< 1);            // +2
                3'b011: csd3_shift_add = (x_ext <<< 1) + x_ext;    // +3
                3'b100: csd3_shift_add = -(x_ext <<< 2);           // -4
                3'b101: csd3_shift_add = -(x_ext <<< 1) - x_ext;   // -3
                3'b110: csd3_shift_add = -(x_ext <<< 1);           // -2
                default: csd3_shift_add = -x_ext;                  // -1
            endcase
        end
    endfunction

    // =========================================================================
    // Stage 1: 16-Channel Parallel PWL SiLU Evaluation
    // =========================================================================
    logic                   valid_s1_q;
    logic                   first_s1_q;
    logic                   last_s1_q;
    logic signed [15:0]     gate_ref_s1_q [0:CHANNELS-1];
    logic signed [15:0]     silu_s1_q     [0:CHANNELS-1];
    logic signed [15:0]     up_s1_q       [0:CHANNELS-1];
    logic signed [15:0]     silu_s1_d     [0:CHANNELS-1];

    always_comb begin
        for (int c = 0; c < CHANNELS; c++) begin
            silu_s1_d[c] = eval_silu_pwl_q8_8($signed(gate_vec_i[c*DATA_W +: DATA_W]));
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_s1_q <= 1'b0;
            first_s1_q <= 1'b0;
            last_s1_q  <= 1'b0;
            for (int c = 0; c < CHANNELS; c++) begin
                gate_ref_s1_q[c] <= 16'sd0;
                silu_s1_q[c]     <= 16'sd0;
                up_s1_q[c]       <= 16'sd0;
            end
        end else begin
            valid_s1_q <= valid_i;
            if (valid_i) begin
                first_s1_q <= first_ffn_grp_i;
                last_s1_q  <= last_ffn_grp_i;
                for (int c = 0; c < CHANNELS; c++) begin
                    gate_ref_s1_q[c] <= $signed(gate_vec_i[c*DATA_W +: DATA_W]);
                    silu_s1_q[c]     <= silu_s1_d[c];
                    up_s1_q[c]       <= $signed(up_vec_i[c*DATA_W +: DATA_W]);
                end
            end
        end
    end

    // =========================================================================
    // Stage 2: Element-Wise Hadamard Product (h_c = SiLU(g_c) * u_c) & INT8 Quant
    // =========================================================================
    logic                   valid_s2_q;
    logic                   first_s2_q;
    logic                   last_s2_q;
    logic signed [15:0]     hadamard_s2_q [0:CHANNELS-1];
    logic signed [7:0]      had_int8_s2_q [0:CHANNELS-1];

    logic signed [15:0]     hadamard_s2_d [0:CHANNELS-1];
    logic signed [7:0]      had_int8_s2_d [0:CHANNELS-1];

    always_comb begin
        for (int c = 0; c < CHANNELS; c++) begin
            logic signed [31:0] prod_q16;
            logic signed [31:0] prod_rnd;
            logic signed [23:0] shifted_q8;
            logic signed [17:0] had_rnd;
            logic signed [17:0] int8_scaled;
            prod_q16    = 32'(silu_s1_q[c]) * 32'(up_s1_q[c]);
            // [STAGE-28 FIX AUDIT-FINDING-011]: Optional IEEE-754 RNE unbiased tie-breaking
            if (rne_en_i && (prod_q16[7:0] == 8'h80)) begin
                prod_rnd = prod_q16 + (prod_q16[8] ? 32'sd128 : 32'sd0);
            end else begin
                prod_rnd = prod_q16 + 32'sd128;
            end
            shifted_q8  = 24'(prod_rnd >>> 8);
            if (shifted_q8 > 24'sd32767) begin
                hadamard_s2_d[c] = 16'sd32767;
            end else if (shifted_q8 < -24'sd32768) begin
                hadamard_s2_d[c] = -16'sd32768;
            end else begin
                hadamard_s2_d[c] = shifted_q8[15:0];
            end

            // Dynamic INT8 quantization (Q8.8 -> INT8 via RNE_8 + [-128, +127] clamp)
            // [STAGE-29 LOCKSTEP UVM FIX]: Widen had_rnd & int8_scaled to 18-bit signed so
            // hadamard_s2_d[c] in [+32640, +32767] + 128 = +32768..+32895 saturates to +127 instead of wrapping to -128!
            if (rne_en_i && (hadamard_s2_d[c][7:0] == 8'h80)) begin
                had_rnd = 18'(hadamard_s2_d[c]) + (hadamard_s2_d[c][8] ? 18'sd128 : 18'sd0);
            end else begin
                had_rnd = 18'(hadamard_s2_d[c]) + 18'sd128;
            end
            int8_scaled = had_rnd >>> 8;
            if (int8_scaled > 18'sd127) begin
                had_int8_s2_d[c] = 8'sd127;
            end else if (int8_scaled < -18'sd128) begin
                had_int8_s2_d[c] = -8'sd128;
            end else begin
                had_int8_s2_d[c] = int8_scaled[7:0];
            end
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_s2_q <= 1'b0;
            first_s2_q <= 1'b0;
            last_s2_q  <= 1'b0;
            for (int c = 0; c < CHANNELS; c++) begin
                hadamard_s2_q[c] <= 16'sd0;
                had_int8_s2_q[c] <= 8'sd0;
            end
        end else begin
            valid_s2_q <= valid_s1_q;
            if (valid_s1_q) begin
                first_s2_q <= first_s1_q;
                last_s2_q  <= last_s1_q;
                for (int c = 0; c < CHANNELS; c++) begin
                    hadamard_s2_q[c] <= hadamard_s2_d[c];
                    had_int8_s2_q[c] <= had_int8_s2_d[c];
                end
            end
        end
    end

    // =========================================================================
    // Stage 3: Streaming W_down Multiplierless 3-Bit CSD Accumulator
    // =========================================================================
    logic                   down_valid_q;
    logic                   down_done_q;
    logic signed [23:0]     down_acc_q [0:DOWN_OUT_CH-1];
    logic signed [23:0]     down_grp_d [0:DOWN_OUT_CH-1];

    always_comb begin
        for (int o = 0; o < DOWN_OUT_CH; o++) begin
            logic signed [23:0] grp_sum;
            grp_sum = 24'sd0;
            for (int c = 0; c < CHANNELS; c++) begin
                logic [2:0] w_code;
                w_code  = w_down_3b_i[(o*CHANNELS + c)*3 +: 3];
                grp_sum = grp_sum + 24'(csd3_shift_add(hadamard_s2_q[c], w_code));
            end
            down_grp_d[o] = grp_sum;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            down_valid_q <= 1'b0;
            down_done_q  <= 1'b0;
            for (int o = 0; o < DOWN_OUT_CH; o++) begin
                down_acc_q[o] <= 24'sd0;
            end
        end else begin
            down_valid_q <= valid_s2_q;
            down_done_q  <= valid_s2_q && last_s2_q;
            if (valid_s2_q) begin
                for (int o = 0; o < DOWN_OUT_CH; o++) begin
                    if (first_s2_q) begin
                        down_acc_q[o] <= down_grp_d[o];
                    end else begin
                        down_acc_q[o] <= down_acc_q[o] + down_grp_d[o];
                    end
                end
            end
        end
    end

    always_comb begin
        silu_valid_o     = valid_s1_q;
        hadamard_valid_o = valid_s2_q;
        down_valid_o     = down_valid_q;
        down_done_o      = down_done_q;
        for (int c = 0; c < CHANNELS; c++) begin
            silu_vec_o[c*DATA_W +: DATA_W]     = silu_s1_q[c];
            hadamard_vec_o[c*DATA_W +: DATA_W] = hadamard_s2_q[c];
            hadamard_int8_o[c*8 +: 8]          = had_int8_s2_q[c];
        end
        for (int o = 0; o < DOWN_OUT_CH; o++) begin
            down_acc_o[o*24 +: 24] = down_acc_q[o];
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
        if (rst_n && past_valid_q && valid_s1_q) begin
            // PROP_M11_SILU_ZERO: Exact zero preservation SiLU(0) == 0
            if (gate_ref_s1_q[0] == 16'sd0) begin
                assert (silu_s1_q[0] == 16'sd0);
            end
            // PROP_M11_SILU_POS_ASYMP: Asymptotic pass-through SiLU(g >= +8.0) == g
            if (gate_ref_s1_q[0] >= 16'sd2048) begin
                assert (silu_s1_q[0] == gate_ref_s1_q[0]);
            end
            // PROP_M11_SILU_NEG_CLAMP: Asymptotic negative clamping SiLU(g <= -8.0) == 0
            if (gate_ref_s1_q[0] <= -16'sd2048) begin
                assert (silu_s1_q[0] == 16'sd0);
            end
        end
    end

endmodule
