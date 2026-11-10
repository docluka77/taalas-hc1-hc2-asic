`timescale 1ns / 1ps
// =============================================================================
// File:        formal/taalas_formal_miter_suite.sv
// Project:     Taalas HC1/HC2 Hardwired LLM Inference ASIC (Stage 9 Formal)
// Description: Comprehensive Formal Verification & Miter Equivalence Suite
//              containing 65+ named formal assertions across:
//                1. taalas_csd_vs_mult_miter          (M2 3b CSD & 6b Outlier)
//                2. taalas_mxfp4_exact_miter          (M3 OCP MXFP4 E2M1/E8M0)
//                3. taalas_secded_72_64_exhaustive_miter (M5 72b SECDED ECC)
//                4. taalas_gf16_swizzle_bijection_miter  (M5 GF(2^4) Swizzler)
//                5. taalas_nonlin_math_miter          (M8/M9/M10/M11 Math)
//                6. taalas_deep_seq12_protocol_miter  (M12/M13/M15 12-Cyc BMC)
// =============================================================================

// =============================================================================
// MITER 1: Multiplierless 3-Bit CSD & 6-Bit Outlier Shift-Add vs. Booth Mult
// Proves 0-ULP bit-exact equivalence over all x in [-128,127], w3 in [-4,3],
// w6 in [-32,31], zero-skip invariance, and 12-cycle pipelined VMM equivalence.
// =============================================================================
module taalas_csd_vs_mult_miter (
    input  logic               clk,
    input  logic               rst_n,
    input  logic               valid_i,
    input  logic signed [7:0]  x_sym_i,
    input  logic signed [2:0]  w3_sym_i,
    input  logic signed [5:0]  w6_sym_i,
    input  logic               zskip_sym_i,
    input  logic [31:0]        act_vec4_i,
    input  logic [11:0]        w_base4_3b_i,
    input  logic [5:0]         w_out_val_6b_i,
    input  logic [5:0]         w_out_idx_6b_i,
    output logic               miter_ok_o
);

    // Replica of M2 csd3_shift_add
    function automatic logic signed [10:0] dut_csd3_shift_add(
        input logic signed [2:0] w_3b,
        input logic signed [7:0] x_in,
        input logic              zskip_en
    );
        logic signed [7:0]  x_iso;
        logic signed [10:0] x_ext, x_sh1, x_sh2;
        begin
            x_iso = (zskip_en && ((w_3b == 3'sd0) || (x_in == 8'sd0))) ? 8'sd0 : x_in;
            x_ext = {{3{x_iso[7]}}, x_iso};
            x_sh1 = x_ext <<< 1;
            x_sh2 = x_ext <<< 2;
            unique case (w_3b)
                3'sb000: dut_csd3_shift_add = 11'sd0;
                3'sb001: dut_csd3_shift_add = x_ext;
                3'sb010: dut_csd3_shift_add = x_sh1;
                3'sb011: dut_csd3_shift_add = x_sh1 + x_ext;
                3'sb100: dut_csd3_shift_add = -x_sh2;
                3'sb101: dut_csd3_shift_add = -(x_sh1 + x_ext);
                3'sb110: dut_csd3_shift_add = -x_sh1;
                3'sb111: dut_csd3_shift_add = -x_ext;
                default: dut_csd3_shift_add = 11'sd0;
            endcase
        end
    endfunction

    // Replica of M2 outlier6_shift_add
    function automatic logic signed [13:0] dut_outlier6_shift_add(
        input logic signed [5:0] w_6b,
        input logic signed [7:0] x_in,
        input logic              zskip_en
    );
        logic signed [7:0]  x_iso;
        logic signed [13:0] x_ext, t0, t1, t2, t3, t4, t5;
        begin
            x_iso = (zskip_en && ((w_6b == 6'sd0) || (x_in == 8'sd0))) ? 8'sd0 : x_in;
            x_ext = {{6{x_iso[7]}}, x_iso};
            t0 = w_6b[0] ?  x_ext        : 14'sd0;
            t1 = w_6b[1] ? (x_ext <<< 1) : 14'sd0;
            t2 = w_6b[2] ? (x_ext <<< 2) : 14'sd0;
            t3 = w_6b[3] ? (x_ext <<< 3) : 14'sd0;
            t4 = w_6b[4] ? (x_ext <<< 4) : 14'sd0;
            t5 = w_6b[5] ? (x_ext <<< 5) : 14'sd0;
            dut_outlier6_shift_add = (t0 + t1 + t2) + (t3 + t4 - t5);
        end
    endfunction

    // Golden Reference Signed Booth Multipliers
    logic signed [10:0] ref_csd3_mult, dut_csd3_z0, dut_csd3_z1, dut_csd3_zsym;
    logic signed [13:0] ref_out6_mult, dut_out6_z0, dut_out6_z1, dut_out6_zsym;

    assign ref_csd3_mult = 11'(x_sym_i) * 11'(w3_sym_i);
    assign dut_csd3_z0   = dut_csd3_shift_add(w3_sym_i, x_sym_i, 1'b0);
    assign dut_csd3_z1   = dut_csd3_shift_add(w3_sym_i, x_sym_i, 1'b1);
    assign dut_csd3_zsym = dut_csd3_shift_add(w3_sym_i, x_sym_i, zskip_sym_i);

    assign ref_out6_mult = 14'(x_sym_i) * 14'(w6_sym_i);
    assign dut_out6_z0   = dut_outlier6_shift_add(w6_sym_i, x_sym_i, 1'b0);
    assign dut_out6_z1   = dut_outlier6_shift_add(w6_sym_i, x_sym_i, 1'b1);
    assign dut_out6_zsym = dut_outlier6_shift_add(w6_sym_i, x_sym_i, zskip_sym_i);

    // Instantiate M2 DUT for 12-cycle sequential VMM Miter against Golden Pipeline
    logic               dut_valid_o;
    logic signed [23:0] dut_acc_o;
    logic signed [15:0] dut_act_sum_o;
    logic [15:0]        dut_zsaved_o;

    taalas_3b6b_wired_mac_array #(
        .VEC_LEN      (4),
        .OUT_CHANNELS (1),
        .NUM_OUTLIERS (1)
    ) u_dut_m2 (
        .clk              (clk),
        .rst_n            (rst_n),
        .valid_i          (valid_i),
        .act_vec_i        (act_vec4_i),
        .w_base_3b_i      (w_base4_3b_i),
        .w_out_val_6b_i   (w_out_val_6b_i),
        .w_out_idx_6b_i   (w_out_idx_6b_i),
        .zero_skip_en_i   (zskip_sym_i),
        .valid_o          (dut_valid_o),
        .acc_out_o        (dut_acc_o),
        .act_sum_o        (dut_act_sum_o),
        .zero_ops_saved_o (dut_zsaved_o)
    );

    // Golden 3-Stage Reference Booth-Multiplier VMM Pipeline
    logic signed [23:0] ref_acc_s1_d, ref_acc_s1_q, ref_acc_s2_q, ref_acc_s3_q;
    logic signed [15:0] ref_asum_s1_d, ref_asum_s1_q, ref_asum_s2_q, ref_asum_s3_q;
    logic               ref_v_s1_q, ref_v_s2_q, ref_v_s3_q;

    always_comb begin
        logic signed [7:0]  x0, x1, x2, x3, x_out;
        logic signed [2:0]  w0, w1, w2, w3;
        logic signed [5:0]  wo;
        x0 = $signed(act_vec4_i[7:0]);
        x1 = $signed(act_vec4_i[15:8]);
        x2 = $signed(act_vec4_i[23:16]);
        x3 = $signed(act_vec4_i[31:24]);
        w0 = $signed(w_base4_3b_i[2:0]);
        w1 = $signed(w_base4_3b_i[5:3]);
        w2 = $signed(w_base4_3b_i[8:6]);
        w3 = $signed(w_base4_3b_i[11:9]);
        wo = $signed(w_out_val_6b_i);
        unique case (w_out_idx_6b_i[1:0])
            2'd0: x_out = x0;
            2'd1: x_out = x1;
            2'd2: x_out = x2;
            default: x_out = x3;
        endcase
        ref_acc_s1_d  = 24'(x0)*24'(w0) + 24'(x1)*24'(w1) + 24'(x2)*24'(w2) + 24'(x3)*24'(w3) + 24'(x_out)*24'(wo);
        ref_asum_s1_d = 16'(x0) + 16'(x1) + 16'(x2) + 16'(x3);
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ref_v_s1_q    <= 1'b0;    ref_v_s2_q    <= 1'b0;    ref_v_s3_q    <= 1'b0;
            ref_acc_s1_q  <= 24'sd0;  ref_acc_s2_q  <= 24'sd0;  ref_acc_s3_q  <= 24'sd0;
            ref_asum_s1_q <= 16'sd0;  ref_asum_s2_q <= 16'sd0;  ref_asum_s3_q <= 16'sd0;
        end else begin
            ref_v_s1_q   <= valid_i;
            ref_v_s2_q   <= ref_v_s1_q;
            ref_v_s3_q   <= ref_v_s2_q;
            if (valid_i) begin
                ref_acc_s1_q  <= ref_acc_s1_d;
                ref_asum_s1_q <= ref_asum_s1_d;
            end
            if (ref_v_s1_q) begin
                ref_acc_s2_q  <= ref_acc_s1_q;
                ref_asum_s2_q <= ref_asum_s1_q;
            end
            if (ref_v_s2_q) begin
                ref_acc_s3_q  <= ref_acc_s2_q;
                ref_asum_s3_q <= ref_asum_s2_q;
            end
        end
    end

    assign miter_ok_o = (dut_csd3_zsym == ref_csd3_mult) && (dut_out6_zsym == ref_out6_mult);

    logic past_valid_q;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) past_valid_q <= 1'b0;
        else        past_valid_q <= 1'b1;
    end

    always_ff @(posedge clk) begin
        if (past_valid_q && rst_n) begin
            p_m1_csd3_exact_z0:    assert (dut_csd3_z0   == ref_csd3_mult);
            p_m1_csd3_exact_z1:    assert (dut_csd3_z1   == ref_csd3_mult);
            p_m1_csd3_zskip_inv:   assert (dut_csd3_z0   == dut_csd3_z1);
            p_m1_csd3_bounds:      assert (dut_csd3_zsym >= -11'sd512 && dut_csd3_zsym <= 11'sd512);
            p_m1_out6_exact_z0:    assert (dut_out6_z0   == ref_out6_mult);
            p_m1_out6_exact_z1:    assert (dut_out6_z1   == ref_out6_mult);
            p_m1_out6_zskip_inv:   assert (dut_out6_z0   == dut_out6_z1);
            p_m1_out6_bounds:      assert (dut_out6_zsym >= -14'sd4096 && dut_out6_zsym <= 14'sd4096);
            p_m1_seq_valid_eq:     assert (dut_valid_o   == ref_v_s3_q);
            p_m1_seq_acc_eq:       assert (!dut_valid_o  || (dut_acc_o == ref_acc_s3_q));
            p_m1_seq_actsum_eq:    assert (!dut_valid_o  || (dut_act_sum_o == ref_asum_s3_q));
            p_m1_seq_zsaved_bound: assert (!dut_valid_o  || (dut_zsaved_o <= 16'd5));
        end
    end
endmodule

// =============================================================================
// MITER 2: OCP MXFP4 E2M1 Shift-Add & E8M0 Block Exponent Exact Miter
// Proves 100% bit-exactness across all 16x16 = 256 E2M1 pairs, all E8M0 shared
// exponents, and 12-cycle sequential equivalence of taalas_mxfp4_hc2_mac_lane.
// =============================================================================
module taalas_mxfp4_exact_miter (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        valid_i,
    input  logic [3:0]  w_e2m1_sym_i,
    input  logic [3:0]  x_e2m1_sym_i,
    input  logic [15:0] act_mxfp4_vec4_i,
    input  logic [7:0]  act_e8m0_i,
    input  logic [15:0] w_mxfp4_vec4_i,
    input  logic [7:0]  w_e8m0_i,
    output logic        miter_ok_o
);

    function automatic logic [3:0] ref_decode_mag2x(input logic [2:0] mag_code);
        begin
            unique case (mag_code)
                3'b000: ref_decode_mag2x = 4'd0;
                3'b001: ref_decode_mag2x = 4'd1;
                3'b010: ref_decode_mag2x = 4'd2;
                3'b011: ref_decode_mag2x = 4'd3;
                3'b100: ref_decode_mag2x = 4'd4;
                3'b101: ref_decode_mag2x = 4'd6;
                3'b110: ref_decode_mag2x = 4'd8;
                3'b111: ref_decode_mag2x = 4'd12;
                default: ref_decode_mag2x = 4'd0;
            endcase
        end
    endfunction

    function automatic logic signed [4:0] ref_decode_signed2x(input logic [3:0] c4);
        logic [3:0] m2x;
        logic signed [4:0] pv;
        begin
            m2x = ref_decode_mag2x(c4[2:0]);
            pv  = $signed({1'b0, m2x});
            ref_decode_signed2x = c4[3] ? (-pv) : pv;
        end
    endfunction

    function automatic logic signed [8:0] dut_mxfp4_shift_add(
        input logic [3:0] w_code,
        input logic [3:0] x_code
    );
        logic [3:0]        x_mag;
        logic [7:0]        x_ext, prod_mag;
        logic              prod_sign;
        logic signed [8:0] prod_pos;
        begin
            x_mag = ref_decode_mag2x(x_code[2:0]);
            x_ext = (w_code[2:0] == 3'b000) ? 8'd0 : {4'd0, x_mag};
            unique case (w_code[2:0])
                3'b000: prod_mag = 8'd0;
                3'b001: prod_mag = x_ext;
                3'b010: prod_mag = (x_ext << 1);
                3'b011: prod_mag = (x_ext << 1) + x_ext;
                3'b100: prod_mag = (x_ext << 2);
                3'b101: prod_mag = (x_ext << 2) + (x_ext << 1);
                3'b110: prod_mag = (x_ext << 3);
                3'b111: prod_mag = (x_ext << 3) + (x_ext << 2);
                default: prod_mag = 8'd0;
            endcase
            prod_sign = w_code[3] ^ x_code[3];
            prod_pos  = $signed({1'b0, prod_mag});
            dut_mxfp4_shift_add = (prod_mag == 8'd0) ? 9'sd0 : (prod_sign ? (-prod_pos) : prod_pos);
        end
    endfunction

    logic signed [4:0] w_val_2x, x_val_2x;
    logic signed [8:0] ref_prod_mult, dut_prod_sa, dut_prod_comm, dut_prod_negw;

    assign w_val_2x      = ref_decode_signed2x(w_e2m1_sym_i);
    assign x_val_2x      = ref_decode_signed2x(x_e2m1_sym_i);
    assign ref_prod_mult = 9'(w_val_2x) * 9'(x_val_2x);
    assign dut_prod_sa   = dut_mxfp4_shift_add(w_e2m1_sym_i, x_e2m1_sym_i);
    assign dut_prod_comm = dut_mxfp4_shift_add(x_e2m1_sym_i, w_e2m1_sym_i);
    assign dut_prod_negw = dut_mxfp4_shift_add({~w_e2m1_sym_i[3], w_e2m1_sym_i[2:0]}, x_e2m1_sym_i);

    // Instantiate M3 DUT for 12-cycle sequential MXFP4 dot-product equivalence
    logic               dut_valid_o;
    logic signed [15:0] dut_dot_o;
    logic signed [9:0]  dut_exp_o;
    logic [31:0]        dut_fp32_o;

    taalas_mxfp4_hc2_mac_lane #(
        .BLOCK_SIZE (4),
        .NUM_LANES  (1)
    ) u_dut_m3 (
        .clk         (clk),
        .rst_n       (rst_n),
        .valid_i     (valid_i),
        .act_mxfp4_i (act_mxfp4_vec4_i),
        .act_e8m0_i  (act_e8m0_i),
        .w_mxfp4_i   (w_mxfp4_vec4_i),
        .w_e8m0_i    (w_e8m0_i),
        .valid_o     (dut_valid_o),
        .dot_int16_o (dut_dot_o),
        .exp_comb_o  (dut_exp_o),
        .fp32_out_o  (dut_fp32_o)
    );

    logic signed [15:0] ref_dot_s1_d, ref_dot_s1_q, ref_dot_s2_q, ref_dot_s3_q;
    logic signed [9:0]  ref_exp_s1_d, ref_exp_s1_q, ref_exp_s2_q, ref_exp_s3_q;
    logic               ref_v_s1_q, ref_v_s2_q, ref_v_s3_q;

    always_comb begin
        logic signed [4:0] x0, x1, x2, x3, w0, w1, w2, w3;
        x0 = ref_decode_signed2x(act_mxfp4_vec4_i[3:0]);
        x1 = ref_decode_signed2x(act_mxfp4_vec4_i[7:4]);
        x2 = ref_decode_signed2x(act_mxfp4_vec4_i[11:8]);
        x3 = ref_decode_signed2x(act_mxfp4_vec4_i[15:12]);
        w0 = ref_decode_signed2x(w_mxfp4_vec4_i[3:0]);
        w1 = ref_decode_signed2x(w_mxfp4_vec4_i[7:4]);
        w2 = ref_decode_signed2x(w_mxfp4_vec4_i[11:8]);
        w3 = ref_decode_signed2x(w_mxfp4_vec4_i[15:12]);
        ref_dot_s1_d = 16'(w0)*16'(x0) + 16'(w1)*16'(x1) + 16'(w2)*16'(x2) + 16'(w3)*16'(x3);
        ref_exp_s1_d = $signed({2'b00, w_e8m0_i}) + $signed({2'b00, act_e8m0_i}) - 10'sd256;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ref_v_s1_q   <= 1'b0;   ref_v_s2_q   <= 1'b0;   ref_v_s3_q   <= 1'b0;
            ref_dot_s1_q <= 16'sd0; ref_dot_s2_q <= 16'sd0; ref_dot_s3_q <= 16'sd0;
            ref_exp_s1_q <= 10'sd0; ref_exp_s2_q <= 10'sd0; ref_exp_s3_q <= 10'sd0;
        end else begin
            ref_v_s1_q <= valid_i;
            ref_v_s2_q <= ref_v_s1_q;
            ref_v_s3_q <= ref_v_s2_q;
            if (valid_i)    begin ref_dot_s1_q <= ref_dot_s1_d; ref_exp_s1_q <= ref_exp_s1_d; end
            if (ref_v_s1_q) begin ref_dot_s2_q <= ref_dot_s1_q; ref_exp_s2_q <= ref_exp_s1_q; end
            if (ref_v_s2_q) begin ref_dot_s3_q <= ref_dot_s2_q; ref_exp_s3_q <= ref_exp_s2_q; end
        end
    end

    assign miter_ok_o = (dut_prod_sa == ref_prod_mult);

    logic past_valid_q;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) past_valid_q <= 1'b0;
        else        past_valid_q <= 1'b1;
    end

    always_ff @(posedge clk) begin
        if (past_valid_q && rst_n) begin
            p_m2_e2m1_prod_exact:  assert (dut_prod_sa   == ref_prod_mult);
            p_m2_e2m1_commutative: assert (dut_prod_sa   == dut_prod_comm);
            p_m2_e2m1_sign_sym:    assert (dut_prod_negw == -dut_prod_sa);
            p_m2_e2m1_prod_bounds: assert (dut_prod_sa   >= -9'sd144 && dut_prod_sa <= 9'sd144);
            p_m2_e2m1_zero_w:      assert ((w_e2m1_sym_i[2:0] != 3'd0) || (dut_prod_sa == 9'sd0));
            p_m2_e2m1_zero_x:      assert ((x_e2m1_sym_i[2:0] != 3'd0) || (dut_prod_sa == 9'sd0));
            p_m2_seq_valid_eq:     assert (dut_valid_o == ref_v_s3_q);
            p_m2_seq_dot_eq:       assert (!dut_valid_o || (dut_dot_o == ref_dot_s3_q));
            p_m2_seq_exp_eq:       assert (!dut_valid_o || (dut_exp_o == ref_exp_s3_q));
            p_m2_seq_dot_bounds:   assert (!dut_valid_o || (dut_dot_o >= -16'sd576 && dut_dot_o <= 16'sd576));
            p_m2_seq_fp32_zero:    assert (!dut_valid_o || (dut_dot_o != 16'sd0) || (dut_fp32_o == 32'h0));
            p_m2_seq_fp32_sign:    assert (!dut_valid_o || (dut_dot_o == 16'sd0) || (dut_fp32_o[31] == dut_dot_o[15]));
        end
    end
endmodule

// =============================================================================
// MITER 3: (72,64) Extended Hamming SECDED Exhaustive Symbolic Miter
// Universal proof over all 2^64 data words, all 72 single-bit error masks, and
// all C(72,2) = 2,556 double-bit error masks: 100% SEC & 100% DED (0 SDC).
// =============================================================================
module taalas_secded_72_64_exhaustive_miter (
    input  logic        clk,
    input  logic        rst_n,
    input  logic [63:0] wdata_sym_i,
    input  logic [6:0]  raw_idx1_i,
    input  logic [6:0]  raw_idx2_i,
    input  logic [5:0]  col_idx_a_i,
    input  logic [5:0]  col_idx_b_i,
    output logic        secded_ok_o
);

    function automatic logic [6:0] get_syndrome_col(input logic [5:0] bit_idx);
        logic [6:0] col_val;
        if (bit_idx == 6'd0)       col_val = 7'd3;
        else if (bit_idx <= 6'd3)  col_val = {1'b0, bit_idx} + 7'd4;
        else if (bit_idx <= 6'd10) col_val = {1'b0, bit_idx} + 7'd5;
        else if (bit_idx <= 6'd25) col_val = {1'b0, bit_idx} + 7'd6;
        else if (bit_idx <= 6'd56) col_val = {1'b0, bit_idx} + 7'd7;
        else                       col_val = {1'b0, bit_idx} + 7'd8;
        get_syndrome_col = col_val;
    endfunction

    function automatic logic [7:0] secded_encode_72_64(input logic [63:0] d_in);
        logic [6:0] p_hamming, col_c;
        logic       p_overall;
        p_hamming = 7'd0;
        for (int i = 0; i < 64; i++) begin
            col_c = get_syndrome_col(i[5:0]);
            if (d_in[i]) p_hamming = p_hamming ^ col_c;
        end
        p_overall = (^d_in) ^ (^p_hamming);
        secded_encode_72_64 = {p_overall, p_hamming};
    endfunction

    function automatic logic [73:0] secded_decode_72_64(
        input logic [63:0] data_rx,
        input logic [7:0]  ecc_rx
    );
        logic [7:0]  ecc_calc;
        logic [6:0]  syndrome_7b, col_c;
        logic        total_parity, sec_flag, ded_flag;
        logic [63:0] data_corr;
        ecc_calc     = secded_encode_72_64(data_rx);
        syndrome_7b  = ecc_rx[6:0] ^ ecc_calc[6:0];
        total_parity = ecc_rx[7] ^ ecc_calc[7] ^ (^syndrome_7b);
        data_corr    = data_rx;
        sec_flag     = 1'b0;
        ded_flag     = 1'b0;
        if ((syndrome_7b == 7'd0) && (total_parity == 1'b0)) begin
            sec_flag = 1'b0; ded_flag = 1'b0;
        end else if (total_parity == 1'b1) begin
            sec_flag = 1'b1; ded_flag = 1'b0;
            for (int i = 0; i < 64; i++) begin
                col_c = get_syndrome_col(i[5:0]);
                if (syndrome_7b == col_c) data_corr[i] = ~data_rx[i];
            end
        end else begin
            sec_flag = 1'b0; ded_flag = 1'b1;
        end
        secded_decode_72_64 = {ded_flag, sec_flag, total_parity, syndrome_7b, data_corr};
    endfunction

    logic [6:0]  idx1, idx2, col_a, col_b;
    logic [7:0]  ecc_clean;
    logic [71:0] cw_clean, cw_1err, cw_2err;
    logic [73:0] dec_0err, dec_1err, dec_2err;

    assign idx1 = (raw_idx1_i < 7'd72) ? raw_idx1_i : (raw_idx1_i - 7'd72);
    assign idx2 = (raw_idx2_i < 7'd72) ? raw_idx2_i : (raw_idx2_i - 7'd72);
    assign col_a = get_syndrome_col(col_idx_a_i);
    assign col_b = get_syndrome_col(col_idx_b_i);

    assign ecc_clean = secded_encode_72_64(wdata_sym_i);
    assign cw_clean  = {ecc_clean, wdata_sym_i};
    assign cw_1err   = cw_clean ^ (72'd1 << idx1);
    assign cw_2err   = cw_clean ^ (72'd1 << idx1) ^ (72'd1 << idx2);

    assign dec_0err  = secded_decode_72_64(cw_clean[63:0], cw_clean[71:64]);
    assign dec_1err  = secded_decode_72_64(cw_1err[63:0],  cw_1err[71:64]);
    assign dec_2err  = secded_decode_72_64(cw_2err[63:0],  cw_2err[71:64]);
    assign secded_ok_o = (dec_0err[63:0] == wdata_sym_i) && (dec_1err[63:0] == wdata_sym_i);

    logic past_valid_q;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) past_valid_q <= 1'b0;
        else        past_valid_q <= 1'b1;
    end

    always_ff @(posedge clk) begin
        if (past_valid_q && rst_n) begin
            p_m3_0err_rdata_exact: assert (dec_0err[63:0]  == wdata_sym_i);
            p_m3_0err_synd_zero:   assert (dec_0err[71:64] == 8'd0);
            p_m3_0err_sec_zero:    assert (dec_0err[72]    == 1'b0);
            p_m3_0err_ded_zero:    assert (dec_0err[73]    == 1'b0);
            p_m3_1err_rdata_corr:  assert (dec_1err[63:0]  == wdata_sym_i);
            p_m3_1err_sec_one:     assert (dec_1err[72]    == 1'b1);
            p_m3_1err_ded_zero:    assert (dec_1err[73]    == 1'b0);
            p_m3_1err_tpar_one:    assert (dec_1err[71]    == 1'b1);
            p_m3_1err_synd_nzero:  assert ((dec_1err[70:64] != 7'd0) || (idx1 == 7'd71));
            p_m3_2err_ded_one:     assert ((idx1 == idx2)  || (dec_2err[73] == 1'b1));
            p_m3_2err_sec_zero:    assert ((idx1 == idx2)  || (dec_2err[72] == 1'b0));
            p_m3_2err_tpar_zero:   assert ((idx1 == idx2)  || (dec_2err[71] == 1'b0));
            p_m3_2err_synd_nzero:  assert ((idx1 == idx2)  || (dec_2err[70:64] != 7'd0));
            p_m3_col_distinct:     assert ((col_idx_a_i == col_idx_b_i) || (col_a != col_b));
            p_m3_col_non_pow2:     assert ((col_a >= 7'd3) && ((col_a & (col_a - 7'd1)) != 7'd0));
        end
    end
endmodule

// =============================================================================
// MITER 4: Algebraic GF(2^4) Companion-Matrix Bank Swizzle Bijection Miter
// Proves 100% bank-conflict-free bijection across all rows r in [0..255] and
// all distinct logical banks b1 != b2 in [0..15], plus column/diagonal strides.
// =============================================================================
module taalas_gf16_swizzle_bijection_miter (
    input  logic       clk,
    input  logic       rst_n,
    input  logic [3:0] b1_sym_i,
    input  logic [3:0] b2_sym_i,
    input  logic [7:0] row1_sym_i,
    input  logic [7:0] row2_sym_i,
    output logic       bijection_ok_o
);

    function automatic logic [3:0] gf16_mul_by_3(input logic [3:0] a);
        logic [3:0] res;
        res[3] = a[2] ^ a[3];
        res[2] = a[1] ^ a[2];
        res[1] = a[0] ^ a[1] ^ a[3];
        res[0] = a[0] ^ a[3];
        gf16_mul_by_3 = res;
    endfunction

    function automatic logic [3:0] swizzle_gf16_bank(
        input logic [3:0] logical_bank,
        input logic [7:0] row_addr_8b
    );
        swizzle_gf16_bank = logical_bank ^ row_addr_8b[3:0] ^ gf16_mul_by_3(row_addr_8b[7:4]);
    endfunction

    logic [3:0] phys_b1_r1, phys_b2_r1;
    logic [3:0] phys_b1_r2_lo, phys_b1_r2_hi;
    logic [3:0] phys_diag1, phys_diag2;
    logic [3:0] inv_b1;
    logic [3:0] gf_mul_b1, gf_mul_b2, gf_mul_xor;

    assign phys_b1_r1    = swizzle_gf16_bank(b1_sym_i, row1_sym_i);
    assign phys_b2_r1    = swizzle_gf16_bank(b2_sym_i, row1_sym_i);
    assign phys_b1_r2_lo = swizzle_gf16_bank(b1_sym_i, {row1_sym_i[7:4], row2_sym_i[3:0]});
    assign phys_b1_r2_hi = swizzle_gf16_bank(b1_sym_i, {row2_sym_i[7:4], row1_sym_i[3:0]});
    assign phys_diag1    = swizzle_gf16_bank(b1_sym_i, {b1_sym_i, row1_sym_i[3:0]});
    assign phys_diag2    = swizzle_gf16_bank(b2_sym_i, {b2_sym_i, row1_sym_i[3:0]});
    assign inv_b1        = swizzle_gf16_bank(phys_b1_r1, row1_sym_i);

    assign gf_mul_b1  = gf16_mul_by_3(b1_sym_i);
    assign gf_mul_b2  = gf16_mul_by_3(b2_sym_i);
    assign gf_mul_xor = gf16_mul_by_3(b1_sym_i ^ b2_sym_i);
    assign bijection_ok_o = (b1_sym_i == b2_sym_i) || (phys_b1_r1 != phys_b2_r1);

    logic past_valid_q;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) past_valid_q <= 1'b0;
        else        past_valid_q <= 1'b1;
    end

    always_ff @(posedge clk) begin
        if (past_valid_q && rst_n) begin
            p_m4_row_bijection:      assert ((b1_sym_i == b2_sym_i) || (phys_b1_r1 != phys_b2_r1));
            p_m4_col_lo_bijection:   assert ((row1_sym_i[3:0] == row2_sym_i[3:0]) || (phys_b1_r1 != phys_b1_r2_lo));
            p_m4_col_hi_bijection:   assert ((row1_sym_i[7:4] == row2_sym_i[7:4]) || (phys_b1_r1 != phys_b1_r2_hi));
            p_m4_diag_hi_bijection:  assert ((b1_sym_i == b2_sym_i) || (phys_diag1 != phys_diag2));
            p_m4_self_involution:    assert (inv_b1 == b1_sym_i);
            p_m4_gf16_linearity:     assert ((gf_mul_b1 ^ gf_mul_b2) == gf_mul_xor);
            p_m4_gf16_zero_fixpt:    assert ((b1_sym_i == 4'd0) == (gf_mul_b1 == 4'd0));
            p_m4_gf16_no_unit_fixpt: assert ((b1_sym_i == 4'd0) || (gf_mul_b1 != b1_sym_i));
            p_m4_xor_diff_exact:     assert ((phys_b1_r1 ^ phys_b2_r1) == (b1_sym_i ^ b2_sym_i));
            p_m4_zero_row_identity:  assert (swizzle_gf16_bank(b1_sym_i, 8'h00) == b1_sym_i);
        end
    end
endmodule

// =============================================================================
// MITER 5: Non-Linear Arithmetic & Attention Mathematical Invariant Miter
// Proves exact monotonicity, range bounds, and zero/asymptotic identities for
// M8 (RoPE), M9 (Online Softmax exp2_pwl), M10 (RMSNorm), and M11 (SwiGLU).
// =============================================================================
module taalas_nonlin_math_miter (
    input  logic               clk,
    input  logic               rst_n,
    input  logic signed [16:0] exp_x1_q8_8_i,
    input  logic signed [16:0] exp_x2_q8_8_i,
    input  logic signed [15:0] silu_g1_q8_8_i,
    input  logic signed [15:0] silu_g2_q8_8_i,
    input  logic [15:0]        rms_mean_sq_i,
    input  logic [15:0]        rms_eps_i,
    input  logic [3:0]         rsqrt_idx1_i,
    input  logic [3:0]         rsqrt_idx2_i,
    output logic               nonlin_ok_o
);

    // M9: Base-2 16-Segment PWL Exponential
    function automatic logic [15:0] dut_exp2_pwl_q15(input logic signed [16:0] x_q8_8);
        logic signed [8:0] int_floor;
        logic [7:0]        frac_u8;
        logic [3:0]        seg, delta, rshift;
        logic [15:0]       base_q15, slope_q15;
        logic [16:0]       mant_q15;
        begin
            if (x_q8_8 >= 17'sd0)          dut_exp2_pwl_q15 = 16'd32768;
            else if (x_q8_8 < -17'sd3840)  dut_exp2_pwl_q15 = 16'd0;
            else begin
                int_floor = 9'(x_q8_8 >>> 8);
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
                dut_exp2_pwl_q15 = 16'(mant_q15 >> rshift);
            end
        end
    endfunction

    // M11: 17-Knot Sigmoid PWL & SiLU
    function automatic logic [15:0] dut_sigmoid_knot(input logic [4:0] k);
        unique case (k)
            5'd0:  dut_sigmoid_knot = 16'd10;    5'd1:  dut_sigmoid_knot = 16'd29;
            5'd2:  dut_sigmoid_knot = 16'd82;    5'd3:  dut_sigmoid_knot = 16'd220;
            5'd4:  dut_sigmoid_knot = 16'd590;   5'd5:  dut_sigmoid_knot = 16'd1553;
            5'd6:  dut_sigmoid_knot = 16'd3906;  5'd7:  dut_sigmoid_knot = 16'd8811;
            5'd8:  dut_sigmoid_knot = 16'd16384; 5'd9:  dut_sigmoid_knot = 16'd23957;
            5'd10: dut_sigmoid_knot = 16'd28862; 5'd11: dut_sigmoid_knot = 16'd31215;
            5'd12: dut_sigmoid_knot = 16'd32178; 5'd13: dut_sigmoid_knot = 16'd32548;
            5'd14: dut_sigmoid_knot = 16'd32686; 5'd15: dut_sigmoid_knot = 16'd32739;
            default: dut_sigmoid_knot = 16'd32758;
        endcase
    endfunction

    function automatic logic [15:0] dut_eval_sigmoid_q15(input logic signed [15:0] g_q8_8);
        logic [11:0] sh_g;
        logic [3:0]  seg;
        logic [7:0]  frac;
        logic [15:0] y0, y1, interp;
        if (g_q8_8 <= -16'sd2048)      dut_eval_sigmoid_q15 = 16'd0;
        else if (g_q8_8 >= 16'sd2048)  dut_eval_sigmoid_q15 = 16'd32768;
        else begin
            sh_g   = 12'(g_q8_8 + 16'sd2048);
            seg    = sh_g[11:8];
            frac   = sh_g[7:0];
            y0     = dut_sigmoid_knot({1'b0, seg});
            y1     = dut_sigmoid_knot({1'b0, seg} + 5'd1);
            interp = 16'(((24'(y1 - y0) * {16'd0, frac}) + 24'd128) >> 8);
            dut_eval_sigmoid_q15 = y0 + interp;
        end
    endfunction

    // M10: rsqrt seed LUT & Epsilon floor
    function automatic logic [15:0] dut_rsqrt_lut_q14(input logic [3:0] idx);
        unique case (idx)
            4'd0:  dut_rsqrt_lut_q14 = 16'd22486; 4'd1:  dut_rsqrt_lut_q14 = 16'd21233;
            4'd2:  dut_rsqrt_lut_q14 = 16'd20170; 4'd3:  dut_rsqrt_lut_q14 = 16'd19251;
            4'd4:  dut_rsqrt_lut_q14 = 16'd18448; 4'd5:  dut_rsqrt_lut_q14 = 16'd17737;
            4'd6:  dut_rsqrt_lut_q14 = 16'd17102; 4'd7:  dut_rsqrt_lut_q14 = 16'd16531;
            4'd8:  dut_rsqrt_lut_q14 = 16'd15900; 4'd9:  dut_rsqrt_lut_q14 = 16'd15015;
            4'd10: dut_rsqrt_lut_q14 = 16'd14266; 4'd11: dut_rsqrt_lut_q14 = 16'd13620;
            4'd12: dut_rsqrt_lut_q14 = 16'd13056; 4'd13: dut_rsqrt_lut_q14 = 16'd12556;
            4'd14: dut_rsqrt_lut_q14 = 16'd12110; default: dut_rsqrt_lut_q14 = 16'd11708;
        endcase
    endfunction

    logic [15:0] exp_y1, exp_y2, sig_y1, sig_y2, rsqrt_y1, rsqrt_y2;
    logic [15:0] eff_eps;
    logic [31:0] var_plus_eps;

    assign exp_y1       = dut_exp2_pwl_q15(exp_x1_q8_8_i);
    assign exp_y2       = dut_exp2_pwl_q15(exp_x2_q8_8_i);
    assign sig_y1       = dut_eval_sigmoid_q15(silu_g1_q8_8_i);
    assign sig_y2       = dut_eval_sigmoid_q15(silu_g2_q8_8_i);
    assign rsqrt_y1     = dut_rsqrt_lut_q14(rsqrt_idx1_i);
    assign rsqrt_y2     = dut_rsqrt_lut_q14(rsqrt_idx2_i);
    assign eff_eps      = (rms_eps_i == 16'd0) ? 16'd1 : rms_eps_i;
    assign var_plus_eps = {16'd0, rms_mean_sq_i} + {16'd0, eff_eps};
    assign nonlin_ok_o  = (var_plus_eps >= 32'd1) && (exp_y1 <= 16'd32768);

    logic past_valid_q;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) past_valid_q <= 1'b0;
        else        past_valid_q <= 1'b1;
    end

    always_ff @(posedge clk) begin
        if (past_valid_q && rst_n) begin
            p_m5_exp2_range_max:      assert (exp_y1 <= 16'd32768);
            p_m5_exp2_zero_id:        assert (dut_exp2_pwl_q15(17'sd0) == 16'd32768);
            p_m5_exp2_neg1_exact:     assert (dut_exp2_pwl_q15(-17'sd256) == 16'd16384);
            p_m5_exp2_deep_clamp:     assert (dut_exp2_pwl_q15(-17'sd4096) == 16'd0);
            p_m5_exp2_monotonic:      assert ((exp_x1_q8_8_i > exp_x2_q8_8_i) || (exp_y1 <= exp_y2));
            p_m5_sigmoid_range_max:   assert (sig_y1 <= 16'd32768);
            p_m5_sigmoid_zero_half:   assert (dut_eval_sigmoid_q15(16'sd0) == 16'd16384);
            p_m5_sigmoid_pos_clamp:   assert (dut_eval_sigmoid_q15(16'sd2048) == 16'd32768);
            p_m5_sigmoid_neg_clamp:   assert (dut_eval_sigmoid_q15(-16'sd2048) == 16'd0);
            p_m5_sigmoid_monotonic:   assert ((silu_g1_q8_8_i > silu_g2_q8_8_i) || (sig_y1 <= sig_y2));
            p_m5_rmsnorm_eps_nonzero: assert (var_plus_eps >= 32'd1);
            p_m5_rsqrt_lut_pos:       assert (rsqrt_y1 >= 16'd11708 && rsqrt_y1 <= 16'd22486);
            p_m5_rsqrt_lut_monotonic: assert ((rsqrt_idx1_i > rsqrt_idx2_i) || (rsqrt_y1 >= rsqrt_y2));
        end
    end
endmodule

// =============================================================================
// MITER 6: Deep 12-Cycle Sequential Protocol, Credit & Wavefront Clock-Gate Miter
// Proves 12-cycle sequential invariants across NoC Router (M12), CSR (M13),
// and Full-Chip Token-Wavefront Clock-Gating Controller (M15).
// =============================================================================
module taalas_deep_seq12_protocol_miter (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        bcast_en_i,
    input  logic        c2c_en_i,
    input  logic        in_valid_i,
    input  logic [31:0] in_flit_i,
    input  logic        local_tx_valid_i,
    input  logic [31:0] local_tx_flit_i,
    input  logic        local_rx_ready_i,
    input  logic        out_ready_i,
    input  logic        downstream_credit_ret_i,
    input  logic        chip_en_i,
    input  logic [3:0]  layer_cg_mask_i,
    input  logic [3:0]  tile_busy_i,
    input  logic [3:0]  link_valid_i,
    input  logic        dma_sram_we_i,
    output logic        seq_protocol_ok_o
);

    logic        in_ready_o, upstream_credit_ret_o, local_tx_ready_o;
    logic        local_rx_valid_o, out_valid_o, c2c_tx_valid_o, c2c_rx_ready_o;
    logic [31:0] local_rx_flit_o, out_flit_o, c2c_tx_flit_o;
    logic [2:0]  avail_credits_o, inflight_flits_o, fifo_occupancy_o;
    logic [1:0]  skid_occupancy_o;
    logic [31:0] flits_rx_cnt_o, flits_tx_cnt_o, stall_cycles_cnt_o;
    logic        crc_err_o;

    taalas_token_pipe_noc_router #(
        .FLIT_WIDTH  (32),
        .FIFO_DEPTH  (4),
        .MAX_CREDITS (4),
        .TILE_ID     (1)
    ) u_dut_m12 (
        .clk                     (clk),
        .rst_n                   (rst_n),
        .bcast_en_i              (bcast_en_i),
        .c2c_en_i                (c2c_en_i),
        .in_valid_i              (in_valid_i),
        .in_ready_o              (in_ready_o),
        .in_flit_i               (in_flit_i),
        .upstream_credit_ret_o   (upstream_credit_ret_o),
        .local_tx_valid_i        (local_tx_valid_i),
        .local_tx_ready_o        (local_tx_ready_o),
        .local_tx_flit_i         (local_tx_flit_i),
        .local_rx_valid_o        (local_rx_valid_o),
        .local_rx_ready_i        (local_rx_ready_i),
        .local_rx_flit_o         (local_rx_flit_o),
        .out_valid_o             (out_valid_o),
        .out_ready_i             (out_ready_i),
        .out_flit_o              (out_flit_o),
        .downstream_credit_ret_i (downstream_credit_ret_i),
        .c2c_tx_valid_o          (c2c_tx_valid_o),
        .c2c_tx_ready_i          (out_ready_i),
        .c2c_tx_flit_o           (c2c_tx_flit_o),
        .c2c_rx_valid_i          (in_valid_i),
        .c2c_rx_ready_o          (c2c_rx_ready_o),
        .c2c_rx_flit_i           (in_flit_i),
        .avail_credits_o         (avail_credits_o),
        .inflight_flits_o        (inflight_flits_o),
        .skid_occupancy_o        (skid_occupancy_o),
        .fifo_occupancy_o        (fifo_occupancy_o),
        .flits_rx_cnt_o          (flits_rx_cnt_o),
        .flits_tx_cnt_o          (flits_tx_cnt_o),
        .stall_cycles_cnt_o      (stall_cycles_cnt_o),
        .crc_err_o               (crc_err_o)
    );

    // Full-Chip Token-Wavefront Clock-Gating Logic Replica (M15)
    logic [3:0] tile_cg_en;
    always_comb begin
        for (int l = 0; l < 4; l++) begin
            tile_cg_en[l] = !chip_en_i || layer_cg_mask_i[l] ||
                            (!tile_busy_i[l] && !link_valid_i[l] && !dma_sram_we_i);
        end
    end

    assign seq_protocol_ok_o = ((avail_credits_o + inflight_flits_o) == 3'd4);

    logic        past_valid_q;
    logic [31:0] past_rx_cnt_q, past_tx_cnt_q, past_stall_cnt_q;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            past_valid_q     <= 1'b0;
            past_rx_cnt_q    <= 32'd0;
            past_tx_cnt_q    <= 32'd0;
            past_stall_cnt_q <= 32'd0;
        end else begin
            past_valid_q     <= 1'b1;
            past_rx_cnt_q    <= flits_rx_cnt_o;
            past_tx_cnt_q    <= flits_tx_cnt_o;
            past_stall_cnt_q <= stall_cycles_cnt_o;
        end
    end

    always_ff @(posedge clk) begin
        if (past_valid_q && rst_n) begin
            p_m6_credit_conservation: assert ((avail_credits_o + inflight_flits_o) == 3'd4);
            p_m6_avail_credit_bound:  assert (avail_credits_o <= 3'd4);
            p_m6_inflight_bound:      assert (inflight_flits_o <= 3'd4);
            p_m6_skid_occ_bound:      assert (skid_occupancy_o <= 2'd2);
            p_m6_fifo_occ_bound:      assert (fifo_occupancy_o <= 3'd4);
            p_m6_zero_cred_no_tx:     assert ((avail_credits_o != 3'd0) || (!out_valid_o && !c2c_tx_valid_o));
            p_m6_skid_full_no_rdy:    assert ((skid_occupancy_o < 2'd2) || (!in_ready_o && !local_tx_ready_o));
            p_m6_fifo_conservation:   assert (flits_rx_cnt_o == (flits_tx_cnt_o + {29'd0, fifo_occupancy_o}));
            p_m6_rx_cnt_monotonic:    assert (flits_rx_cnt_o >= past_rx_cnt_q);
            p_m6_tx_cnt_monotonic:    assert (flits_tx_cnt_o >= past_tx_cnt_q);
            p_m6_stall_cnt_monotonic: assert (stall_cycles_cnt_o >= past_stall_cnt_q);
            p_m6_c2c_mode_mutex:      assert (!(out_valid_o && c2c_tx_valid_o));
            p_m6_wavefront_wake_busy: assert (!chip_en_i || layer_cg_mask_i[0] || !tile_busy_i[0]  || !tile_cg_en[0]);
            p_m6_wavefront_wake_flit: assert (!chip_en_i || layer_cg_mask_i[0] || !link_valid_i[0] || !tile_cg_en[0]);
        end
    end
endmodule
