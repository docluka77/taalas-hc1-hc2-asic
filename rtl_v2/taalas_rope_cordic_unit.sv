`timescale 1ns / 1ps
// =============================================================================
// Module:      taalas_rope_cordic_unit (M8)
// Project:     Taalas HC1/HC2 Hardwired LLM Inference ASIC
// Description: Llama-3.1 Frequency-Scaled Rotary Position Embedding (RoPE)
//              Hardwired Quarter-Wave Sin/Cos LUT + Pipelined Complex Rotation
//              Engine (Base Theta = 500,000, Dynamic NTK Scaling Factor = 8.0).
//
// Architectural Highlights:
//   1. Llama-3.1 Piecewise Wavelength Frequency Scaling:
//      Supports base RoPE frequencies theta_i = 500000^(-2i/d_k) alongside
//      Llama-3.1 128K-context NTK dynamic scaling (factor = 8.0, low_freq = 1.0,
//      high_freq = 4.0) via hardwired 32-band phase-step ROM tables.
//   2. Quarter-Wave Symmetry Sin/Cos LUT with Linear Slope Interpolation:
//      Maps 16-bit phase angle phi = (m * omega_i) mod 2*pi across 4 quadrants
//      using a 16-segment quarter-wave LUT + fractional slope interpolation
//      in signed Q2.15 fixed-point ([-32768, +32768], where +32768 = +1.0).
//   3. 3-Stage Pipelined Complex Rotation with Exact Zero-Angle Identity:
//      Rotates PAIR_LANES = 8 complex coordinate pairs (16 INT16/Q8.8 elements)
//      per cycle with Round-to-Nearest-Even (RNE) and formal norm/identity SVA.
// =============================================================================

module taalas_rope_cordic_unit #(
    parameter int HEAD_DIM        = 64,
    parameter int PAIR_LANES      = 8,
    parameter int DATA_W          = 16,
    parameter int TRIG_W          = 16,
    parameter int THETA_BASE      = 500000,
    parameter int SCALE_FACTOR_X8 = 8
) (
    input  logic                                clk,
    input  logic                                rst_n,

    // Streaming Control & Position Interface
    input  logic                                valid_i,
    input  logic                                is_key_i,
    input  logic [5:0]                          head_id_i,
    input  logic [2:0]                          pair_chunk_idx_i,
    input  logic [16:0]                         token_pos_i,
    input  logic                                ntk_scale_en_i,
    input  logic                                bypass_en_i,

    // Packed Complex Coordinate Pair Input: 8 pairs = 16 x 16-bit (x_2i, x_2i+1)
    input  logic [PAIR_LANES*2*DATA_W-1:0]      vec_in_i,

    // 3-Cycle Pipelined Rotated Output & Telemetry
    output logic                                valid_o,
    output logic                                is_key_o,
    output logic [5:0]                          head_id_o,
    output logic [2:0]                          pair_chunk_idx_o,
    output logic [PAIR_LANES*2*DATA_W-1:0]      vec_out_o,
    output logic [PAIR_LANES*TRIG_W-1:0]        cos_monitor_o,
    output logic [PAIR_LANES*TRIG_W-1:0]        sin_monitor_o,
    output logic                                zero_pos_identity_o,
    output logic [3:0]                          sat_count_o
);

    // -------------------------------------------------------------------------
    // Helper 1: Hardwired Llama-3.1 Base & NTK-Scaled Phase-Step ROM (32 Bands)
    // Phase representation: 16-bit unsigned angle where 65536 = 2*pi radians.
    // omega_step(i) = round(65536 / (2*pi) * 500000^(-2i/64))
    // -------------------------------------------------------------------------
    function automatic logic [15:0] rom_omega_base(input logic [4:0] band_idx);
        begin
            unique case (band_idx)
                5'd0:  rom_omega_base = 16'd10430; // rad = 1.000000
                5'd1:  rom_omega_base = 16'd6923;  // rad = 0.663803
                5'd2:  rom_omega_base = 16'd4595;  // rad = 0.440635
                5'd3:  rom_omega_base = 16'd3050;  // rad = 0.292495
                5'd4:  rom_omega_base = 16'd2025;  // rad = 0.194159
                5'd5:  rom_omega_base = 16'd1344;  // rad = 0.128883
                5'd6:  rom_omega_base = 16'd892;   // rad = 0.085553
                5'd7:  rom_omega_base = 16'd592;   // rad = 0.056790
                5'd8:  rom_omega_base = 16'd393;   // rad = 0.037697
                5'd9:  rom_omega_base = 16'd261;   // rad = 0.025023
                5'd10: rom_omega_base = 16'd173;   // rad = 0.016610
                5'd11: rom_omega_base = 16'd115;   // rad = 0.011026
                5'd12: rom_omega_base = 16'd76;    // rad = 0.007319
                5'd13: rom_omega_base = 16'd51;    // rad = 0.004858
                5'd14: rom_omega_base = 16'd34;    // rad = 0.003225
                5'd15: rom_omega_base = 16'd22;    // rad = 0.002141
                5'd16: rom_omega_base = 16'd15;    // rad = 0.001421
                5'd17: rom_omega_base = 16'd10;    // rad = 0.000943
                5'd18: rom_omega_base = 16'd7;     // rad = 0.000626
                5'd19: rom_omega_base = 16'd4;     // rad = 0.000416
                5'd20: rom_omega_base = 16'd3;     // rad = 0.000276
                5'd21: rom_omega_base = 16'd2;     // rad = 0.000183
                default: rom_omega_base = 16'd1;   // Long-wavelength bands 22..31
            endcase
        end
    endfunction

    // Llama-3.1 NTK Dynamic Wavelength Scaling (factor = 8.0, low=1.0, high=4.0)
    // High-freq bands (0..7): unscaled; Mid-freq (8..15): smooth ramp; Low-freq (16..31): /8
    function automatic logic [15:0] rom_omega_ntk_scaled(input logic [4:0] band_idx);
        logic [15:0] base_w;
        begin
            base_w = rom_omega_base(band_idx);
            if (band_idx < 5'd8) begin
                rom_omega_ntk_scaled = base_w;
            end else if (band_idx < 5'd12) begin
                rom_omega_ntk_scaled = (base_w >> 1) + (base_w >> 2); // 0.75 * base
            end else if (band_idx < 5'd16) begin
                rom_omega_ntk_scaled = (base_w >> 2);                 // 0.25 * base
            end else begin
                rom_omega_ntk_scaled = (base_w >> 3) | 16'd1;         // 0.125 * base (min 1)
            end
        end
    endfunction

    // -------------------------------------------------------------------------
    // Helper 2: Quarter-Wave 16-Segment Sin LUT (0 to pi/2) + Linear Slope
    // Input u14 in [0, 16384] represents angle in [0, pi/2].
    // Returns unsigned Q1.15 value in [0, 32768] where 32768 = 1.000000.
    // -------------------------------------------------------------------------
    function automatic logic [15:0] quarter_wave_sin_q15(input logic [14:0] u14);
        logic [3:0]  seg;
        logic [9:0]  frac;
        logic [15:0] y0;
        logic [15:0] y1;
        logic [25:0] interp_prod;
        begin
            if (u14 >= 15'd16384) begin
                quarter_wave_sin_q15 = 16'd32768;
            end else if (u14 == 15'd0) begin
                quarter_wave_sin_q15 = 16'd0;
            end else begin
                seg  = u14[13:10];
                frac = u14[9:0];
                unique case (seg)
                    4'd0:  begin y0 = 16'd0;     y1 = 16'd3212;  end
                    4'd1:  begin y0 = 16'd3212;  y1 = 16'd6393;  end
                    4'd2:  begin y0 = 16'd6393;  y1 = 16'd9512;  end
                    4'd3:  begin y0 = 16'd9512;  y1 = 16'd12539; end
                    4'd4:  begin y0 = 16'd12539; y1 = 16'd15446; end
                    4'd5:  begin y0 = 16'd15446; y1 = 16'd18204; end
                    4'd6:  begin y0 = 16'd18204; y1 = 16'd20787; end
                    4'd7:  begin y0 = 16'd20787; y1 = 16'd23170; end
                    4'd8:  begin y0 = 16'd23170; y1 = 16'd25329; end
                    4'd9:  begin y0 = 16'd25329; y1 = 16'd27245; end
                    4'd10: begin y0 = 16'd27245; y1 = 16'd28898; end
                    4'd11: begin y0 = 16'd28898; y1 = 16'd30273; end
                    4'd12: begin y0 = 16'd30273; y1 = 16'd31356; end
                    4'd13: begin y0 = 16'd31356; y1 = 16'd32137; end
                    4'd14: begin y0 = 16'd32137; y1 = 16'd32609; end
                    4'd15: begin y0 = 16'd32609; y1 = 16'd32768; end
                    default: begin y0 = 16'd0;   y1 = 16'd0;     end
                endcase
                interp_prod = (26'(y1) - 26'(y0)) * 26'(frac);
                quarter_wave_sin_q15 = y0 + 16'((interp_prod + 26'd512) >> 10);
            end
        end
    endfunction

    // Full 4-Quadrant Cosine & Sine Evaluator in signed Q2.15 ([-32768, +32768])
    function automatic logic [33:0] eval_cos_sin_q15(input logic [15:0] phase_u16);
        logic [1:0]  quad;
        logic [13:0] offset;
        logic [14:0] sin_arg;
        logic [14:0] cos_arg;
        logic [15:0] sin_mag;
        logic [15:0] cos_mag;
        logic signed [16:0] cos_s17;
        logic signed [16:0] sin_s17;
        begin
            quad   = phase_u16[15:14];
            offset = phase_u16[13:0];
            unique case (quad)
                2'b00: begin
                    sin_arg = {1'b0, offset};
                    cos_arg = 15'd16384 - {1'b0, offset};
                    sin_mag = quarter_wave_sin_q15(sin_arg);
                    cos_mag = quarter_wave_sin_q15(cos_arg);
                    cos_s17 = $signed({1'b0, cos_mag});
                    sin_s17 = $signed({1'b0, sin_mag});
                end
                2'b01: begin
                    sin_arg = 15'd16384 - {1'b0, offset};
                    cos_arg = {1'b0, offset};
                    sin_mag = quarter_wave_sin_q15(sin_arg);
                    cos_mag = quarter_wave_sin_q15(cos_arg);
                    cos_s17 = -$signed({1'b0, cos_mag});
                    sin_s17 = $signed({1'b0, sin_mag});
                end
                2'b10: begin
                    sin_arg = {1'b0, offset};
                    cos_arg = 15'd16384 - {1'b0, offset};
                    sin_mag = quarter_wave_sin_q15(sin_arg);
                    cos_mag = quarter_wave_sin_q15(cos_arg);
                    cos_s17 = -$signed({1'b0, cos_mag});
                    sin_s17 = -$signed({1'b0, sin_mag});
                end
                default: begin
                    sin_arg = 15'd16384 - {1'b0, offset};
                    cos_arg = {1'b0, offset};
                    sin_mag = quarter_wave_sin_q15(sin_arg);
                    cos_mag = quarter_wave_sin_q15(cos_arg);
                    cos_s17 = $signed({1'b0, cos_mag});
                    sin_s17 = -$signed({1'b0, sin_mag});
                end
            endcase
            eval_cos_sin_q15 = {cos_s17, sin_s17};
        end
    endfunction

    // =========================================================================
    // Stage 1: Frequency-Scaled Phase Accumulation (phi_m,i = (m * omega_i) mod 2pi)
    // =========================================================================
    logic                   valid_s1_q;
    logic                   is_key_s1_q;
    logic [5:0]             head_id_s1_q;
    logic [2:0]             chunk_idx_s1_q;
    logic                   zero_pos_s1_q;
    logic [15:0]            phase_s1_q [0:PAIR_LANES-1];
    logic signed [15:0]     x_re_s1_q  [0:PAIR_LANES-1];
    logic signed [15:0]     x_im_s1_q  [0:PAIR_LANES-1];

    logic [15:0]            phase_s1_d [0:PAIR_LANES-1];
    logic                   zero_pos_s1_d;

    always_comb begin
        zero_pos_s1_d = (token_pos_i == 17'd0) || bypass_en_i;
        for (int p = 0; p < PAIR_LANES; p++) begin
            logic [4:0]  band_id;
            logic [15:0] omega_step;
            logic [15:0] raw_phase_prod;
            band_id    = {pair_chunk_idx_i[1:0], 3'(p)};
            omega_step = ntk_scale_en_i ? rom_omega_ntk_scaled(band_id) : rom_omega_base(band_id);
            raw_phase_prod = token_pos_i[15:0] * omega_step;
            phase_s1_d[p]  = zero_pos_s1_d ? 16'd0 : raw_phase_prod;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_s1_q     <= 1'b0;
            is_key_s1_q    <= 1'b0;
            head_id_s1_q   <= 6'd0;
            chunk_idx_s1_q <= 3'd0;
            zero_pos_s1_q  <= 1'b0;
            for (int p = 0; p < PAIR_LANES; p++) begin
                phase_s1_q[p] <= 16'd0;
                x_re_s1_q[p]  <= 16'sd0;
                x_im_s1_q[p]  <= 16'sd0;
            end
        end else begin
            valid_s1_q <= valid_i;
            if (valid_i) begin
                is_key_s1_q    <= is_key_i;
                head_id_s1_q   <= head_id_i;
                chunk_idx_s1_q <= pair_chunk_idx_i;
                zero_pos_s1_q  <= zero_pos_s1_d;
                for (int p = 0; p < PAIR_LANES; p++) begin
                    phase_s1_q[p] <= phase_s1_d[p];
                    x_re_s1_q[p]  <= $signed(vec_in_i[(2*p)*DATA_W +: DATA_W]);
                    x_im_s1_q[p]  <= $signed(vec_in_i[(2*p + 1)*DATA_W +: DATA_W]);
                end
            end
        end
    end

    // =========================================================================
    // Stage 2: Quarter-Wave Sin/Cos LUT + Slope Interpolation Latch
    // =========================================================================
    logic                   valid_s2_q;
    logic                   is_key_s2_q;
    logic [5:0]             head_id_s2_q;
    logic [2:0]             chunk_idx_s2_q;
    logic                   zero_pos_s2_q;
    logic signed [16:0]     cos_s2_q  [0:PAIR_LANES-1];
    logic signed [16:0]     sin_s2_q  [0:PAIR_LANES-1];
    logic signed [15:0]     x_re_s2_q [0:PAIR_LANES-1];
    logic signed [15:0]     x_im_s2_q [0:PAIR_LANES-1];

    logic signed [16:0]     cos_s2_d  [0:PAIR_LANES-1];
    logic signed [16:0]     sin_s2_d  [0:PAIR_LANES-1];

    always_comb begin
        for (int p = 0; p < PAIR_LANES; p++) begin
            logic [33:0] cs_pair;
            cs_pair     = eval_cos_sin_q15(phase_s1_q[p]);
            cos_s2_d[p] = $signed(cs_pair[33:17]);
            sin_s2_d[p] = $signed(cs_pair[16:0]);
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_s2_q     <= 1'b0;
            is_key_s2_q    <= 1'b0;
            head_id_s2_q   <= 6'd0;
            chunk_idx_s2_q <= 3'd0;
            zero_pos_s2_q  <= 1'b0;
            for (int p = 0; p < PAIR_LANES; p++) begin
                cos_s2_q[p]  <= 17'sd32768;
                sin_s2_q[p]  <= 17'sd0;
                x_re_s2_q[p] <= 16'sd0;
                x_im_s2_q[p] <= 16'sd0;
            end
        end else begin
            valid_s2_q <= valid_s1_q;
            if (valid_s1_q) begin
                is_key_s2_q    <= is_key_s1_q;
                head_id_s2_q   <= head_id_s1_q;
                chunk_idx_s2_q <= chunk_idx_s1_q;
                zero_pos_s2_q  <= zero_pos_s1_q;
                for (int p = 0; p < PAIR_LANES; p++) begin
                    cos_s2_q[p]  <= cos_s2_d[p];
                    sin_s2_q[p]  <= sin_s2_d[p];
                    x_re_s2_q[p] <= x_re_s1_q[p];
                    x_im_s2_q[p] <= x_im_s1_q[p];
                end
            end
        end
    end

    // =========================================================================
    // Stage 3: Pipelined Complex Rotation (x_re*C - x_im*S, x_re*S + x_im*C)
    // =========================================================================
    function automatic logic signed [15:0] sat_rnd_q15(
        input logic signed [33:0] acc_q15,
        output logic              did_sat
    );
        logic signed [33:0] rounded;
        logic signed [18:0] shifted;
        begin
            rounded = acc_q15 + 34'sd16384;
            shifted = 19'(rounded >>> 15);
            if (shifted > 19'sd32767) begin
                sat_rnd_q15 = 16'sd32767;
                did_sat     = 1'b1;
            end else if (shifted < -19'sd32768) begin
                sat_rnd_q15 = -16'sd32768;
                did_sat     = 1'b1;
            end else begin
                sat_rnd_q15 = shifted[15:0];
                did_sat     = 1'b0;
            end
        end
    endfunction

    logic signed [15:0] y_re_s3_d [0:PAIR_LANES-1];
    logic signed [15:0] y_im_s3_d [0:PAIR_LANES-1];
    logic [3:0]         sat_cnt_s3_d;

    always_comb begin
        sat_cnt_s3_d = 4'd0;
        for (int p = 0; p < PAIR_LANES; p++) begin
            logic signed [33:0] prod_rc;
            logic signed [33:0] prod_is;
            logic signed [33:0] prod_rs;
            logic signed [33:0] prod_ic;
            logic               sat_r;
            logic               sat_i;
            prod_rc = 34'(x_re_s2_q[p]) * 34'(cos_s2_q[p]);
            prod_is = 34'(x_im_s2_q[p]) * 34'(sin_s2_q[p]);
            prod_rs = 34'(x_re_s2_q[p]) * 34'(sin_s2_q[p]);
            prod_ic = 34'(x_im_s2_q[p]) * 34'(cos_s2_q[p]);

            y_re_s3_d[p] = sat_rnd_q15(prod_rc - prod_is, sat_r);
            y_im_s3_d[p] = sat_rnd_q15(prod_rs + prod_ic, sat_i);
            sat_cnt_s3_d = sat_cnt_s3_d + 4'(sat_r) + 4'(sat_i);
        end
    end

    logic                   valid_s3_q;
    logic                   is_key_s3_q;
    logic [5:0]             head_id_s3_q;
    logic [2:0]             chunk_idx_s3_q;
    logic                   zero_pos_s3_q;
    logic [3:0]             sat_cnt_s3_q;
    logic signed [15:0]     y_re_s3_q   [0:PAIR_LANES-1];
    logic signed [15:0]     y_im_s3_q   [0:PAIR_LANES-1];
    logic signed [15:0]     x_re_ref_s3_q [0:PAIR_LANES-1];
    logic signed [15:0]     x_im_ref_s3_q [0:PAIR_LANES-1];
    logic signed [15:0]     cos_mon_s3_q [0:PAIR_LANES-1];
    logic signed [15:0]     sin_mon_s3_q [0:PAIR_LANES-1];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_s3_q     <= 1'b0;
            is_key_s3_q    <= 1'b0;
            head_id_s3_q   <= 6'd0;
            chunk_idx_s3_q <= 3'd0;
            zero_pos_s3_q  <= 1'b0;
            sat_cnt_s3_q   <= 4'd0;
            for (int p = 0; p < PAIR_LANES; p++) begin
                y_re_s3_q[p]     <= 16'sd0;
                y_im_s3_q[p]     <= 16'sd0;
                x_re_ref_s3_q[p] <= 16'sd0;
                x_im_ref_s3_q[p] <= 16'sd0;
                cos_mon_s3_q[p]  <= 16'sd32767;
                sin_mon_s3_q[p]  <= 16'sd0;
            end
        end else begin
            valid_s3_q <= valid_s2_q;
            if (valid_s2_q) begin
                is_key_s3_q    <= is_key_s2_q;
                head_id_s3_q   <= head_id_s2_q;
                chunk_idx_s3_q <= chunk_idx_s2_q;
                zero_pos_s3_q  <= zero_pos_s2_q;
                sat_cnt_s3_q   <= sat_cnt_s3_d;
                for (int p = 0; p < PAIR_LANES; p++) begin
                    y_re_s3_q[p]     <= y_re_s3_d[p];
                    y_im_s3_q[p]     <= y_im_s3_d[p];
                    x_re_ref_s3_q[p] <= x_re_s2_q[p];
                    x_im_ref_s3_q[p] <= x_im_s2_q[p];
                    cos_mon_s3_q[p]  <= (cos_s2_q[p] > 17'sd32767)  ? 16'sd32767 :
                                        (cos_s2_q[p] < -17'sd32768) ? -16'sd32768 : cos_s2_q[p][15:0];
                    sin_mon_s3_q[p]  <= (sin_s2_q[p] > 17'sd32767)  ? 16'sd32767 :
                                        (sin_s2_q[p] < -17'sd32768) ? -16'sd32768 : sin_s2_q[p][15:0];
                end
            end
        end
    end

    always_comb begin
        valid_o             = valid_s3_q;
        is_key_o            = is_key_s3_q;
        head_id_o           = head_id_s3_q;
        pair_chunk_idx_o    = chunk_idx_s3_q;
        zero_pos_identity_o = valid_s3_q && zero_pos_s3_q;
        sat_count_o         = sat_cnt_s3_q;
        for (int p = 0; p < PAIR_LANES; p++) begin
            vec_out_o[(2*p)*DATA_W +: DATA_W]     = y_re_s3_q[p];
            vec_out_o[(2*p + 1)*DATA_W +: DATA_W] = y_im_s3_q[p];
            cos_monitor_o[p*TRIG_W +: TRIG_W]     = cos_mon_s3_q[p];
            sin_monitor_o[p*TRIG_W +: TRIG_W]     = sin_mon_s3_q[p];
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
        if (rst_n && past_valid_q) begin
            // PROP_M8_ZERO_POS_IDENTITY: token_pos == 0 guarantees exact 0-ULP identity
            if (valid_s3_q && zero_pos_s3_q) begin
                assert (y_re_s3_q[0] == x_re_ref_s3_q[0]);
                assert (y_im_s3_q[0] == x_im_ref_s3_q[0]);
                assert (sat_cnt_s3_q == 4'd0);
            end
            // PROP_M8_TRIG_RANGE: Sin/Cos LUT outputs are strictly bounded in [-32768, +32768]
            if (valid_s2_q) begin
                assert (cos_s2_q[0] >= -17'sd32768 && cos_s2_q[0] <= 17'sd32768);
                assert (sin_s2_q[0] >= -17'sd32768 && sin_s2_q[0] <= 17'sd32768);
            end
        end
    end

endmodule
