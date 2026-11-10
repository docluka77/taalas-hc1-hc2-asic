`timescale 1ns / 1ps
// =============================================================================
// Module: baseline_fp16_int8_mac_array
// Description:
//   Conventional Baseline Multiplier-Based INT8xINT8 + FP16 Scale MAC Array
//   with Active Weight Buffer Registers (Iso-Throughput Baseline for Taalas
//   HC1 taalas_3b6b_wired_mac_array PPA Comparison).
//
// Architectural Contrast vs. Taalas 3b/6b Multiplierless CSD Wired MAC:
//   1. Full 8x8 Signed Booth Hardware Multipliers (VEC_LEN x OUT_CHANNELS)
//      instead of Taalas's Multiplierless 3-Bit CSD Shift-Add + 4x Outlier Path.
//   2. Active Flip-Flop / SRAM Weight Holding Registers (8 bits per weight)
//      to buffer weights fetched from conventional 6T SRAM macro, rather than
//      zero-area/zero-write wire-routed 1T Via-Mask ROM bitlines.
//   3. No Zero-Weight / Zero-Activation Operand Isolation before multipliers.
//   4. Identical 3-Stage Pipeline Latency (S1 Multiply -> S2 Tree -> S3 Final)
//      and identical VEC_LEN x OUT_CHANNELS throughput per clock cycle.
// =============================================================================

module baseline_fp16_int8_mac_array #(
    parameter int VEC_LEN      = 64,
    parameter int OUT_CHANNELS = 16
) (
    input  logic                           clk,
    input  logic                           rst_n,
    input  logic                           valid_i,
    input  logic                           weight_load_en_i,
    input  logic [VEC_LEN*8-1:0]           act_vec_i,
    input  logic [OUT_CHANNELS*VEC_LEN*8-1:0] w_sram_in_i,
    input  logic [OUT_CHANNELS*16-1:0]     w_scale_fp16_i,
    output logic                           valid_o,
    output logic [OUT_CHANNELS*24-1:0]     acc_out_o
);

    localparam int GROUPS_OF_8 = (VEC_LEN >= 8) ? (VEC_LEN / 8) : 1;

    // Active weight buffer register file (simulating local weight tile buffer
    // required by conventional SRAM-fed tensor cores)
    logic signed [7:0] w_buf_q [0:OUT_CHANNELS-1][0:VEC_LEN-1];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int c = 0; c < OUT_CHANNELS; c++) begin
                for (int k = 0; k < VEC_LEN; k++) begin
                    w_buf_q[c][k] <= 8'sd0;
                end
            end
        end else if (weight_load_en_i) begin
            for (int c = 0; c < OUT_CHANNELS; c++) begin
                for (int k = 0; k < VEC_LEN; k++) begin
                    w_buf_q[c][k] <= $signed(w_sram_in_i[(c*VEC_LEN + k)*8 +: 8]);
                end
            end
        end
    end

    // Stage 1: Conventional 8x8 Signed Booth Multipliers (No Operand Isolation)
    logic               s1_valid_q;
    logic signed [15:0] s1_prod_q  [0:OUT_CHANNELS-1][0:VEC_LEN-1];
    logic signed [15:0] s1_scale_q [0:OUT_CHANNELS-1];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s1_valid_q <= 1'b0;
            for (int c = 0; c < OUT_CHANNELS; c++) begin
                s1_scale_q[c] <= 16'sd0;
                for (int k = 0; k < VEC_LEN; k++) begin
                    s1_prod_q[c][k] <= 16'sd0;
                end
            end
        end else begin
            s1_valid_q <= valid_i;
            for (int c = 0; c < OUT_CHANNELS; c++) begin
                s1_scale_q[c] <= $signed(w_scale_fp16_i[c*16 +: 16]);
                for (int k = 0; k < VEC_LEN; k++) begin
                    logic signed [7:0] act_k;
                    act_k = $signed(act_vec_i[k*8 +: 8]);
                    s1_prod_q[c][k] <= act_k * w_buf_q[c][k];
                end
            end
        end
    end

    // Stage 2: First-Level Adder Tree Reduction (Groups of 8)
    logic               s2_valid_q;
    logic signed [19:0] s2_part_q  [0:OUT_CHANNELS-1][0:GROUPS_OF_8-1];
    logic signed [15:0] s2_scale_q [0:OUT_CHANNELS-1];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s2_valid_q <= 1'b0;
            for (int c = 0; c < OUT_CHANNELS; c++) begin
                s2_scale_q[c] <= 16'sd0;
                for (int g = 0; g < GROUPS_OF_8; g++) begin
                    s2_part_q[c][g] <= 20'sd0;
                end
            end
        end else begin
            s2_valid_q <= s1_valid_q;
            for (int c = 0; c < OUT_CHANNELS; c++) begin
                s2_scale_q[c] <= s1_scale_q[c];
                for (int g = 0; g < GROUPS_OF_8; g++) begin
                    logic signed [19:0] g_sum;
                    g_sum = 20'sd0;
                    for (int j = 0; j < 8; j++) begin
                        if (g*8 + j < VEC_LEN)
                            g_sum = g_sum + 20'(s1_prod_q[c][g*8 + j]);
                    end
                    s2_part_q[c][g] <= g_sum;
                end
            end
        end
    end

    // Stage 3: Final Reduction & Group Scale Multiplication
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_o   <= 1'b0;
            acc_out_o <= '0;
        end else begin
            valid_o <= s2_valid_q;
            for (int c = 0; c < OUT_CHANNELS; c++) begin
                logic signed [23:0] ch_sum;
                logic signed [39:0] scaled_prod;
                ch_sum = 24'sd0;
                for (int g = 0; g < GROUPS_OF_8; g++) begin
                    ch_sum = ch_sum + 24'(s2_part_q[c][g]);
                end
                scaled_prod = ch_sum * s2_scale_q[c];
                acc_out_o[c*24 +: 24] <= scaled_prod[31:8];
            end
        end
    end

endmodule
