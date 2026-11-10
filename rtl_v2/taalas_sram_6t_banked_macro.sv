// =============================================================================
// Module:      taalas_sram_6t_banked_macro (M5)
// Project:     Taalas HC1/HC2 Hardwired LLM Inference ASIC
// Description: 16-Bank On-Die 6T SRAM Macro featuring:
//              1. GF(2^4) Companion-Matrix XOR Bank-Conflict-Free Address Swizzler
//              2. (72,64) Extended Hamming SECDED ECC Encoder, Syndrome Decoder,
//                 Single-Bit Auto-Correction, Double-Bit Detection & Fault Injector
//              3. 8-Byte Write-Strobe Masking with Read-Modify-Write (RMW) ECC
//              4. Per-Bank Clock Gating, Deep-Sleep Retention & Conflict Analyzer
// =============================================================================

`timescale 1ns / 1ps

module taalas_sram_6t_banked_macro #(
    parameter int NUM_BANKS  = 16,
    parameter int BANK_DEPTH = 256,
    parameter int DATA_WIDTH = 64,
    parameter int ECC_WIDTH  = 8,
    parameter int RAW_WIDTH  = 72
) (
    input  logic                                clk,
    input  logic                                rst_n,

    // Power Management & Per-Bank Clock-Gating Controls
    input  logic                                ret_sleep_i,        // 0.5V retention deep sleep
    input  logic [NUM_BANKS-1:0]                bank_cg_en_i,       // Per-bank clock gate enable

    // Primary Memory Access Port (Logical Bank + Row Address)
    input  logic                                req_valid_i,
    input  logic                                req_we_i,
    input  logic [3:0]                          req_bank_i,         // Logical bank b_log [0..15]
    input  logic [$clog2(BANK_DEPTH)-1:0]       req_row_i,          // Row address r_row
    input  logic [DATA_WIDTH-1:0]               req_wdata_i,        // 64-bit write data
    input  logic [(DATA_WIDTH/8)-1:0]           req_wmask_i,        // 8-bit byte write strobe

    // Parallel Vector Stride Conflict Analyzer Interface (16-Lane Check)
    input  logic [NUM_BANKS-1:0]                vec_req_valid_i,
    input  logic [NUM_BANKS*8-1:0]              vec_req_row_i,
    output logic [NUM_BANKS-1:0]                bank_conflict_mask_o,
    output logic                                conflict_free_o,

    // Diagnostic SECDED Fault Injection Port (UVM & Formal Verification)
    input  logic                                err_inj_en_i,
    input  logic [RAW_WIDTH-1:0]                err_inj_mask_i,     // 72-bit XOR fault mask

    // Synchronous Read Response & ECC Telemetry Outputs
    output logic                                resp_valid_o,
    output logic [DATA_WIDTH-1:0]               resp_rdata_o,       // SEC-corrected 64b data
    output logic [RAW_WIDTH-1:0]                resp_raw_codeword_o,// Raw 72b codeword read
    output logic [3:0]                          phys_bank_o,        // Swizzled physical bank
    output logic                                sec_err_o,          // Single-Error Corrected
    output logic                                ded_err_o,          // Double-Error Detected
    output logic [ECC_WIDTH-1:0]                err_syndrome_o,     // {overall_par, synd[6:0]}
    output logic [15:0]                         sec_err_cnt_o,      // Cumulative SEC count
    output logic [15:0]                         ded_err_cnt_o       // Cumulative DED count
);

    localparam int ROW_W = $clog2(BANK_DEPTH);

    // -------------------------------------------------------------------------
    // 1. Algebraic GF(2^4) Bank-Conflict-Free Address Swizzler
    //    Irreducible polynomial p(x) = x^4 + x + 1 (0x13), multiplier = 0x3
    // -------------------------------------------------------------------------
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
        logic [3:0] r_lo;
        logic [3:0] r_hi;
        r_lo = row_addr_8b[3:0];
        r_hi = row_addr_8b[7:4];
        swizzle_gf16_bank = logical_bank ^ r_lo ^ gf16_mul_by_3(r_hi);
    endfunction

    // Zero-pad or slice row address to 8 bits for GF(2^4) swizzling
    logic [7:0] req_row_8b;
    generate
        if (ROW_W >= 8) begin : gen_row8_slice
            assign req_row_8b = req_row_i[7:0];
        end else begin : gen_row8_pad
            assign req_row_8b = {{(8-ROW_W){1'b0}}, req_row_i};
        end
    endgenerate

    logic [3:0] swizzled_phys_bank_comb;
    assign swizzled_phys_bank_comb = swizzle_gf16_bank(req_bank_i, req_row_8b);

    // -------------------------------------------------------------------------
    // Parallel 16-Lane Vector Stride Bank Conflict Detector
    // -------------------------------------------------------------------------
    logic [3:0] lane_phys_bank [0:NUM_BANKS-1];

    always_comb begin
        for (int i = 0; i < NUM_BANKS; i++) begin
            lane_phys_bank[i] = swizzle_gf16_bank(i[3:0], vec_req_row_i[i*8 +: 8]);
        end

        bank_conflict_mask_o = '0;
        for (int i = 0; i < NUM_BANKS; i++) begin
            for (int j = 0; j < NUM_BANKS; j++) begin
                if ((i != j) && vec_req_valid_i[i] && vec_req_valid_i[j]) begin
                    if (lane_phys_bank[i] == lane_phys_bank[j]) begin
                        bank_conflict_mask_o[i] = 1'b1;
                    end
                end
            end
        end
        conflict_free_o = (bank_conflict_mask_o == '0);
    end

    // -------------------------------------------------------------------------
    // 2. (72,64) Extended Hamming SECDED ECC Encoder & Syndrome Decoder
    //    Each data bit i in [0..63] maps to the i-th non-power-of-2 integer
    //    C_i in [3..71] \ {4, 8, 16, 32, 64}.
    // -------------------------------------------------------------------------
    function automatic logic [6:0] get_syndrome_col(input logic [5:0] bit_idx);
        logic [6:0] col_val;
        if (bit_idx == 6'd0)       col_val = 7'd3;
        else if (bit_idx <= 6'd3)  col_val = {1'b0, bit_idx} + 7'd4; // 5..7
        else if (bit_idx <= 6'd10) col_val = {1'b0, bit_idx} + 7'd5; // 9..15
        else if (bit_idx <= 6'd25) col_val = {1'b0, bit_idx} + 7'd6; // 17..31
        else if (bit_idx <= 56)    col_val = {1'b0, bit_idx} + 7'd7; // 33..63
        else                       col_val = {1'b0, bit_idx} + 7'd8; // 65..71
        get_syndrome_col = col_val;
    endfunction

    function automatic logic [7:0] secded_encode_72_64(input logic [63:0] d_in);
        logic [6:0] p_hamming;
        logic       p_overall;
        logic [6:0] col_c;
        p_hamming = 7'd0;
        for (int i = 0; i < 64; i++) begin
            col_c = get_syndrome_col(i[5:0]);
            if (d_in[i]) begin
                p_hamming = p_hamming ^ col_c;
            end
        end
        p_overall = (^d_in) ^ (^p_hamming);
        secded_encode_72_64 = {p_overall, p_hamming};
    endfunction

    // Decode 72-bit codeword {ecc_rx[7:0], data_rx[63:0]} -> {ded, sec, synd[7:0], d_corr[63:0]}
    function automatic logic [73:0] secded_decode_72_64(
        input logic [63:0] data_rx,
        input logic [7:0]  ecc_rx
    );
        logic [7:0]  ecc_calc;
        logic [6:0]  syndrome_7b;
        logic        total_parity;
        logic [63:0] data_corr;
        logic        sec_flag;
        logic        ded_flag;
        logic [6:0]  col_c;

        ecc_calc     = secded_encode_72_64(data_rx);
        syndrome_7b  = ecc_rx[6:0] ^ ecc_calc[6:0];
        total_parity = ecc_rx[7] ^ ecc_calc[7] ^ (^syndrome_7b);

        data_corr = data_rx;
        sec_flag  = 1'b0;
        ded_flag  = 1'b0;

        if ((syndrome_7b == 7'd0) && (total_parity == 1'b0)) begin
            // Clean codeword: zero error
            sec_flag = 1'b0;
            ded_flag = 1'b0;
        end else if (total_parity == 1'b1) begin
            // Single-Bit Error Corrected (SEC) in either data[63:0] or ecc[7:0]
            sec_flag = 1'b1;
            ded_flag = 1'b0;
            for (int i = 0; i < 64; i++) begin
                col_c = get_syndrome_col(i[5:0]);
                if (syndrome_7b == col_c) begin
                    data_corr[i] = ~data_rx[i];
                end
            end
        end else begin
            // syndrome_7b != 0 && total_parity == 0 -> Double-Bit Error Detected (DED)
            sec_flag = 1'b0;
            ded_flag = 1'b1;
        end

        secded_decode_72_64 = {ded_flag, sec_flag, total_parity, syndrome_7b, data_corr};
    endfunction

    // -------------------------------------------------------------------------
    // 3. 16-Bank Physical 6T SRAM Storage Array (72-bit Codewords: {ECC[7:0], DATA[63:0]})
    // -------------------------------------------------------------------------
    localparam int TOTAL_WORDS = NUM_BANKS * BANK_DEPTH;
    logic [RAW_WIDTH-1:0] sram_array [0:TOTAL_WORDS-1];

`ifndef YOSYS
    initial begin
        for (int idx = 0; idx < TOTAL_WORDS; idx++) begin
            sram_array[idx] = '0;
        end
    end
`endif

    // Target physical address calculation
    logic [$clog2(TOTAL_WORDS)-1:0] phys_word_idx;
    assign phys_word_idx = {swizzled_phys_bank_comb, req_row_i};

    // Effective bank clock enable (active when not in retention sleep and bank clock enabled)
    logic target_bank_clk_en;
    assign target_bank_clk_en = (!ret_sleep_i) && bank_cg_en_i[swizzled_phys_bank_comb];

    // Combinational Read-Modify-Write (RMW) & Read ECC Datapath
    logic [RAW_WIDTH-1:0]  raw_word_from_mem;
    logic [RAW_WIDTH-1:0]  raw_word_post_inj;
    logic [73:0]           dec_result_comb;
    logic [DATA_WIDTH-1:0] rmw_merged_data_comb;
    logic [ECC_WIDTH-1:0]  rmw_new_ecc_comb;

    assign raw_word_from_mem = sram_array[phys_word_idx];
    assign raw_word_post_inj = err_inj_en_i ? (raw_word_from_mem ^ err_inj_mask_i)
                                            : raw_word_from_mem;

    assign dec_result_comb = secded_decode_72_64(
        raw_word_post_inj[63:0],
        raw_word_post_inj[71:64]
    );

    // Sub-word 8-Byte Write Strobe Masking with SEC-cleaned Read-Modify-Write
    logic        rmw_sec_flag_comb;
    logic        rmw_ded_flag_comb;
    logic [7:0]  rmw_synd_comb;
    logic [63:0] base_clean_word_comb;
    logic [73:0] rmw_dec_comb;

    always_comb begin
        // [STAGE-10 FIX BUG-HC1-003]: Decode raw_word_post_inj during sub-word RMW so injected faults are detected
        rmw_dec_comb         = secded_decode_72_64(raw_word_post_inj[63:0], raw_word_post_inj[71:64]);
        base_clean_word_comb = rmw_dec_comb[63:0];
        rmw_synd_comb        = rmw_dec_comb[71:64];
        rmw_sec_flag_comb    = rmw_dec_comb[72];
        rmw_ded_flag_comb    = rmw_dec_comb[73];
        rmw_merged_data_comb = base_clean_word_comb;
        for (int b = 0; b < 8; b++) begin
            if (req_wmask_i[b]) begin
                rmw_merged_data_comb[b*8 +: 8] = req_wdata_i[b*8 +: 8];
            end
        end
        rmw_new_ecc_comb = secded_encode_72_64(rmw_merged_data_comb);
    end

    // -------------------------------------------------------------------------
    // Round-Robin Multi-Request Priority Bank Arbiter & Background Scrubber
    // -------------------------------------------------------------------------
    logic [3:0]  rr_arb_ptr_q;
    logic [3:0]  arb_grant_lane_q;
    logic        arb_grant_valid_q;
    logic [11:0] scrub_row_ptr_q;
    logic [3:0]  arb_next_lane_comb;

    always_comb begin
        arb_next_lane_comb = arb_grant_lane_q;
        for (int offset = 0; offset < NUM_BANKS; offset++) begin
            if (vec_req_valid_i[(rr_arb_ptr_q + offset[3:0]) & 4'hF]) begin
                arb_next_lane_comb = (rr_arb_ptr_q + offset[3:0]) & 4'hF;
            end
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rr_arb_ptr_q      <= 4'd0;
            arb_grant_lane_q  <= 4'd0;
            arb_grant_valid_q <= 1'b0;
            scrub_row_ptr_q   <= 12'd0;
        end else if (!ret_sleep_i) begin
            arb_grant_valid_q <= (|vec_req_valid_i);
            arb_grant_lane_q  <= arb_next_lane_comb;
            if (|vec_req_valid_i) begin
                rr_arb_ptr_q <= rr_arb_ptr_q + 4'd1;
            end else if (!req_valid_i) begin
                // Advance idle background ECC scrub pointer when bank array is idle
                scrub_row_ptr_q <= scrub_row_ptr_q + 12'd1;
            end
        end
    end

    // Synchronous 6T SRAM Array Write & 1-Cycle Read Response Pipeline
    logic                  resp_valid_q;
    logic [DATA_WIDTH-1:0] resp_rdata_q;
    logic [RAW_WIDTH-1:0]  resp_raw_codeword_q;
    logic [3:0]            phys_bank_q;
    logic                  sec_err_q;
    logic                  ded_err_q;
    logic [ECC_WIDTH-1:0]  err_syndrome_q;
    logic [15:0]           sec_err_cnt_q;
    logic [15:0]           ded_err_cnt_q;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            resp_valid_q        <= 1'b0;
            resp_rdata_q        <= '0;
            resp_raw_codeword_q <= '0;
            phys_bank_q         <= 4'd0;
            sec_err_q           <= 1'b0;
            ded_err_q           <= 1'b0;
            err_syndrome_q      <= 8'd0;
            sec_err_cnt_q       <= 16'd0;
            ded_err_cnt_q       <= 16'd0;
        end else if (ret_sleep_i) begin
            // Deep-sleep retention: periphery clamped to 0, array retains state
            resp_valid_q        <= 1'b0;
            resp_rdata_q        <= '0;
            resp_raw_codeword_q <= '0;
            sec_err_q           <= 1'b0;
            ded_err_q           <= 1'b0;
            err_syndrome_q      <= 8'd0;
        end else if (req_valid_i && target_bank_clk_en) begin
            phys_bank_q <= swizzled_phys_bank_comb;
            if (req_we_i) begin
                resp_valid_q <= 1'b0;
                if (req_wmask_i == 8'hFF) begin
                    sram_array[phys_word_idx] <= {rmw_new_ecc_comb, rmw_merged_data_comb};
                    sec_err_q                 <= 1'b0;
                    ded_err_q                 <= 1'b0;
                    err_syndrome_q            <= 8'd0;
                end else begin
                    // [STAGE-10 FIX BUG-HC1-003]: Block writeback on RMW DED fault & accumulate ECC telemetry
                    if (!rmw_ded_flag_comb) begin
                        sram_array[phys_word_idx] <= {rmw_new_ecc_comb, rmw_merged_data_comb};
                    end
                    sec_err_q      <= rmw_sec_flag_comb;
                    ded_err_q      <= rmw_ded_flag_comb;
                    err_syndrome_q <= rmw_synd_comb;
                    if (rmw_sec_flag_comb) sec_err_cnt_q <= sec_err_cnt_q + 16'd1;
                    if (rmw_ded_flag_comb) ded_err_cnt_q <= ded_err_cnt_q + 16'd1;
                end
            end else begin
                resp_valid_q        <= 1'b1;
                resp_rdata_q        <= dec_result_comb[63:0];
                resp_raw_codeword_q <= raw_word_post_inj;
                err_syndrome_q      <= dec_result_comb[71:64];
                sec_err_q           <= dec_result_comb[72];
                ded_err_q           <= dec_result_comb[73];
                if (dec_result_comb[72]) sec_err_cnt_q <= sec_err_cnt_q + 16'd1;
                if (dec_result_comb[73]) ded_err_cnt_q <= ded_err_cnt_q + 16'd1;
            end
        end else begin
            resp_valid_q   <= 1'b0;
            sec_err_q      <= 1'b0;
            ded_err_q      <= 1'b0;
            err_syndrome_q <= 8'd0;
        end
    end

    assign resp_valid_o        = resp_valid_q;
    assign resp_rdata_o        = resp_rdata_q;
    assign resp_raw_codeword_o = resp_raw_codeword_q;
    assign phys_bank_o         = phys_bank_q;
    assign sec_err_o           = sec_err_q;
    assign ded_err_o           = ded_err_q;
    assign err_syndrome_o      = err_syndrome_q;
    assign sec_err_cnt_o       = sec_err_cnt_q;
    assign ded_err_cnt_o       = ded_err_cnt_q;

    // =========================================================================
    // 4. Inline Formal Verification & Algebraic Proof Signals (Yosys SAT & SVA)
    // =========================================================================
    // Algebraic witness signals driven from primary inputs so Yosys SAT proves
    // universal quantification over all 2^64 data words, all 16 banks, and all
    // 72 single-bit / double-bit error positions.
    logic [3:0]  formal_b1, formal_b2;
    logic [3:0]  formal_phys_b1, formal_phys_b2;
    logic [7:0]  formal_row_8b;
    logic [7:0]  formal_ecc_clean;
    logic [71:0] formal_cw_clean;
    logic [6:0]  formal_bit_idx1, formal_bit_idx2;
    logic [71:0] formal_cw_1bit_err, formal_cw_2bit_err;
    logic [73:0] formal_dec_clean, formal_dec_1bit, formal_dec_2bit;

    assign formal_b1      = req_bank_i;
    assign formal_b2      = req_wmask_i[3:0];
    assign formal_row_8b  = req_row_8b;
    assign formal_phys_b1 = swizzle_gf16_bank(formal_b1, formal_row_8b);
    assign formal_phys_b2 = swizzle_gf16_bank(formal_b2, formal_row_8b);

    assign formal_ecc_clean = secded_encode_72_64(req_wdata_i);
    assign formal_cw_clean  = {formal_ecc_clean, req_wdata_i};

    // Map arbitrary input bits to valid codeword bit indices [0..71]
    assign formal_bit_idx1 = (err_inj_mask_i[6:0] < 7'd72) ? err_inj_mask_i[6:0]
                                                           : (err_inj_mask_i[6:0] - 7'd72);
    assign formal_bit_idx2 = (err_inj_mask_i[13:7] < 7'd72) ? err_inj_mask_i[13:7]
                                                            : (err_inj_mask_i[13:7] - 7'd72);

    assign formal_cw_1bit_err = formal_cw_clean ^ (72'd1 << formal_bit_idx1);
    assign formal_cw_2bit_err = formal_cw_clean ^ (72'd1 << formal_bit_idx1)
                                                ^ (72'd1 << formal_bit_idx2);

    assign formal_dec_clean = secded_decode_72_64(formal_cw_clean[63:0],    formal_cw_clean[71:64]);
    assign formal_dec_1bit  = secded_decode_72_64(formal_cw_1bit_err[63:0], formal_cw_1bit_err[71:64]);
    assign formal_dec_2bit  = secded_decode_72_64(formal_cw_2bit_err[63:0], formal_cw_2bit_err[71:64]);

    logic        past_valid_q;
    logic        past_ret_sleep_q;
    logic [11:0] past_scrub_ptr_q;
    logic [3:0]  past_arb_lane_q;
    logic        past_arb_valid_q;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            past_valid_q     <= 1'b0;
            past_ret_sleep_q <= 1'b0;
            past_scrub_ptr_q <= 12'd0;
            past_arb_lane_q  <= 4'd0;
            past_arb_valid_q <= 1'b0;
        end else begin
            past_valid_q     <= 1'b1;
            past_ret_sleep_q <= ret_sleep_i;
            past_scrub_ptr_q <= scrub_row_ptr_q;
            past_arb_lane_q  <= arb_grant_lane_q;
            past_arb_valid_q <= arb_grant_valid_q;
        end
    end

    always_ff @(posedge clk) begin
        if (past_valid_q) begin
            // PROP_M5_GF16_BIJECTION: Distinct logical banks NEVER collide on same row
            if (formal_b1 != formal_b2) begin
                assert (formal_phys_b1 != formal_phys_b2);
            end

            // PROP_M5_SECDED_CLEAN: Zero error produces exact data, zero syndrome & zero flags
            assert (formal_dec_clean[63:0]  == req_wdata_i);
            assert (formal_dec_clean[71:64] == 8'd0);
            assert (formal_dec_clean[72]    == 1'b0);
            assert (formal_dec_clean[73]    == 1'b0);

            // PROP_M5_SECDED_100PCT_SEC: Any single-bit flip in [0..71] is 100% corrected!
            assert (formal_dec_1bit[63:0] == req_wdata_i);
            assert (formal_dec_1bit[71]   == 1'b1);
            assert ((formal_dec_1bit[70:64] != 7'd0) || (formal_bit_idx1 == 7'd71));
            assert (formal_dec_1bit[72]   == 1'b1);
            assert (formal_dec_1bit[73]   == 1'b0);

            // PROP_M5_SECDED_100PCT_DED: Any double-bit flip in [0..71] is 100% detected!
            if (formal_bit_idx1 != formal_bit_idx2) begin
                assert (formal_dec_2bit[63:0]  == formal_cw_2bit_err[63:0]);
                assert (formal_dec_2bit[70:64] != 7'd0);
                assert (formal_dec_2bit[71]    == 1'b0);
                assert (formal_dec_2bit[73]    == 1'b1);
                assert (formal_dec_2bit[72]    == 1'b0);
            end

            // PROP_M5_RMW_MUTEX: RMW decoder never asserts SEC and DED simultaneously
            assert (!(rmw_sec_flag_comb && rmw_ded_flag_comb));
            if (!rmw_sec_flag_comb && !rmw_ded_flag_comb) begin
                assert (rmw_synd_comb == 8'd0);
            end
            // PROP_BUG003_RMW_NO_DED_LAUNDERING: RMW decoder matches primary SECDED decoder on raw_word_post_inj
            assert (rmw_dec_comb == dec_result_comb);

            // PROP_M5_SCRUB_RETENTION_HOLD: Retention sleep freezes scrubber & arbiter state
            if (past_valid_q && past_ret_sleep_q) begin
                assert (scrub_row_ptr_q  == past_scrub_ptr_q);
                assert (arb_grant_lane_q == past_arb_lane_q);
                assert (arb_grant_valid_q == past_arb_valid_q);
                assert (resp_valid_o == 1'b0);
                assert (resp_rdata_o == '0);
                assert (sec_err_o    == 1'b0);
                assert (ded_err_o    == 1'b0);
            end
        end
    end

endmodule
