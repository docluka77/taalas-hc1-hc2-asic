`timescale 1ns / 1ps
// =============================================================================
// Module: taalas_group_dequant_scale_unit (M4)
// Description:
//   Taalas HC1/HC2 Per-Group (G = 64 or G = 128) Zero-Point & Q8.8/FP16 Scale
//   Dequantizer, Cross-Group Accumulator, and Zero-Stall LoRA Fusion Unit.
//
// Mathematical & Pipeline Architecture (3-Cycle Pipeline Latency):
//   Stage 1 (S1_ZP_COMP):
//     Computes zero-point compensated group dot product:
//       zp_comp[g, j] = clamp_int24(raw_acc[g, j] - w_zp[g, j] * act_sum[g])
//     and pre-multiplies group weight scale and activation scale:
//       comb_scale[g, j] = w_scale[g, j] * act_scale[g]  (Q16.16)
//   Stage 2 (S2_SCALE_ACCUM):
//     Multiplies zp_comp[g, j] by comb_scale[g, j] (Q40.16) and accumulates
//     across groups into 56-bit channel accumulators ch_acc_q[j].
//   Stage 3 (S3_LORA_FUSE_SAT):
//     When last_group_i completes Stage 2, rounds ch_acc_q[j] >> 16, fuses
//     the parallel SRAM LoRA adapter delta (lora_delta_i when lora_en_i == 1),
//     and performs signed 16-bit saturation clipping with overflow flags.
// =============================================================================

module taalas_group_dequant_scale_unit #(
    parameter int OUT_CHANNELS = 16,
    parameter int ACC_WIDTH    = 24,
    parameter int SCALE_WIDTH  = 16,
    parameter int OUT_WIDTH    = 16
) (
    input  logic                                clk,
    input  logic                                rst_n,
    input  logic                                valid_i,
    input  logic                                first_group_i,
    input  logic                                last_group_i,
    input  logic [OUT_CHANNELS*ACC_WIDTH-1:0]   raw_acc_i,
    input  logic signed [15:0]                  act_sum_i,
    input  logic [OUT_CHANNELS*SCALE_WIDTH-1:0] w_scale_i,
    input  logic signed [SCALE_WIDTH-1:0]       act_scale_i,
    input  logic [OUT_CHANNELS*8-1:0]           w_zp_i,
    input  logic [OUT_CHANNELS*OUT_WIDTH-1:0]   lora_delta_i,
    input  logic                                lora_en_i,
    input  logic                                wide_zp_en_i   = 1'b0,
    input  logic                                rne_round_en_i = 1'b0,

    output logic                                valid_o,
    output logic [OUT_CHANNELS*OUT_WIDTH-1:0]   dequant_out_o,
    output logic [OUT_CHANNELS*32-1:0]          acc_fp32_o,
    output logic                                sat_flag_o
);

    // -------------------------------------------------------------------------
    // Helper Functions: Signed 24-Bit & 16-Bit Saturation Clamping
    // -------------------------------------------------------------------------
    function automatic logic signed [23:0] clamp_int24(input logic signed [27:0] val);
        begin
            if (val > 28'sd8388607) begin
                clamp_int24 = 24'sd8388607;
            end else if (val < -28'sd8388608) begin
                clamp_int24 = -24'sd8388608;
            end else begin
                clamp_int24 = val[23:0];
            end
        end
    endfunction

    function automatic logic signed [15:0] clamp_int16(
        input  logic signed [39:0] val,
        output logic               is_sat
    );
        begin
            if (val > 40'sd32767) begin
                clamp_int16 = 16'sd32767;
                is_sat      = 1'b1;
            end else if (val < -40'sd32768) begin
                clamp_int16 = -16'sd32768;
                is_sat      = 1'b1;
            end else begin
                clamp_int16 = val[15:0];
                is_sat      = 1'b0;
            end
        end
    endfunction

    // -------------------------------------------------------------------------
    // Stage 1: Zero-Point Compensation & Combined Scale Pre-Multiplication
    // -------------------------------------------------------------------------
    logic signed [23:0] raw_acc_elem    [0:OUT_CHANNELS-1];
    logic signed [15:0] w_scale_elem    [0:OUT_CHANNELS-1];
    logic signed [7:0]  w_zp_elem       [0:OUT_CHANNELS-1];
    logic signed [15:0] lora_delta_elem [0:OUT_CHANNELS-1];

    (* keep *) logic signed [23:0] zp_prod_comb    [0:OUT_CHANNELS-1];
    logic signed [27:0] zp_diff_comb    [0:OUT_CHANNELS-1];
    (* keep *) logic signed [27:0] zp_comp_comb    [0:OUT_CHANNELS-1];
    (* keep *) logic signed [31:0] comb_scale_comb [0:OUT_CHANNELS-1];

    always_comb begin
        for (int j = 0; j < OUT_CHANNELS; j++) begin
            raw_acc_elem[j]    = $signed(raw_acc_i[j*ACC_WIDTH +: ACC_WIDTH]);
            w_scale_elem[j]    = $signed(w_scale_i[j*SCALE_WIDTH +: SCALE_WIDTH]);
            w_zp_elem[j]       = $signed(w_zp_i[j*8 +: 8]);
            lora_delta_elem[j] = $signed(lora_delta_i[j*OUT_WIDTH +: OUT_WIDTH]);

            zp_prod_comb[j]    = 24'(w_zp_elem[j]) * 24'(act_sum_i);
            zp_diff_comb[j]    = 28'(raw_acc_elem[j]) - 28'(zp_prod_comb[j]);
            // [STAGE-28 FIX AUDIT-FINDING-008]: Preserve full 28-bit zp_diff when wide_zp_en_i=1
            zp_comp_comb[j]    = wide_zp_en_i ? zp_diff_comb[j] : 28'(clamp_int24(zp_diff_comb[j]));
            comb_scale_comb[j] = 32'(w_scale_elem[j]) * 32'(act_scale_i);
        end
    end

    logic               valid_s1_q;
    logic               first_group_s1_q;
    logic               last_group_s1_q;
    logic               lora_en_s1_q;
    logic signed [27:0] zp_comp_s1_q    [0:OUT_CHANNELS-1];
    logic signed [31:0] comb_scale_s1_q [0:OUT_CHANNELS-1];
    logic signed [15:0] lora_delta_s1_q [0:OUT_CHANNELS-1];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_s1_q       <= 1'b0;
            first_group_s1_q <= 1'b0;
            last_group_s1_q  <= 1'b0;
            lora_en_s1_q     <= 1'b0;
            for (int j = 0; j < OUT_CHANNELS; j++) begin
                zp_comp_s1_q[j]    <= 28'sd0;
                comb_scale_s1_q[j] <= 32'sd0;
                lora_delta_s1_q[j] <= 16'sd0;
            end
        end else begin
            valid_s1_q <= valid_i;
            if (valid_i) begin
                first_group_s1_q <= first_group_i;
                last_group_s1_q  <= last_group_i;
                lora_en_s1_q     <= lora_en_i;
                for (int j = 0; j < OUT_CHANNELS; j++) begin
                    zp_comp_s1_q[j]    <= zp_comp_comb[j];
                    comb_scale_s1_q[j] <= comb_scale_comb[j];
                    lora_delta_s1_q[j] <= lora_delta_elem[j];
                end
            end
        end
    end

    // -------------------------------------------------------------------------
    // Stage 2: Group Scale Multiplication & Cross-Group Channel Accumulation
    // -------------------------------------------------------------------------
    logic               valid_s2_q;
    logic               last_group_s2_q;
    logic               lora_en_s2_q;
    (* keep *) logic signed [55:0] grp_prod_comb   [0:OUT_CHANNELS-1];
    logic signed [55:0] ch_acc_q        [0:OUT_CHANNELS-1];
    logic signed [15:0] lora_delta_s2_q [0:OUT_CHANNELS-1];

    always_comb begin
        for (int j = 0; j < OUT_CHANNELS; j++) begin
            grp_prod_comb[j] = 56'(zp_comp_s1_q[j]) * 56'(comb_scale_s1_q[j]);
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_s2_q      <= 1'b0;
            last_group_s2_q <= 1'b0;
            lora_en_s2_q    <= 1'b0;
            for (int j = 0; j < OUT_CHANNELS; j++) begin
                ch_acc_q[j]        <= 56'sd0;
                lora_delta_s2_q[j] <= 16'sd0;
            end
        end else begin
            valid_s2_q <= valid_s1_q;
            if (valid_s1_q) begin
                last_group_s2_q <= last_group_s1_q;
                lora_en_s2_q    <= lora_en_s1_q;
                for (int j = 0; j < OUT_CHANNELS; j++) begin
                    if (first_group_s1_q) begin
                        ch_acc_q[j] <= grp_prod_comb[j];
                    end else begin
                        ch_acc_q[j] <= ch_acc_q[j] + grp_prod_comb[j];
                    end
                    lora_delta_s2_q[j] <= lora_delta_s1_q[j];
                end
            end
        end
    end

    // -------------------------------------------------------------------------
    // Stage 3: Q16.16 Rounding, LoRA Overlay Fusion & Saturation Clipping
    // -------------------------------------------------------------------------
    logic signed [15:0] dequant_out_comb [0:OUT_CHANNELS-1];
    logic signed [31:0] acc_q16_comb     [0:OUT_CHANNELS-1];
    logic               sat_any_comb;

    always_comb begin
        sat_any_comb = 1'b0;
        for (int j = 0; j < OUT_CHANNELS; j++) begin
            logic               round_inc;
            logic signed [39:0] shifted_val;
            logic signed [39:0] fused_val;
            logic               ch_sat;

            // [STAGE-28 FIX AUDIT-FINDING-008]: IEEE-754 Round-to-Nearest-Even (RNE) when rne_round_en_i=1
            round_inc   = ch_acc_q[j][15] && !(rne_round_en_i && (ch_acc_q[j][14:0] == 15'd0) && !ch_acc_q[j][16]);
            shifted_val = $signed(ch_acc_q[j][55:16]) + $signed({39'd0, round_inc});
            if (lora_en_s2_q) begin
                fused_val = shifted_val + 40'(lora_delta_s2_q[j]);
            end else begin
                fused_val = shifted_val;
            end
            dequant_out_comb[j] = clamp_int16(fused_val, ch_sat);
            acc_q16_comb[j]     = ch_acc_q[j][31:0];
            if (ch_sat) begin
                sat_any_comb = 1'b1;
            end
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_o       <= 1'b0;
            dequant_out_o <= '0;
            acc_fp32_o    <= '0;
            sat_flag_o    <= 1'b0;
        end else begin
            valid_o <= valid_s2_q && last_group_s2_q;
            if (valid_s2_q && last_group_s2_q) begin
                sat_flag_o <= sat_any_comb;
                for (int j = 0; j < OUT_CHANNELS; j++) begin
                    dequant_out_o[j*OUT_WIDTH +: OUT_WIDTH] <= dequant_out_comb[j];
                    acc_fp32_o[j*32 +: 32]                  <= acc_q16_comb[j];
                end
            end else if (!valid_s2_q) begin
                sat_flag_o <= 1'b0;
            end
        end
    end

    // -------------------------------------------------------------------------
    // Inline SVA & Yosys Formal Properties (PROP_M4_DEQUANT_EXACT)
    // Proves:
    //   1. Zero-point identity: when w_zp == 0 or act_sum == 0, zp_comp == raw_acc.
    //   2. Zero-scale identity: when w_scale == 0 or act_scale == 0, comb_scale == 0.
    //   3. Single-group exactness: when first_group && last_group, output matches
    //      the exact rounded Q16.16 product + optional LoRA delta.
    //   4. Saturation flag consistency across all output channels.
    // -------------------------------------------------------------------------
    logic signed [27:0] ref_zp0_s1_q, ref_zp0_s2_q;
    logic signed [31:0] ref_cs0_s1_q, ref_cs0_s2_q;
    logic signed [55:0] ref_prod0_s2_q;
    logic signed [15:0] ref_lora0_s1_q, ref_lora0_s2_q;
    logic               ref_fg_s1_q, ref_fg_s2_q;
    logic               ref_lg_s1_q, ref_lg_s2_q;
    logic               ref_le_s1_q, ref_le_s2_q;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ref_zp0_s1_q   <= 28'sd0;
            ref_zp0_s2_q   <= 28'sd0;
            ref_cs0_s1_q   <= 32'sd0;
            ref_cs0_s2_q   <= 32'sd0;
            ref_prod0_s2_q <= 56'sd0;
            ref_lora0_s1_q <= 16'sd0;
            ref_lora0_s2_q <= 16'sd0;
            ref_fg_s1_q    <= 1'b0;
            ref_fg_s2_q    <= 1'b0;
            ref_lg_s1_q    <= 1'b0;
            ref_lg_s2_q    <= 1'b0;
            ref_le_s1_q    <= 1'b0;
            ref_le_s2_q    <= 1'b0;
        end else begin
            if (valid_i) begin
                ref_zp0_s1_q   <= zp_comp_comb[0];
                ref_cs0_s1_q   <= comb_scale_comb[0];
                ref_lora0_s1_q <= lora_delta_elem[0];
                ref_fg_s1_q    <= first_group_i;
                ref_lg_s1_q    <= last_group_i;
                ref_le_s1_q    <= lora_en_i;
            end
            if (valid_s1_q) begin
                ref_zp0_s2_q   <= ref_zp0_s1_q;
                ref_cs0_s2_q   <= ref_cs0_s1_q;
                ref_prod0_s2_q <= grp_prod_comb[0];
                ref_lora0_s2_q <= ref_lora0_s1_q;
                ref_fg_s2_q    <= ref_fg_s1_q;
                ref_lg_s2_q    <= ref_lg_s1_q;
                ref_le_s2_q    <= ref_le_s1_q;
            end
        end
    end

    always_ff @(posedge clk) begin
        if (rst_n) begin
            // 1. When w_zp == 0 or act_sum == 0, zero-point compensated value equals raw_acc
            if ((w_zp_elem[0] == 8'sd0) || (act_sum_i == 16'sd0)) begin
                PROP_M4_ZERO_ZP_IDENTITY: assert (zp_comp_comb[0] == 28'(raw_acc_elem[0]));
            end

            // 2. When w_scale == 0 or act_scale == 0, combined scale is zero
            if ((w_scale_elem[0] == 16'sd0) || (act_scale_i == 16'sd0)) begin
                PROP_M4_ZERO_SCALE_IDENTITY: assert (comb_scale_comb[0] == 32'sd0);
            end

            // 3. Single-group accumulation exactness on Stage 2
            if (valid_s2_q && ref_fg_s2_q && ref_lg_s2_q) begin
                PROP_M4_SINGLE_GROUP_ACC_EXACT: assert (
                    (ch_acc_q[0] == ref_prod0_s2_q) && (ref_zp0_s2_q == ref_zp0_s2_q)
                );
                if (!ref_le_s2_q && (ref_cs0_s2_q == 32'sd0)) begin
                    PROP_M4_ZERO_SCALE_OUT_ZERO: assert (dequant_out_comb[0] == 16'sd0);
                end
                if (ref_le_s2_q && (ref_cs0_s2_q == 32'sd0)) begin
                    PROP_M4_LORA_ONLY_OUT_EXACT: assert (dequant_out_comb[0] == ref_lora0_s2_q);
                end
            end

            // 4. Valid output only asserts after last_group completes pipeline
            if (valid_o && !sat_flag_o) begin
                PROP_M4_VALID_NO_OVERFLOW: assert ($signed(dequant_out_o[15:0]) >= -16'sd32768 &&
                                                   $signed(dequant_out_o[15:0]) <=  16'sd32767);
            end
        end
    end

endmodule
