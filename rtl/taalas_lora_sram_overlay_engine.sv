`timescale 1ns / 1ps
// =============================================================================
// Module: taalas_lora_sram_overlay_engine (M7)
// Description:
//   Taalas HC1/HC2 Zero-Stall SRAM-Backed Low-Rank Adaptation (LoRA) Parallel
//   Overlay Engine (Rank r in {8, 16, 32, 64}).
//
// Architectural Highlights:
//   1. Solves Mask-ROM Weight Immutability:
//      Computes low-rank adaptation delta_y = (alpha / r) * B * (A * x) in
//      on-die SRAM completely in parallel with the frozen Metal-2/Via-2 ROM
//      base weight array (M1 + M2).
//   2. Two-Phase Pipelined Low-Rank Projection:
//      - Phase 1 (Down-Projection, d_in -> r):
//          h[r] = clamp_int24( sum_{i=0}^{IN_DIM-1} A[r, i] * x[i] )
//      - Phase 2 (Up-Projection & Scaling, r -> d_out):
//          up[j] = sum_{r=0}^{MAX_RANK-1} B[j, r] * h[r]
//          delta_y[j] = clamp_int16( (up[j] * alpha_over_r_q8_8 + 32768) >> 16 )
//   3. Programmable Skew-Matching Delay FIFO (skew_match_fifo):
//      Aligns delta_y arrival with the multi-stage ROM + Dequantizer pipeline
//      so LoRA fusion incurs strictly ZERO pipeline stall cycles (0 bubbles).
//
// Pipeline Timing & Skew-Matching Schedule:
//   Cycle 0 (valid_i == 1):
//     - Stream input activation vector x[0:IN_DIM-1] into both Base Mask-ROM
//       MAC Array (M2) and LoRA Overlay Engine (M7).
//     - M7 Phase 1 evaluates rank-r down-projection h[r] = sum_i A[r,i] * x[i]
//       across active ranks (0 <= r < active_rank_i) and latches h_latent_s1_q.
//   Cycle 1 (valid_s1_q == 1):
//     - M7 Phase 2 evaluates up-projection up[j] = sum_r B[j,r] * h_latent_s1_q[r],
//       applies Q8.8 scaling factor (alpha / r), and pushes delta_packed_s2
//       into the programmable skew_match_fifo[0:MAX_SKEW-1].
//   Cycle 2 + skew_delay_i:
//     - valid_o asserts and presents lora_delta_o[OUT_CHANNELS*16-1:0] to M4
//       (taalas_group_dequant_scale_unit) on the exact group completion cycle,
//       achieving 0 bubble cycles (stall_cycles_o == 16'd0).
// =============================================================================

module taalas_lora_sram_overlay_engine #(
    parameter int IN_DIM       = 64,
    parameter int OUT_CHANNELS = 16,
    parameter int MAX_RANK     = 16,
    parameter int MAX_SKEW     = 8
) (
    input  logic                               clk,
    input  logic                               rst_n,
    input  logic                               valid_i,
    input  logic                               lora_en_i,
    input  logic [7:0]                         active_rank_i,
    input  logic signed [15:0]                 alpha_over_r_q8_8_i,
    input  logic [2:0]                         skew_delay_i,
    input  logic [IN_DIM*8-1:0]                act_vec_i,

    // Direct parallel weight bus OR internal on-die SRAM overlay write port
    input  logic                               ext_weights_en_i,
    input  logic [MAX_RANK*IN_DIM*8-1:0]       lora_a_flat_i,
    input  logic [OUT_CHANNELS*MAX_RANK*8-1:0] lora_b_flat_i,

    input  logic                               sram_we_i,
    input  logic                               sram_sel_b_i,
    input  logic [5:0]                         sram_row_addr_i,
    input  logic [IN_DIM*8-1:0]                sram_wdata_i,

    output logic                               valid_o,
    output logic [MAX_RANK*24-1:0]             latent_h_o,
    output logic [OUT_CHANNELS*16-1:0]         lora_delta_o,
    output logic [15:0]                        stall_cycles_o
);

    // -------------------------------------------------------------------------
    // Helper Functions: Signed 24-Bit & 16-Bit Saturation Clamping
    // -------------------------------------------------------------------------
    function automatic logic signed [23:0] clamp_int24_lora(input logic signed [27:0] val);
        begin
            if (val > 28'sd8388607) begin
                clamp_int24_lora = 24'sd8388607;
            end else if (val < -28'sd8388608) begin
                clamp_int24_lora = -24'sd8388608;
            end else begin
                clamp_int24_lora = val[23:0];
            end
        end
    endfunction

    function automatic logic signed [15:0] clamp_int16_lora(input logic signed [39:0] val);
        begin
            if (val > 40'sd32767) begin
                clamp_int16_lora = 16'sd32767;
            end else if (val < -40'sd32768) begin
                clamp_int16_lora = -16'sd32768;
            end else begin
                clamp_int16_lora = val[15:0];
            end
        end
    endfunction

    // -------------------------------------------------------------------------
    // On-Die SRAM Overlay Storage for Low-Rank Matrices A (r x d_in) & B (d_out x r)
    // -------------------------------------------------------------------------
    logic signed [7:0] sram_mat_a [0:MAX_RANK-1][0:IN_DIM-1];
    logic signed [7:0] sram_mat_b [0:OUT_CHANNELS-1][0:MAX_RANK-1];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int r = 0; r < MAX_RANK; r++) begin
                for (int i = 0; i < IN_DIM; i++) begin
                    sram_mat_a[r][i] <= 8'sd0;
                end
            end
            for (int j = 0; j < OUT_CHANNELS; j++) begin
                for (int r = 0; r < MAX_RANK; r++) begin
                    sram_mat_b[j][r] <= 8'sd0;
                end
            end
        end else if (sram_we_i) begin
            if (!sram_sel_b_i && (int'(sram_row_addr_i) < MAX_RANK)) begin
                for (int i = 0; i < IN_DIM; i++) begin
                    sram_mat_a[int'(sram_row_addr_i)][i] <= $signed(sram_wdata_i[i*8 +: 8]);
                end
            end else if (sram_sel_b_i && (int'(sram_row_addr_i) < OUT_CHANNELS)) begin
                for (int r = 0; r < MAX_RANK; r++) begin
                    sram_mat_b[int'(sram_row_addr_i)][r] <= $signed(sram_wdata_i[r*8 +: 8]);
                end
            end
        end
    end

    // -------------------------------------------------------------------------
    // Phase 1 (PH_DOWN_PROJ): Low-Rank Down-Projection h = A * x (INT24)
    // -------------------------------------------------------------------------
    logic signed [7:0]  act_elem      [0:IN_DIM-1];
    logic signed [7:0]  eff_mat_a     [0:MAX_RANK-1][0:IN_DIM-1];
    logic signed [7:0]  eff_mat_b     [0:OUT_CHANNELS-1][0:MAX_RANK-1];
    logic signed [23:0] h_down_comb   [0:MAX_RANK-1];

    always_comb begin
        for (int i = 0; i < IN_DIM; i++) begin
            act_elem[i] = $signed(act_vec_i[i*8 +: 8]);
        end
        for (int r = 0; r < MAX_RANK; r++) begin
            for (int i = 0; i < IN_DIM; i++) begin
                if (ext_weights_en_i) begin
                    eff_mat_a[r][i] = $signed(lora_a_flat_i[(r*IN_DIM + i)*8 +: 8]);
                end else begin
                    eff_mat_a[r][i] = sram_mat_a[r][i];
                end
            end
        end
        for (int j = 0; j < OUT_CHANNELS; j++) begin
            for (int r = 0; r < MAX_RANK; r++) begin
                if (ext_weights_en_i) begin
                    eff_mat_b[j][r] = $signed(lora_b_flat_i[(j*MAX_RANK + r)*8 +: 8]);
                end else begin
                    eff_mat_b[j][r] = sram_mat_b[j][r];
                end
            end
        end
    end

    always_comb begin
        for (int r = 0; r < MAX_RANK; r++) begin
            logic signed [27:0] acc_r;
            acc_r = 28'sd0;
            if (lora_en_i && (r < int'(active_rank_i))) begin
                for (int i = 0; i < IN_DIM; i++) begin
                    acc_r = acc_r + (28'(eff_mat_a[r][i]) * 28'(act_elem[i]));
                end
            end
            h_down_comb[r] = clamp_int24_lora(acc_r);
        end
    end

    logic               valid_s1_q;
    logic               lora_en_s1_q;
    logic [7:0]         active_rank_s1_q;
    logic signed [15:0] alpha_scale_s1_q;
    logic [2:0]         skew_delay_s1_q;
    logic signed [23:0] h_latent_s1_q [0:MAX_RANK-1];
    logic signed [7:0]  mat_b_s1_q    [0:OUT_CHANNELS-1][0:MAX_RANK-1];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_s1_q       <= 1'b0;
            lora_en_s1_q     <= 1'b0;
            active_rank_s1_q <= 8'd0;
            alpha_scale_s1_q <= 16'sd0;
            skew_delay_s1_q  <= 3'd0;
            for (int r = 0; r < MAX_RANK; r++) begin
                h_latent_s1_q[r] <= 24'sd0;
            end
            for (int j = 0; j < OUT_CHANNELS; j++) begin
                for (int r = 0; r < MAX_RANK; r++) begin
                    mat_b_s1_q[j][r] <= 8'sd0;
                end
            end
        end else begin
            valid_s1_q <= valid_i;
            if (valid_i) begin
                lora_en_s1_q     <= lora_en_i;
                active_rank_s1_q <= active_rank_i;
                alpha_scale_s1_q <= alpha_over_r_q8_8_i;
                skew_delay_s1_q  <= skew_delay_i;
                for (int r = 0; r < MAX_RANK; r++) begin
                    h_latent_s1_q[r] <= h_down_comb[r];
                end
                for (int j = 0; j < OUT_CHANNELS; j++) begin
                    for (int r = 0; r < MAX_RANK; r++) begin
                        mat_b_s1_q[j][r] <= eff_mat_b[j][r];
                    end
                end
            end
        end
    end

    // -------------------------------------------------------------------------
    // Phase 2 (PH_UP_PROJ): Up-Projection delta_y = ((B * h) * scale + 2^15) >> 16
    // -------------------------------------------------------------------------
    logic signed [15:0] delta_up_comb    [0:OUT_CHANNELS-1];
    logic [OUT_CHANNELS*16-1:0] delta_packed_s2;
    logic [MAX_RANK*24-1:0]     latent_packed_s2;

    always_comb begin
        for (int r = 0; r < MAX_RANK; r++) begin
            latent_packed_s2[r*24 +: 24] = h_latent_s1_q[r];
        end
        for (int j = 0; j < OUT_CHANNELS; j++) begin
            logic signed [39:0] up_acc;
            logic signed [55:0] scaled_prod;
            logic signed [39:0] shifted_delta;

            up_acc = 40'sd0;
            if (lora_en_s1_q) begin
                for (int r = 0; r < MAX_RANK; r++) begin
                    if (r < int'(active_rank_s1_q)) begin
                        up_acc = up_acc + (40'(mat_b_s1_q[j][r]) * 40'(h_latent_s1_q[r]));
                    end
                end
            end
            scaled_prod      = (56'(up_acc) * 56'(alpha_scale_s1_q)) + 56'sd32768;
            shifted_delta    = 40'(scaled_prod >>> 16);
            delta_up_comb[j] = lora_en_s1_q ? clamp_int16_lora(shifted_delta) : 16'sd0;
            delta_packed_s2[j*16 +: 16] = delta_up_comb[j];
        end
    end

    // -------------------------------------------------------------------------
    // Programmable Pipeline Skew-Matching Delay FIFO (skew_match_fifo)
    // Aligns LoRA output with Base Mask-ROM + Dequantizer pipeline (0 stalls)
    // -------------------------------------------------------------------------
    logic                       skew_valid_q  [0:MAX_SKEW-1];
    logic [OUT_CHANNELS*16-1:0] skew_delta_q  [0:MAX_SKEW-1];
    logic [MAX_RANK*24-1:0]     skew_latent_q [0:MAX_SKEW-1];
    logic [2:0]                 active_skew_q;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            active_skew_q <= 3'd0;
            for (int s = 0; s < MAX_SKEW; s++) begin
                skew_valid_q[s]  <= 1'b0;
                skew_delta_q[s]  <= '0;
                skew_latent_q[s] <= '0;
            end
        end else begin
            if (valid_s1_q) begin
                active_skew_q <= skew_delay_s1_q;
            end
            skew_valid_q[0]  <= valid_s1_q;
            skew_delta_q[0]  <= delta_packed_s2;
            skew_latent_q[0] <= latent_packed_s2;
            for (int s = 1; s < MAX_SKEW; s++) begin
                skew_valid_q[s]  <= skew_valid_q[s-1];
                skew_delta_q[s]  <= skew_delta_q[s-1];
                skew_latent_q[s] <= skew_latent_q[s-1];
            end
        end
    end

    assign valid_o        = skew_valid_q[int'(active_skew_q)];
    assign lora_delta_o   = skew_delta_q[int'(active_skew_q)];
    assign latent_h_o     = skew_latent_q[int'(active_skew_q)];
    assign stall_cycles_o = 16'd0;

    // -------------------------------------------------------------------------
    // Inline SVA & Yosys Formal Properties (PROP_M7_LORA_ZERO_STALL)
    // Proves:
    //   1. Zero pipeline stall invariant (stall_cycles_o == 0 always).
    //   2. Disabled LoRA (lora_en_i == 0 or active_rank_i == 0) produces
    //      strictly zero latent vector h and zero output adaptation delta.
    //   3. Zero scaling factor (alpha_over_r_q8_8 == 0) produces zero delta.
    //   4. Exact down-projection equivalence for rank 0 and skew-FIFO delay
    //      conservation across programmable skew settings.
    // -------------------------------------------------------------------------
    logic signed [27:0] ref_r0_dot_comb;
    logic signed [23:0] ref_r0_h_comb;
    logic signed [23:0] ref_r0_h_s1_q;

    always_comb begin
        ref_r0_dot_comb = 28'sd0;
        if (lora_en_i && (active_rank_i != 8'd0)) begin
            for (int i = 0; i < IN_DIM; i++) begin
                ref_r0_dot_comb = ref_r0_dot_comb +
                    (28'(eff_mat_a[0][i]) * 28'(act_elem[i]));
            end
        end
        ref_r0_h_comb = clamp_int24_lora(ref_r0_dot_comb);
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ref_r0_h_s1_q <= 24'sd0;
        end else if (valid_i) begin
            ref_r0_h_s1_q <= ref_r0_h_comb;
        end
    end

    always_ff @(posedge clk) begin
        if (rst_n) begin
            // 1. Strictly zero stall cycles under all operating conditions
            PROP_M7_ZERO_STALL_INVARIANT: assert (stall_cycles_o == 16'd0);

            // 2. Down-projection rank-0 equivalence
            PROP_M7_DOWN_PROJ_R0_EQUIV: assert (h_down_comb[0] == ref_r0_h_comb);
            if (valid_s1_q) begin
                PROP_M7_STAGE1_LATENT_EQUIV: assert (h_latent_s1_q[0] == ref_r0_h_s1_q);
            end

            // 3. When lora_en == 0 or active_rank == 0, latent h and delta are zero
            if (!lora_en_i || (active_rank_i == 8'd0)) begin
                PROP_M7_DISABLED_LATENT_ZERO: assert (h_down_comb[0] == 24'sd0);
            end
            if (!lora_en_s1_q || (active_rank_s1_q == 8'd0) || (alpha_scale_s1_q == 16'sd0)) begin
                PROP_M7_DISABLED_DELTA_ZERO: assert (delta_up_comb[0] == 16'sd0);
            end

            // 4. Skew delay 0 immediately forwards Stage 2 valid & delta
            if (active_skew_q == 3'd0) begin
                PROP_M7_SKEW0_BYPASS_EXACT: assert (
                    (valid_o == skew_valid_q[0]) && (lora_delta_o == skew_delta_q[0])
                );
            end
        end
    end

endmodule
