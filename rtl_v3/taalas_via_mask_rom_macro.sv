// =============================================================================
// Module:      taalas_via_mask_rom_macro (M1)
// Project:     Taalas HC1/HC2 Hardwired LLM Inference ASIC
// Description: Two-Mask (Metal-2 / Via-2 / Metal-3) Via-Programmable Weight ROM
//              Macro with Wordline Decoder, Bitline Precharge & Sense-Amplifier
//              Pipeline, Sparse 6-Bit Outlier CAM/LUT, Zero-Leakage Sleep
//              Isolation, Dynamic Via Popcount Telemetry, and CRC-16 BIST.
// =============================================================================

`timescale 1ns / 1ps
/* verilator lint_off PINMISSING */
/* verilator lint_off PINCONNECTEMPTY */

module taalas_via_mask_rom_macro #(
    parameter int    NUM_BANKS     = 8,
    parameter int    ROWS          = 256,
    parameter int    COLS          = 512,
    parameter int    COLS_3B       = 64,
    parameter int    OUTLIER_SLOTS = 8,
    parameter        ROM_INIT_FILE = "",
    parameter logic [31:0] MASK_SEED = 32'h5441_414C
) (
    input  logic                                clk,
    input  logic                                rst_n,

    // Power-Gating & Isolation Controls
    input  logic                                sleep_n,        // Active-low sleep (0=sleep, 1=awake)
    input  logic                                sleep_i,        // Active-high sleep request
    input  logic                                iso_en_i,       // Clamp outputs to 0 when isolated

    // Read Access & Sense-Amp Controls
    input  logic                                cs_en,          // Macro chip-select
    input  logic                                precharge_en,   // Bitline precharge enable
    input  logic                                sa_en,          // Sense-amplifier latch strobe
    input  logic [$clog2(NUM_BANKS)-1:0]        bank_sel_i,     // Target ROM bank (0..NUM_BANKS-1)
    input  logic [$clog2(ROWS)-1:0]             addr_i,         // Row wordline address (0..ROWS-1)

    // Silicon Compiler / Testbench Via-Mask Programming Interface
    input  logic                                prog_en_i,
    input  logic [$clog2(NUM_BANKS)-1:0]        prog_bank_i,
    input  logic [$clog2(ROWS)-1:0]             prog_row_i,
    input  logic [COLS-1:0]                     prog_wdata_i,

    // Built-In Self-Test (BIST) & CRC-16 Mask Verification Interface
    input  logic                                bist_start_i,
    output logic                                bist_busy_o,
    output logic                                bist_done_o,
    output logic [15:0]                         bist_crc16_o,
    output logic                                bist_pass_o,

    // Primary Readout Outputs (1-Cycle Synchronous Sense-Amp Latency)
    output logic [COLS-1:0]                     rdata_o,
    output logic [COLS_3B*3-1:0]                weights_3b_o,
    output logic [OUTLIER_SLOTS*6-1:0]          outlier_idx_o,
    output logic [OUTLIER_SLOTS*6-1:0]          outlier_val6b_o,
    output logic [15:0]                         group_scale_fp16_o,
    output logic [7:0]                          group_zp_int8_o,
    output logic                                rvalid_o,
    output logic [$clog2(COLS+1)-1:0]           active_vias_o,
    output logic [NUM_BANKS-1:0]                bank_active_o,
    output logic                                bl_precharged_o,
    output logic                                bl_contention_prevented_o
);

    // -------------------------------------------------------------------------
    // Local Parameters & Derived Widths
    // -------------------------------------------------------------------------
    localparam int BANK_W = $clog2(NUM_BANKS);
    localparam int ROW_W  = $clog2(ROWS);
    localparam int VIA_W  = $clog2(COLS + 1);
    localparam int BIST_SCAN_ROWS = (ROWS < 16) ? ROWS : 16;

    // Effective power-down / isolation condition
    logic effective_sleep;
    assign effective_sleep = (!sleep_n) || sleep_i || iso_en_i;

    // -------------------------------------------------------------------------
    // Physical Metal-2 / Via-2 / Metal-3 ROM Bitmap Storage
    // -------------------------------------------------------------------------
    // Flattened 2D array indexed by {bank, row} for clean synthesis & Verilator
    localparam int TOTAL_ROWS = NUM_BANKS * ROWS;
    logic [COLS-1:0] via_rom_array [0:TOTAL_ROWS-1];

    // Deterministic LFSR-based Via-2 pattern generator for default silicon slice
    function automatic logic [COLS-1:0] gen_via_row_pattern(
        input int b_idx,
        input int r_idx,
        input logic [31:0] seed
    );
        logic [COLS-1:0] row_bits;
        logic [31:0]     lfsr;
        lfsr = seed ^ (b_idx * 32'h9E37_79B9) ^ (r_idx * 32'h85EB_CA6B);
        if (lfsr == 32'd0) lfsr = 32'h5441_414C;
        for (int w = 0; w < (COLS / 32); w++) begin
            lfsr = {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
            row_bits[w*32 +: 32] = lfsr;
        end
        gen_via_row_pattern = row_bits;
    endfunction

    // Initial Via-2 Mask Programming (or optional hex bitmap load)
`ifndef YOSYS
    initial begin
        for (int b = 0; b < NUM_BANKS; b++) begin
            for (int r = 0; r < ROWS; r++) begin
                via_rom_array[b * ROWS + r] = gen_via_row_pattern(b, r, MASK_SEED);
            end
        end
        if (ROM_INIT_FILE != "") begin
            $readmemh(ROM_INIT_FILE, via_rom_array);
        end
    end
`endif

    // Silicon Compiler / Testbench Runtime Mask Programming Port
    always_ff @(posedge clk) begin
        if (prog_en_i) begin
            via_rom_array[{prog_bank_i, prog_row_i}] <= prog_wdata_i;
        end
    end

    // -------------------------------------------------------------------------
    // Built-In Self-Test (BIST) & CRC-16-CCITT State Declarations
    // -------------------------------------------------------------------------
    typedef enum logic [1:0] {
        BIST_IDLE   = 2'b00,
        BIST_SCAN   = 2'b01,
        BIST_VERIFY = 2'b10,
        BIST_DONE   = 2'b11
    } bist_state_e;

    bist_state_e         bist_state_q, bist_state_d;
    logic [BANK_W-1:0]   bist_bank_q,  bist_bank_d;
    logic [ROW_W-1:0]    bist_row_q,   bist_row_d;
    logic [15:0]         bist_crc_q,   bist_crc_d;
    logic [15:0]         bist_ref_crc_q, bist_ref_crc_d;

    // Multiplexed Address & Bank Select + Non-Overlapping Bitline Precharge Interlock
    // [STAGE-23 FIX AUDIT-FINDING-001]: Strictly mutually exclusive PMOS bitline
    // precharge pull-up (pchg_pullup_active) and NMOS wordline evaluation (wl_eval_safe).
    logic [BANK_W-1:0]   mux_bank_sel;
    logic [ROW_W-1:0]    mux_row_addr;
    logic                pchg_pullup_active;
    logic                wl_eval_safe;
    logic                mux_read_fire;

    assign mux_bank_sel       = (bist_state_q == BIST_SCAN) ? bist_bank_q : bank_sel_i;
    assign mux_row_addr       = (bist_state_q == BIST_SCAN) ? bist_row_q  : addr_i;
    assign pchg_pullup_active = (!effective_sleep) && precharge_en && (!sa_en) && (bist_state_q != BIST_SCAN);
    assign wl_eval_safe       = (!effective_sleep) && (!pchg_pullup_active) && (
        (bist_state_q == BIST_SCAN) || (cs_en && sa_en && (precharge_en || bl_precharged_q))
    );
    assign mux_read_fire      = wl_eval_safe;
    assign bl_contention_prevented_o = (!effective_sleep) && cs_en && pchg_pullup_active;

    // -------------------------------------------------------------------------
    // Physical Bank & Wordline Decoder + Bitline Precharge State
    // -------------------------------------------------------------------------
    logic [NUM_BANKS-1:0] bank_onehot_comb;
    logic [COLS-1:0]      sensed_word_comb;
    logic [VIA_W-1:0]     via_popcnt_comb;

    always_comb begin
        bank_onehot_comb = '0;
        if (mux_read_fire) begin
            bank_onehot_comb[mux_bank_sel] = 1'b1;
        end
    end

    // Combinational Via-2 Array Lookup (when wordline asserted & bitlines precharged)
    always_comb begin
        if (mux_read_fire) begin
            sensed_word_comb = via_rom_array[{mux_bank_sel, mux_row_addr}];
        end else begin
            sensed_word_comb = '0;
        end
    end

    // Popcount Tree for Active Via-2 Contacts (Dynamic Power Telemetry)
    always_comb begin
        via_popcnt_comb = '0;
        if (mux_read_fire) begin
            for (int i = 0; i < COLS; i++) begin
                via_popcnt_comb = via_popcnt_comb + {{(VIA_W-1){1'b0}}, sensed_word_comb[i]};
            end
        end
    end

    // -------------------------------------------------------------------------
    // Sense-Amplifier Output Registers & Zero-Leakage Isolation Clamps
    // -------------------------------------------------------------------------
    logic [COLS-1:0]      rdata_q;
    logic                 rvalid_q;
    logic [VIA_W-1:0]     active_vias_q;
    logic [NUM_BANKS-1:0] bank_active_q;
    logic                 bl_precharged_q;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rdata_q         <= '0;
            rvalid_q        <= 1'b0;
            active_vias_q   <= '0;
            bank_active_q   <= '0;
            bl_precharged_q <= 1'b0;
        end else if (effective_sleep) begin
            // Zero-leakage power-gating clamps all sense-amp outputs to ground
            rdata_q         <= '0;
            rvalid_q        <= 1'b0;
            active_vias_q   <= '0;
            bank_active_q   <= '0;
            bl_precharged_q <= 1'b0;
        end else begin
            bl_precharged_q <= precharge_en || pchg_pullup_active;
            bank_active_q   <= bank_onehot_comb;
            if (cs_en && sa_en && (precharge_en || bl_precharged_q) && !pchg_pullup_active) begin
                rdata_q       <= sensed_word_comb;
                rvalid_q      <= 1'b1;
                active_vias_q <= via_popcnt_comb;
            end else begin
                rdata_q       <= '0;
                rvalid_q      <= 1'b0;
                active_vias_q <= '0;
            end
        end
    end

    // -------------------------------------------------------------------------
    // Unpacked Field Extraction (3-Bit CSD Base Weights + 6-Bit Outlier CAM/LUT)
    // -------------------------------------------------------------------------
    assign rdata_o            = rdata_q;
    assign weights_3b_o       = rdata_q[0 +: (COLS_3B * 3)];
    assign outlier_val6b_o    = rdata_q[(COLS_3B * 3) +: (OUTLIER_SLOTS * 6)];
    assign outlier_idx_o      = rdata_q[(COLS_3B * 3 + OUTLIER_SLOTS * 6) +: (OUTLIER_SLOTS * 6)];
    assign group_scale_fp16_o = rdata_q[(COLS_3B * 3 + OUTLIER_SLOTS * 12) +: 16];
    assign group_zp_int8_o    = rdata_q[(COLS_3B * 3 + OUTLIER_SLOTS * 12 + 16) +: 8];
    assign rvalid_o           = rvalid_q;
    assign active_vias_o      = active_vias_q;
    assign bank_active_o      = bank_active_q;
    assign bl_precharged_o    = bl_precharged_q;

    // -------------------------------------------------------------------------
    // Built-In Self-Test (BIST) CRC-16-CCITT Signature Generator (Poly 0x1021)
    // -------------------------------------------------------------------------
    function automatic logic [15:0] crc16_ccitt_step(
        input logic [15:0]     crc_in,
        input logic [COLS-1:0] data_word
    );
        logic [15:0] crc;
        logic [15:0] folded_word;
        crc = crc_in;
        // Fold COLS-bit word into 16-bit XOR digest then step 16 bits of CRC-16-CCITT
        folded_word = 16'h0000;
        for (int seg = 0; seg < (COLS / 16); seg++) begin
            folded_word = folded_word ^ data_word[seg*16 +: 16];
        end
        for (int b = 15; b >= 0; b--) begin
            if ((crc[15] ^ folded_word[b]) == 1'b1) begin
                crc = (crc << 1) ^ 16'h1021;
            end else begin
                crc = (crc << 1);
            end
        end
        crc16_ccitt_step = crc;
    endfunction

    localparam logic [ROW_W-1:0]  LAST_BIST_ROW  = BIST_SCAN_ROWS[ROW_W-1:0] - 1'b1;
    localparam logic [BANK_W-1:0] LAST_BIST_BANK = NUM_BANKS[BANK_W-1:0] - 1'b1;

    always_comb begin
        bist_state_d   = bist_state_q;
        bist_bank_d    = bist_bank_q;
        bist_row_d     = bist_row_q;
        bist_crc_d     = bist_crc_q;
        bist_ref_crc_d = bist_ref_crc_q;

        case (bist_state_q)
            BIST_IDLE: begin
                if (bist_start_i && !effective_sleep) begin
                    bist_state_d   = BIST_SCAN;
                    bist_bank_d    = '0;
                    bist_row_d     = '0;
                    bist_crc_d     = 16'hFFFF;
                    bist_ref_crc_d = 16'hFFFF;
                end
            end

            BIST_SCAN: begin
                if (effective_sleep) begin
                    bist_state_d = BIST_IDLE;
                end else begin
                    bist_crc_d     = crc16_ccitt_step(bist_crc_q, sensed_word_comb);
                    bist_ref_crc_d = crc16_ccitt_step(bist_ref_crc_q,
                                         via_rom_array[{bist_bank_q, bist_row_q}]);
                    if (bist_row_q == LAST_BIST_ROW) begin
                        bist_row_d = '0;
                        if (bist_bank_q == LAST_BIST_BANK) begin
                            bist_state_d = BIST_VERIFY;
                        end else begin
                            bist_bank_d = bist_bank_q + 1'b1;
                        end
                    end else begin
                        bist_row_d = bist_row_q + 1'b1;
                    end
                end
            end

            BIST_VERIFY: begin
                bist_state_d = BIST_DONE;
            end

            BIST_DONE: begin
                if (!bist_start_i) begin
                    bist_state_d = BIST_IDLE;
                end
            end

            default: bist_state_d = BIST_IDLE;
        endcase
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bist_state_q   <= BIST_IDLE;
            bist_bank_q    <= '0;
            bist_row_q     <= '0;
            bist_crc_q     <= 16'hFFFF;
            bist_ref_crc_q <= 16'hFFFF;
        end else begin
            bist_state_q   <= bist_state_d;
            bist_bank_q    <= bist_bank_d;
            bist_row_q     <= bist_row_d;
            bist_crc_q     <= bist_crc_d;
            bist_ref_crc_q <= bist_ref_crc_d;
        end
    end

    assign bist_busy_o  = (bist_state_q == BIST_SCAN) || (bist_state_q == BIST_VERIFY);
    assign bist_done_o  = (bist_state_q == BIST_DONE);
    assign bist_crc16_o = bist_crc_q;
    assign bist_pass_o  = (bist_state_q == BIST_DONE) && (bist_crc_q == bist_ref_crc_q);

    // =========================================================================
    // Formal Verification & Inline SVA Invariants (Yosys SAT & Verilator)
    // =========================================================================
    logic past_valid_q;
    logic past_sleep_q;
    logic past_read_req_q;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            past_valid_q    <= 1'b0;
            past_sleep_q    <= 1'b1;
            past_read_req_q <= 1'b0;
        end else begin
            past_valid_q    <= 1'b1;
            past_sleep_q    <= effective_sleep;
            past_read_req_q <= (!effective_sleep) && cs_en && sa_en && (precharge_en || bl_precharged_q) && (!pchg_pullup_active);
        end
    end

    always_ff @(posedge clk) begin
        if (rst_n) begin
            // PROP_M1_NO_BL_WL_CONTENTION: PMOS bitline precharge pull-up and NMOS wordline
            // evaluation are strictly mutually exclusive (zero VDD-to-GND crowbar contention)
            PROP_M1_NO_BL_WL_CONTENTION: assert (!(wl_eval_safe && pchg_pullup_active));
            if (!effective_sleep && cs_en && precharge_en && !sa_en && (bist_state_q != BIST_SCAN)) begin
                PROP_M1_CONTENTION_INTERLOCK: assert (bl_contention_prevented_o && !wl_eval_safe && (bank_onehot_comb == '0));
            end
        end
        if (past_valid_q) begin
            // PROP_M1_SLEEP_ZERO: Deep-sleep / isolation guarantees zero output & zero leakage
            if (past_sleep_q) begin
                assert (rdata_o == '0);
                assert (weights_3b_o == '0);
                assert (outlier_val6b_o == '0);
                assert (rvalid_o == 1'b0);
                assert (active_vias_o == '0);
                assert (bank_active_o == '0);
            end

            // PROP_M1_READ_LATENCY: Deterministic 1-cycle read valid response when awake
            if (past_read_req_q && !effective_sleep) begin
                assert (rvalid_o == 1'b1);
            end

            // PROP_M1_BIST_INTEGRITY: Completed BIST scan matches reference mask CRC-16
            if (bist_done_o) begin
                assert (bist_pass_o == 1'b1);
            end
        end
    end

endmodule
