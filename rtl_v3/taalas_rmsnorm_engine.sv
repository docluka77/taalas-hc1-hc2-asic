`timescale 1ns / 1ps
/* verilator lint_off UNUSED */
// =============================================================================
// Module:      taalas_rmsnorm_engine (M10 - Stage 12 rtl_v3 Optimized)
// Project:     Taalas HC1/HC2 Hardwired LLM Inference ASIC
// Description: Streaming Variance Accumulator + Retimed Fast Inverse Square-Root
//              (CLZ Even-Exponent Halving + Mantissa LUT + Shared 2-Step
//              Newton-Raphson y_{n+1} = 0.5 * y_n * (3 - x * y_n^2)) +
//              Hardwired Mask-ROM Gamma Scaling Unit.
//
// Stage 12 PPA & Timing Closure Optimizations (rtl_v3):
//   1. Retimed normalize_var_even_exp into RMS_MEAN_EPS so RMS_NR_ITER1 and
//      RMS_NR_ITER2 share a SINGLE hardware Newton-Raphson unit directly fed by
//      registered m_norm_q14_q and r_iter_q14_q flip-flops (eliminating 100% of
//      the duplicate NR multiplier chain and breaking the CLZ+LUT+NR path).
//   2. Added dynamic operand isolation on the VEC_W input squarers (active only
//      in RMS_IDLE/RMS_ACCUM_SQ when in_valid_i is asserted) and on the VEC_W
//      output gamma/inv_rms scaling multipliers (active only in RMS_SCALE_OUT).
// =============================================================================

module taalas_rmsnorm_engine #(
    parameter int HIDDEN_DIM  = 64,
    parameter int VEC_W       = 16,
    parameter int DATA_W      = 16,
    parameter int EPS_DEFAULT = 4
) (
    input  logic                            clk,
    input  logic                            rst_n,

    // Control & Streaming Activation Input (16 x Q8.8 elements per cycle)
    input  logic                            start_i,
    input  logic                            in_valid_i,
    input  logic [VEC_W*DATA_W-1:0]         x_vec_i,
    input  logic [15:0]                     eps_q16_i,

    // Optional External / Mask-ROM Gamma Override (16 x Q8.8 elements)
    input  logic                            ext_gamma_en_i,
    input  logic [VEC_W*DATA_W-1:0]         gamma_vec_i,

    // Streaming Normalized Output & Status Telemetry
    output logic                            busy_o,
    output logic                            out_valid_o,
    output logic                            out_last_o,
    output logic                            done_o,
    output logic [VEC_W*DATA_W-1:0]         y_vec_o,
    output logic [31:0]                     var_eps_o,
    output logic [15:0]                     inv_rms_q8_8_o,
    output logic [2:0]                      fsm_state_o
);

    localparam int N_CHUNKS = (HIDDEN_DIM / VEC_W > 0) ? (HIDDEN_DIM / VEC_W) : 1;
    localparam int CHUNK_W  = (N_CHUNKS > 1) ? $clog2(N_CHUNKS) : 1;
    localparam int LOG2_DIM = $clog2(HIDDEN_DIM);

    typedef enum logic [2:0] {
        RMS_IDLE      = 3'b000,
        RMS_ACCUM_SQ  = 3'b001,
        RMS_MEAN_EPS  = 3'b010,
        RMS_NR_ITER1  = 3'b011,
        RMS_NR_ITER2  = 3'b100,
        RMS_SCALE_OUT = 3'b101,
        RMS_DONE      = 3'b110
    } rms_state_e;

    rms_state_e state_q, state_d;

    // -------------------------------------------------------------------------
    // Helper 1: 16-Entry Mantissa LUT for rsqrt(m) where m in [0.5, 2.0)
    // -------------------------------------------------------------------------
    function automatic logic [15:0] rsqrt_seed_lut_q14(
        input logic       is_ge_one,
        input logic [2:0] sub_idx
    );
        begin
            unique case ({is_ge_one, sub_idx})
                4'b0_000: rsqrt_seed_lut_q14 = 16'd22486;
                4'b0_001: rsqrt_seed_lut_q14 = 16'd21233;
                4'b0_010: rsqrt_seed_lut_q14 = 16'd20170;
                4'b0_011: rsqrt_seed_lut_q14 = 16'd19251;
                4'b0_100: rsqrt_seed_lut_q14 = 16'd18448;
                4'b0_101: rsqrt_seed_lut_q14 = 16'd17737;
                4'b0_110: rsqrt_seed_lut_q14 = 16'd17102;
                4'b0_111: rsqrt_seed_lut_q14 = 16'd16531;
                4'b1_000: rsqrt_seed_lut_q14 = 16'd15900;
                4'b1_001: rsqrt_seed_lut_q14 = 16'd15015;
                4'b1_010: rsqrt_seed_lut_q14 = 16'd14266;
                4'b1_011: rsqrt_seed_lut_q14 = 16'd13620;
                4'b1_100: rsqrt_seed_lut_q14 = 16'd13056;
                4'b1_101: rsqrt_seed_lut_q14 = 16'd12556;
                4'b1_110: rsqrt_seed_lut_q14 = 16'd12110;
                default:  rsqrt_seed_lut_q14 = 16'd11708;
            endcase
        end
    endfunction
    // -------------------------------------------------------------------------
    // Helper 2: Single Newton-Raphson Step in Q2.14 (16384 = 1.0)
    // r_{k+1} = 0.5 * r_k * (3.0 - m * r_k^2)
    // -------------------------------------------------------------------------
    function automatic logic [15:0] nr_rsqrt_step_q14(
        input logic [15:0] m_q14,
        input logic [15:0] r_q14
    );
        logic [31:0] r_sq_q28;
        logic [17:0] r_sq_q14;
        logic [33:0] mr2_q28;
        logic [17:0] mr2_q14;
        logic [17:0] three_minus_q14;
        logic [33:0] prod_q28;
        logic [17:0] r_next;
        begin
            r_sq_q28 = 32'(r_q14) * 32'(r_q14);
            r_sq_q14 = 18'((r_sq_q28 + 32'd8192) >> 14);
            mr2_q28  = 34'(m_q14) * 34'(r_sq_q14);
            mr2_q14  = 18'((mr2_q28 + 34'd8192) >> 14);
            if (mr2_q14 >= 18'd49152) begin
                three_minus_q14 = 18'd1;
            end else begin
                three_minus_q14 = 18'd49152 - mr2_q14;
            end
            prod_q28 = 34'(r_q14) * 34'(three_minus_q14);
            r_next   = 18'((prod_q28 + 34'd16384) >> 15);
            nr_rsqrt_step_q14 = (r_next > 18'd65535) ? 16'd65535 : r_next[15:0];
        end
    endfunction

    // -------------------------------------------------------------------------
    // Helper 3: Even-Exponent Normalization of var_eps (Q16.16)
    // -------------------------------------------------------------------------
    function automatic logic [37:0] normalize_var_even_exp(input logic [31:0] var_q16);
        int                msb_pos;
        int                unbiased_exp;
        int                half_k;
        int                target_shift;
        logic [47:0]       wide_var;
        logic [15:0]       m_q14;
        logic [15:0]       r0_q14;
        logic signed [5:0] k_signed;
        begin
            msb_pos = 0;
            for (int b = 0; b < 32; b++) begin
                if (var_q16[b]) begin
                    msb_pos = b;
                end
            end
            unbiased_exp = msb_pos - 16;
            if ((unbiased_exp + 1) >= 0) begin
                half_k = (unbiased_exp + 1) / 2;
            end else begin
                half_k = -((-(unbiased_exp + 1) + 1) / 2);
            end
            target_shift = 2 + (2 * half_k);
            wide_var     = {16'd0, var_q16};
            if (target_shift >= 0) begin
                m_q14 = 16'(wide_var >> target_shift);
            end else begin
                m_q14 = 16'(wide_var << (-target_shift));
            end
            if (m_q14 < 16'd8192)  m_q14 = 16'd8192;
            if (m_q14 > 16'd32767) m_q14 = 16'd32767;
            // [STAGE-10 FIX BUG-HC1-002]: Index lower octave [0.5, 1.0) with m_q14[12:10]
            r0_q14   = rsqrt_seed_lut_q14(m_q14[14], m_q14[14] ? m_q14[13:11] : m_q14[12:10]);
            k_signed = 6'(half_k);
            normalize_var_even_exp = {k_signed, m_q14, r0_q14};
        end
    endfunction

    // -------------------------------------------------------------------------
    // Internal Replay Buffer & Datapath State Registers
    // -------------------------------------------------------------------------
    logic [VEC_W*DATA_W-1:0] replay_ram_q [0:N_CHUNKS-1];
    logic [CHUNK_W-1:0]      wr_chunk_q;
    logic [CHUNK_W-1:0]      rd_chunk_q;
    logic [47:0]             sum_sq_q;
    logic [31:0]             var_eps_q;
    logic [15:0]             m_norm_q14_q;
    logic [15:0]             r_iter_q14_q;
    logic signed [5:0]       half_exp_k_q;
    logic [15:0]             inv_rms_q8_8_q;
    logic                    out_valid_q;
    logic                    out_last_q;
    logic [VEC_W*DATA_W-1:0] y_vec_q;

    // -------------------------------------------------------------------------
    // Helper 4: Hardwired Via-Mask Gamma ROM (Default 1.0 = 16'h0100 in Q8.8)
    // -------------------------------------------------------------------------
    function automatic logic signed [15:0] rom_gamma_q8_8(
        input logic [CHUNK_W-1:0] chunk_id,
        input logic [3:0]         lane_id
    );
        logic [3:0] mod_pat;
        begin
            mod_pat = 4'(chunk_id) ^ lane_id;
            rom_gamma_q8_8 = 16'sd256 + $signed({12'd0, mod_pat}) - 16'sd8;
        end
    endfunction
    // Combinational Chunk Sum-of-Squares & Scaled Output Vector
    logic [47:0]             chunk_sq_sum_comb;
    logic [31:0]             eff_eps_q16_comb;
    logic [31:0]             calc_var_eps_comb;
    logic [37:0]             norm_pack_comb;
    logic [15:0]             r_nr_step_comb;
    logic [15:0]             inv_rms_final_comb;
    logic [VEC_W*DATA_W-1:0] scaled_y_comb;

    always_comb begin
        logic sq_iso_en;
        logic scale_iso_en;
        sq_iso_en          = in_valid_i && ((state_q == RMS_IDLE && start_i) || (state_q == RMS_ACCUM_SQ));
        scale_iso_en       = (state_q == RMS_SCALE_OUT);
        chunk_sq_sum_comb  = 48'd0;
        for (int i = 0; i < VEC_W; i++) begin
            logic signed [15:0] xi;
            logic signed [31:0] xi_sq;
            xi    = sq_iso_en ? $signed(x_vec_i[i*DATA_W +: DATA_W]) : 16'sd0;
            xi_sq = 32'(xi) * 32'(xi);
            chunk_sq_sum_comb = chunk_sq_sum_comb + 48'($unsigned(xi_sq));
        end

        // Strictly positive epsilon floor guarantees zero divide-by-zero hazard
        eff_eps_q16_comb = (eps_q16_i == 16'd0) ? 32'(EPS_DEFAULT) : {16'd0, eps_q16_i};
        if (eff_eps_q16_comb == 32'd0) begin
            eff_eps_q16_comb = 32'd1;
        end
        begin
            logic [32:0] raw_var_sum;
            raw_var_sum = 33'(sum_sq_q >> LOG2_DIM) + 33'(eff_eps_q16_comb);
            if (raw_var_sum > 33'hFFFF_FFFF) begin
                calc_var_eps_comb = 32'hFFFF_FFFF;
            end else if (raw_var_sum == 33'd0) begin
                calc_var_eps_comb = 32'd1;
            end else begin
                calc_var_eps_comb = raw_var_sum[31:0];
            end
        end

        // Retimed into RMS_MEAN_EPS + Single Shared NR Hardware Step across ITER1 & ITER2
        norm_pack_comb = normalize_var_even_exp(calc_var_eps_comb);
        r_nr_step_comb = nr_rsqrt_step_q14(m_norm_q14_q, r_iter_q14_q);

        // Convert r_nr_step_comb (Q2.14) * 2^(-half_exp_k_q) -> Q8.8 (shift right by 6 + half_exp_k_q)
        begin
            int total_rshift;
            logic [31:0] wide_r2;
            logic [31:0] shifted_inv;
            total_rshift = 6 + int'(half_exp_k_q);
            wide_r2      = {16'd0, r_nr_step_comb};
            if (total_rshift >= 0) begin
                shifted_inv = wide_r2 >> total_rshift;
            end else begin
                shifted_inv = wide_r2 << (-total_rshift);
            end
            if (shifted_inv > 32'd65535) begin
                inv_rms_final_comb = 16'd65535;
            end else if (shifted_inv == 32'd0) begin
                inv_rms_final_comb = 16'd1;
            end else begin
                inv_rms_final_comb = shifted_inv[15:0];
            end
        end

        // Operand-Isolated Scale replay vector by inv_rms_q8_8_q and gamma_i (Q8.8)
        for (int i = 0; i < VEC_W; i++) begin
            logic signed [15:0] x_rep;
            logic signed [15:0] gam_i;
            logic signed [31:0] x_norm_q16;
            // [STAGE-28 FIX AUDIT-FINDING-010]: Widened x_norm_q8 to 24-bit signed & y_prod_q16 to 40-bit signed
            // so high-crest-factor outlier activations (> +32767 after inv_rms) never sign-wrap before gamma scaling!
            logic signed [23:0] x_norm_q8;
            logic signed [39:0] y_prod_q16;
            logic signed [31:0] y_shifted;
            x_rep      = scale_iso_en ? $signed(replay_ram_q[rd_chunk_q][i*DATA_W +: DATA_W]) : 16'sd0;
            gam_i      = ext_gamma_en_i ? $signed(gamma_vec_i[i*DATA_W +: DATA_W])
                                        : rom_gamma_q8_8(rd_chunk_q, 4'(i));
            x_norm_q16 = 32'(x_rep) * 32'($signed({1'b0, inv_rms_q8_8_q}));
            x_norm_q8  = 24'((x_norm_q16 + 32'sd128) >>> 8);
            y_prod_q16 = 40'(x_norm_q8) * 40'(gam_i);
            y_shifted  = 32'((y_prod_q16 + 40'sd128) >>> 8);
            if (y_shifted > 32'sd32767) begin
                scaled_y_comb[i*DATA_W +: DATA_W] = 16'sd32767;
            end else if (y_shifted < -32'sd32768) begin
                scaled_y_comb[i*DATA_W +: DATA_W] = -16'sd32768;
            end else begin
                scaled_y_comb[i*DATA_W +: DATA_W] = y_shifted[15:0];
            end
        end
    end
    // =========================================================================
    // 7-State FSM Next-State Logic
    // =========================================================================
    always_comb begin
        state_d = state_q;
        unique case (state_q)
            RMS_IDLE: begin
                if (start_i && in_valid_i) begin
                    state_d = (N_CHUNKS <= 1) ? RMS_MEAN_EPS : RMS_ACCUM_SQ;
                end
            end
            RMS_ACCUM_SQ: begin
                if (in_valid_i && (wr_chunk_q == CHUNK_W'(N_CHUNKS - 1))) begin
                    state_d = RMS_MEAN_EPS;
                end
            end
            RMS_MEAN_EPS:  state_d = RMS_NR_ITER1;
            RMS_NR_ITER1:  state_d = RMS_NR_ITER2;
            RMS_NR_ITER2:  state_d = RMS_SCALE_OUT;
            RMS_SCALE_OUT: begin
                if (rd_chunk_q == CHUNK_W'(N_CHUNKS - 1)) begin
                    state_d = RMS_DONE;
                end
            end
            RMS_DONE: begin
                if (start_i && in_valid_i) begin
                    state_d = (N_CHUNKS <= 1) ? RMS_MEAN_EPS : RMS_ACCUM_SQ;
                end else begin
                    state_d = RMS_IDLE;
                end
            end
            default:       state_d = RMS_IDLE;
        endcase
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_q        <= RMS_IDLE;
            wr_chunk_q     <= '0;
            rd_chunk_q     <= '0;
            sum_sq_q       <= 48'd0;
            var_eps_q      <= 32'd1;
            m_norm_q14_q   <= 16'd16384;
            r_iter_q14_q   <= 16'd16384;
            half_exp_k_q   <= 6'sd0;
            inv_rms_q8_8_q <= 16'd256;
            out_valid_q    <= 1'b0;
            out_last_q     <= 1'b0;
            y_vec_q        <= '0;
            for (int c = 0; c < N_CHUNKS; c++) begin
                replay_ram_q[c] <= '0;
            end
        end else begin
            state_q     <= state_d;
            out_valid_q <= 1'b0;
            out_last_q  <= 1'b0;

            unique case (state_q)
                RMS_IDLE: begin
                    if (start_i && in_valid_i) begin
                        replay_ram_q[0] <= x_vec_i;
                        sum_sq_q        <= chunk_sq_sum_comb;
                        wr_chunk_q      <= (N_CHUNKS > 1) ? CHUNK_W'(1) : '0;
                        rd_chunk_q      <= '0;
                    end
                end
                RMS_ACCUM_SQ: begin
                    if (in_valid_i) begin
                        replay_ram_q[wr_chunk_q] <= x_vec_i;
                        sum_sq_q                 <= sum_sq_q + chunk_sq_sum_comb;
                        if (wr_chunk_q < CHUNK_W'(N_CHUNKS - 1)) begin
                            wr_chunk_q <= wr_chunk_q + 1'b1;
                        end
                    end
                end
                RMS_MEAN_EPS: begin
                    var_eps_q    <= calc_var_eps_comb;
                    half_exp_k_q <= $signed(norm_pack_comb[37:32]);
                    m_norm_q14_q <= norm_pack_comb[31:16];
                    r_iter_q14_q <= norm_pack_comb[15:0];
                end
                RMS_NR_ITER1: begin
                    r_iter_q14_q <= r_nr_step_comb;
                end
                RMS_NR_ITER2: begin
                    r_iter_q14_q   <= r_nr_step_comb;
                    inv_rms_q8_8_q <= inv_rms_final_comb;
                    rd_chunk_q     <= '0;
                end
                RMS_SCALE_OUT: begin
                    out_valid_q <= 1'b1;
                    out_last_q  <= (rd_chunk_q == CHUNK_W'(N_CHUNKS - 1));
                    y_vec_q     <= scaled_y_comb;
                    if (rd_chunk_q < CHUNK_W'(N_CHUNKS - 1)) begin
                        rd_chunk_q <= rd_chunk_q + 1'b1;
                    end
                end
                default: ;
            endcase
        end
    end

    assign busy_o         = (state_q != RMS_IDLE);
    assign out_valid_o    = out_valid_q;
    assign out_last_o     = out_last_q;
    assign done_o         = (state_q == RMS_DONE);
    assign y_vec_o        = y_vec_q;
    assign var_eps_o      = var_eps_q;
    assign inv_rms_q8_8_o = inv_rms_q8_8_q;
    assign fsm_state_o    = state_q;

    // =========================================================================
    // Formal Verification & Inline SVA Invariants (Yosys SAT & Verilator)
    // =========================================================================
    logic past_valid_q;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) past_valid_q <= 1'b0;
        else        past_valid_q <= 1'b1;
    end

    always_comb begin
        if (rst_n && past_valid_q) begin
            assert (calc_var_eps_comb >= 32'd1);
            if (state_q == RMS_NR_ITER1 || state_q == RMS_NR_ITER2 || state_q == RMS_SCALE_OUT) begin
                assert (var_eps_q >= 32'd1);
            end
            if (state_q == RMS_NR_ITER1 || state_q == RMS_NR_ITER2 || state_q == RMS_SCALE_OUT) begin
                assert (m_norm_q14_q >= 16'd8192 && m_norm_q14_q <= 16'd32767);
            end
            if (state_q == RMS_SCALE_OUT || out_valid_q) begin
                assert (inv_rms_q8_8_q >= 16'd1);
            end
            if (norm_pack_comb[31:16] < 16'd12288) begin
                assert (norm_pack_comb[15:0] >= 16'd19251);
            end
        end
    end

endmodule
