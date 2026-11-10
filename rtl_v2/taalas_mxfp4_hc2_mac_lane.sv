`timescale 1ns / 1ps
/* verilator lint_off SYNCASYNCNET */
// =============================================================================
// Module: taalas_mxfp4_hc2_mac_lane (M3)
// Description:
//   Taalas HC2 (2nd Generation TSMC N4P) Open Compute Project (OCP) MXFP4
//   Spatial Dot-Product Compute Macro (BLOCK_SIZE = 32, NUM_LANES = 8).
//
// Architectural Highlights:
//   1. Exact Integer-Aligned E2M1 Decoding (Zero Intra-Block FP Alignment Loss):
//      Every 4-bit E2M1 element ([3]=sign, [2:1]=exp, [0]=mant) in
//      {0, +-0.5, +-1.0, +-1.5, +-2.0, +-3.0, +-4.0, +-6.0}, when scaled by 2,
//      maps to an exact signed integer in {0, +-1, +-2, +-3, +-4, +-6, +-8, +-12}.
//   2. Multiplierless Shift-Add Pairwise Product:
//      Since |2*w| in {0, 1, 2, 3, 4, 6, 8, 12} has at most two set bits,
//      each E2M1 x E2M1 product is evaluated strictly via bit-shifts (<<1, <<2,
//      <<3) and a single 2-input adder without hardware multipliers.
//   3. Shared E8M0 Block Exponent Scaling & Exact IEEE-754 FP32 Normalization:
//      Combines block scales (Ew + Ex - 254 - 2) and normalizes the exact
//      16-bit integer inner product [-4608, +4608] into IEEE-754 FP32.
//
// E2M1 Encoding Table (scaled by 2x -> Exact INT5):
//   Code[2:0] | Exp | Mant | Float Val | 2x Integer | Shift-Add Realization
//   ----------+-----+------+-----------+------------+------------------------
//     3'b000  |  00 |   0  |    0.0    |      0     | 0 (Operand Isolated)
//     3'b001  |  00 |   1  |    0.5    |      1     | x
//     3'b010  |  01 |   0  |    1.0    |      2     | (x << 1)
//     3'b011  |  01 |   1  |    1.5    |      3     | (x << 1) + x
//     3'b100  |  10 |   0  |    2.0    |      4     | (x << 2)
//     3'b101  |  10 |   1  |    3.0    |      6     | (x << 2) + (x << 1)
//     3'b110  |  11 |   0  |    4.0    |      8     | (x << 3)
//     3'b111  |  11 |   1  |    6.0    |     12     | (x << 3) + (x << 2)
// =============================================================================

module taalas_mxfp4_hc2_mac_lane #(
    parameter int BLOCK_SIZE = 32,
    parameter int NUM_LANES  = 8
) (
    input  logic                              clk,
    input  logic                              rst_n,
    input  logic                              valid_i,
    input  logic [BLOCK_SIZE*4-1:0]           act_mxfp4_i,
    input  logic [7:0]                        act_e8m0_i,
    input  logic [NUM_LANES*BLOCK_SIZE*4-1:0] w_mxfp4_i,
    input  logic [NUM_LANES*8-1:0]            w_e8m0_i,

    output logic                              valid_o,
    output logic [NUM_LANES*16-1:0]           dot_int16_o,
    output logic [NUM_LANES*10-1:0]           exp_comb_o,
    output logic [NUM_LANES*32-1:0]           fp32_out_o
);

    // -------------------------------------------------------------------------
    // Helper Functions: E2M1 -> INT5 (2x) Decode & Multiplierless Shift-Add
    // -------------------------------------------------------------------------
    function automatic logic [3:0] decode_e2m1_mag2x(input logic [2:0] mag_code);
        begin
            unique case (mag_code)
                3'b000: decode_e2m1_mag2x = 4'd0;   // 2 * 0.0 = 0
                3'b001: decode_e2m1_mag2x = 4'd1;   // 2 * 0.5 = 1
                3'b010: decode_e2m1_mag2x = 4'd2;   // 2 * 1.0 = 2
                3'b011: decode_e2m1_mag2x = 4'd3;   // 2 * 1.5 = 3
                3'b100: decode_e2m1_mag2x = 4'd4;   // 2 * 2.0 = 4
                3'b101: decode_e2m1_mag2x = 4'd6;   // 2 * 3.0 = 6
                3'b110: decode_e2m1_mag2x = 4'd8;   // 2 * 4.0 = 8
                3'b111: decode_e2m1_mag2x = 4'd12;  // 2 * 6.0 = 12
                default: decode_e2m1_mag2x = 4'd0;
            endcase
        end
    endfunction

    function automatic logic signed [4:0] decode_e2m1_signed2x(input logic [3:0] code_4b);
        logic [3:0]        mag2x;
        logic signed [4:0] pos_val;
        begin
            mag2x   = decode_e2m1_mag2x(code_4b[2:0]);
            pos_val = $signed({1'b0, mag2x});
            decode_e2m1_signed2x = code_4b[3] ? (-pos_val) : pos_val;
        end
    endfunction

    function automatic logic signed [8:0] mxfp4_shift_add_prod(
        input logic [3:0] w_code,
        input logic [3:0] x_code
    );
        logic [3:0]        x_mag;
        logic [7:0]        x_ext;
        logic [7:0]        prod_mag;
        logic              prod_sign;
        logic signed [8:0] prod_pos;
        begin
            x_mag = decode_e2m1_mag2x(x_code[2:0]);
            // Operand isolation when weight magnitude is zero
            x_ext = (w_code[2:0] == 3'b000) ? 8'd0 : {4'd0, x_mag};

            // Multiplierless 2-term shift-add for w_mag in {0, 1, 2, 3, 4, 6, 8, 12}
            unique case (w_code[2:0])
                3'b000: prod_mag = 8'd0;                         //  0 * x
                3'b001: prod_mag = x_ext;                        //  1 * x
                3'b010: prod_mag = (x_ext << 1);                 //  2 * x
                3'b011: prod_mag = (x_ext << 1) + x_ext;         //  3 * x
                3'b100: prod_mag = (x_ext << 2);                 //  4 * x
                3'b101: prod_mag = (x_ext << 2) + (x_ext << 1);  //  6 * x
                3'b110: prod_mag = (x_ext << 3);                 //  8 * x
                3'b111: prod_mag = (x_ext << 3) + (x_ext << 2);  // 12 * x
                default: prod_mag = 8'd0;
            endcase

            prod_sign = w_code[3] ^ x_code[3];
            prod_pos  = $signed({1'b0, prod_mag});
            if (prod_mag == 8'd0) begin
                mxfp4_shift_add_prod = 9'sd0;
            end else begin
                mxfp4_shift_add_prod = prod_sign ? (-prod_pos) : prod_pos;
            end
        end
    endfunction

    // -------------------------------------------------------------------------
    // Exact Integer + Block Exponent -> IEEE-754 FP32 Normalizer
    // -------------------------------------------------------------------------
    function automatic logic [31:0] normalize_int16_exp_to_fp32(
        input logic signed [15:0] s_int,
        input logic signed [9:0]  e_comb
    );
        logic              fp_sign;
        logic [15:0]       abs_val;
        logic [3:0]        msb_pos;
        logic [4:0]        lshift;
        logic [23:0]       norm_sig;
        logic signed [11:0] biased_exp;
        begin
            if (s_int == 16'sd0) begin
                normalize_int16_exp_to_fp32 = 32'h0000_0000;
            end else begin
                fp_sign = s_int[15];
                abs_val = fp_sign ? 16'(-s_int) : 16'(s_int);
                msb_pos = 4'd0;
                for (int b = 0; b < 15; b++) begin
                    if (abs_val[b]) begin
                        msb_pos = 4'(b);
                    end
                end
                lshift     = 5'd23 - {1'b0, msb_pos};
                norm_sig   = 24'(abs_val) << lshift;
                biased_exp = 12'(e_comb) + 12'($signed({1'b0, msb_pos})) + 12'sd127;

                if (biased_exp >= 12'sd255) begin
                    normalize_int16_exp_to_fp32 = {fp_sign, 8'hFF, 23'd0};
                end else if (biased_exp <= 12'sd0) begin
                    logic signed [11:0] rshift_full;
                    rshift_full = 12'sd1 - biased_exp;
                    if (rshift_full < 12'sd24) begin
                        logic [4:0]  rshift_5b;
                        logic [23:0] sub_sig;
                        rshift_5b = rshift_full[4:0];
                        sub_sig   = norm_sig >> rshift_5b;
                        normalize_int16_exp_to_fp32 = {fp_sign, 7'h00, sub_sig[23:0]};
                    end else begin
                        normalize_int16_exp_to_fp32 = {fp_sign, 31'd0};
                    end
                end else begin
                    normalize_int16_exp_to_fp32 = {fp_sign, biased_exp[7:0], (norm_sig[23] ? norm_sig[22:0] : 23'd0)};
                end
            end
        end
    endfunction

    // -------------------------------------------------------------------------
    // Stage 1: E2M1 Unpack, Shift-Add Pairwise Products & Exponent Combine
    // -------------------------------------------------------------------------
    logic [3:0]        act_code_comb  [0:BLOCK_SIZE-1];
    logic [3:0]        w_code_comb    [0:NUM_LANES-1][0:BLOCK_SIZE-1];
    logic signed [8:0] prod_comb      [0:NUM_LANES-1][0:BLOCK_SIZE-1];
    logic signed [9:0] exp_comb_s1_d  [0:NUM_LANES-1];
    logic              nan_scale_s1_d [0:NUM_LANES-1];

    always_comb begin
        for (int i = 0; i < BLOCK_SIZE; i++) begin
            act_code_comb[i] = act_mxfp4_i[i*4 +: 4];
        end
        for (int l = 0; l < NUM_LANES; l++) begin
            logic [7:0] w_e8;
            w_e8 = w_e8m0_i[l*8 +: 8];
            // [STAGE-10 FIX BUG-HC1-005]: OCP MXFP4 E8M0 == 8'hFF is reserved for NaN scale
            nan_scale_s1_d[l] = (w_e8 == 8'hFF) || (act_e8m0_i == 8'hFF);
            // Combined unbiased exponent: (Ew - 127) + (Ex - 127) - 2 = Ew + Ex - 256
            exp_comb_s1_d[l] = $signed({2'b00, w_e8}) + $signed({2'b00, act_e8m0_i}) - 10'sd256;
            for (int i = 0; i < BLOCK_SIZE; i++) begin
                w_code_comb[l][i] = w_mxfp4_i[(l*BLOCK_SIZE + i)*4 +: 4];
                prod_comb[l][i]   = mxfp4_shift_add_prod(w_code_comb[l][i], act_code_comb[i]);
            end
        end
    end

    logic              valid_s1_q;
    logic signed [8:0] prod_s1_q      [0:NUM_LANES-1][0:BLOCK_SIZE-1];
    logic signed [9:0] exp_comb_s1_q  [0:NUM_LANES-1];
    logic              nan_scale_s1_q [0:NUM_LANES-1];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_s1_q <= 1'b0;
            for (int l = 0; l < NUM_LANES; l++) begin
                exp_comb_s1_q[l]  <= 10'sd0;
                nan_scale_s1_q[l] <= 1'b0;
                for (int i = 0; i < BLOCK_SIZE; i++) begin
                    prod_s1_q[l][i] <= 9'sd0;
                end
            end
        end else begin
            valid_s1_q <= valid_i;
            if (valid_i) begin
                for (int l = 0; l < NUM_LANES; l++) begin
                    exp_comb_s1_q[l]  <= exp_comb_s1_d[l];
                    nan_scale_s1_q[l] <= nan_scale_s1_d[l];
                    for (int i = 0; i < BLOCK_SIZE; i++) begin
                        prod_s1_q[l][i] <= prod_comb[l][i];
                    end
                end
            end
        end
    end

    // -------------------------------------------------------------------------
    // Stage 2: 32-Element Binary Adder Tree Reduction (Zero Rounding Loss)
    // -------------------------------------------------------------------------
    logic signed [15:0] dot_tree_comb [0:NUM_LANES-1];

    always_comb begin
        for (int l = 0; l < NUM_LANES; l++) begin
            dot_tree_comb[l] = 16'sd0;
            for (int i = 0; i < BLOCK_SIZE; i++) begin
                dot_tree_comb[l] = dot_tree_comb[l] + {{7{prod_s1_q[l][i][8]}}, prod_s1_q[l][i]};
            end
        end
    end

    logic               valid_s2_q;
    logic signed [15:0] dot_int16_s2_q [0:NUM_LANES-1];
    logic signed [9:0]  exp_comb_s2_q  [0:NUM_LANES-1];
    logic               nan_scale_s2_q [0:NUM_LANES-1];
    logic [NUM_LANES-1:0] nan_flag_q;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_s2_q <= 1'b0;
            for (int l = 0; l < NUM_LANES; l++) begin
                dot_int16_s2_q[l] <= 16'sd0;
                exp_comb_s2_q[l]  <= 10'sd0;
                nan_scale_s2_q[l] <= 1'b0;
            end
        end else begin
            valid_s2_q <= valid_s1_q;
            if (valid_s1_q) begin
                for (int l = 0; l < NUM_LANES; l++) begin
                    dot_int16_s2_q[l] <= dot_tree_comb[l];
                    exp_comb_s2_q[l]  <= exp_comb_s1_q[l];
                    nan_scale_s2_q[l] <= nan_scale_s1_q[l];
                end
            end
        end
    end

    // -------------------------------------------------------------------------
    // Stage 3: IEEE-754 FP32 Block Scale Normalization & Output Latch
    // -------------------------------------------------------------------------
    logic [31:0] fp32_norm_comb [0:NUM_LANES-1];

    always_comb begin
        for (int l = 0; l < NUM_LANES; l++) begin
            if (nan_scale_s2_q[l]) begin
                fp32_norm_comb[l] = 32'h7FC0_0000;
            end else begin
                fp32_norm_comb[l] = normalize_int16_exp_to_fp32(dot_int16_s2_q[l], exp_comb_s2_q[l]);
            end
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_o     <= 1'b0;
            dot_int16_o <= '0;
            exp_comb_o  <= '0;
            fp32_out_o  <= '0;
            nan_flag_q  <= '0;
        end else begin
            valid_o <= valid_s2_q;
            if (valid_s2_q) begin
                for (int l = 0; l < NUM_LANES; l++) begin
                    dot_int16_o[l*16 +: 16] <= dot_int16_s2_q[l];
                    exp_comb_o[l*10 +: 10]  <= exp_comb_s2_q[l];
                    fp32_out_o[l*32 +: 32]  <= fp32_norm_comb[l];
                    nan_flag_q[l]           <= nan_scale_s2_q[l];
                end
            end
        end
    end

    // -------------------------------------------------------------------------
    // Inline SVA & Yosys Formal Equivalence Verification (PROP_M3_MXFP4_INT_EXACT)
    // Proves:
    //   1. Every E2M1 x E2M1 multiplierless shift-add product matches exact
    //      integer multiplication (2*w) * (2*x) with 0 ULP error.
    //   2. Zero weight or zero activation magnitude yields exact zero product.
    //   3. The 32-element pipelined tree sum matches the exact mathematical
    //      inner product bounded within [-4608, +4608].
    //   4. When the integer dot product is 0, the IEEE-754 FP32 output is +0.0f.
    // -------------------------------------------------------------------------
    logic signed [8:0]  ref_e2m1_mul_l0_i0;
    logic signed [8:0]  ref_e2m1_mul_l0_i1;
    logic signed [15:0] ref_dot_l0_comb;
    logic signed [9:0]  ref_exp_l0_comb;
    logic signed [15:0] ref_dot_l0_s1_q, ref_dot_l0_s2_q, ref_dot_l0_s3_q;
    logic signed [9:0]  ref_exp_l0_s1_q, ref_exp_l0_s2_q, ref_exp_l0_s3_q;

    always_comb begin
        ref_e2m1_mul_l0_i0 = 9'(decode_e2m1_signed2x(w_code_comb[0][0])) *
                             9'(decode_e2m1_signed2x(act_code_comb[0]));
        ref_e2m1_mul_l0_i1 = 9'(decode_e2m1_signed2x(w_code_comb[0][1])) *
                             9'(decode_e2m1_signed2x(act_code_comb[1]));
        ref_exp_l0_comb    = $signed({2'b00, w_e8m0_i[7:0]}) +
                             $signed({2'b00, act_e8m0_i}) - 10'sd256;
        ref_dot_l0_comb    = 16'sd0;
        for (int i = 0; i < BLOCK_SIZE; i++) begin
            logic signed [8:0] p_mxfp4;
            p_mxfp4 = 9'(decode_e2m1_signed2x(w_code_comb[0][i])) *
                      9'(decode_e2m1_signed2x(act_code_comb[i]));
            ref_dot_l0_comb = ref_dot_l0_comb + 16'(p_mxfp4);
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ref_dot_l0_s1_q <= 16'sd0;
            ref_dot_l0_s2_q <= 16'sd0;
            ref_dot_l0_s3_q <= 16'sd0;
            ref_exp_l0_s1_q <= 10'sd0;
            ref_exp_l0_s2_q <= 10'sd0;
            ref_exp_l0_s3_q <= 10'sd0;
        end else begin
            if (valid_i) begin
                ref_dot_l0_s1_q <= ref_dot_l0_comb;
                ref_exp_l0_s1_q <= ref_exp_l0_comb;
            end
            if (valid_s1_q) begin
                ref_dot_l0_s2_q <= ref_dot_l0_s1_q;
                ref_exp_l0_s2_q <= ref_exp_l0_s1_q;
            end
            if (valid_s2_q) begin
                ref_dot_l0_s3_q <= ref_dot_l0_s2_q;
                ref_exp_l0_s3_q <= ref_exp_l0_s2_q;
            end
        end
    end

    always_ff @(posedge clk) begin
        if (rst_n) begin
            PROP_M3_MXFP4_SHIFT_ADD_EQUIV_0: assert (prod_comb[0][0] == ref_e2m1_mul_l0_i0);
            PROP_M3_MXFP4_SHIFT_ADD_EQUIV_1: assert (prod_comb[0][1] == ref_e2m1_mul_l0_i1);

            if ((w_code_comb[0][0][2:0] == 3'b000) || (act_code_comb[0][2:0] == 3'b000)) begin
                PROP_M3_MXFP4_ZERO_ISOLATION: assert (prod_comb[0][0] == 9'sd0);
            end

            if (valid_o) begin
                PROP_M3_MXFP4_INT_EXACT: assert ($signed(dot_int16_o[15:0]) == ref_dot_l0_s3_q);
                PROP_M3_MXFP4_EXP_EXACT: assert ($signed(exp_comb_o[9:0])   == ref_exp_l0_s3_q);
                PROP_M3_MXFP4_BOUND_CHECK: assert (
                    $signed(dot_int16_o[15:0]) >= -$signed(16'(144 * BLOCK_SIZE)) &&
                    $signed(dot_int16_o[15:0]) <=  $signed(16'(144 * BLOCK_SIZE))
                );
                if ($signed(dot_int16_o[15:0]) == 16'sd0 && !nan_flag_q[0]) begin
                    PROP_M3_MXFP4_FP32_ZERO_EXACT: assert (fp32_out_o[31:0] == 32'h0000_0000);
                end
                for (int l = 0; l < NUM_LANES; l++) begin
                    if (nan_flag_q[l]) begin
                        assert (fp32_out_o[l*32 +: 32] == 32'h7FC0_0000);
                    end
                end
            end
        end
    end

endmodule
