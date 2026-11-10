// =============================================================================
// Module:      taalas_ecc_bist_scrubber (Stage 18 Silicon Reliability Subsystem)
// Project:     Taalas HC1/HC2 Hardwired LLM Inference ASIC
// Description: Autonomous Silicon Reliability, Soft-Error SEU/MBU Patrol
//              Scrubber, 8-Entry CAM Spare-Row Repair, Via-ROM CRC-16 BIST
//              & Transient L*di/dt Voltage-Droop Clock-Stretch Controller.
// =============================================================================

`timescale 1ns / 1ps

module taalas_ecc_bist_scrubber #(
    parameter int NUM_BANKS      = 32,
    parameter int BANK_DEPTH     = 256,
    parameter int DATA_WIDTH     = 64,
    parameter int ECC_WIDTH      = 8,
    parameter int RAW_WIDTH      = 72,
    parameter int ROM_DEPTH      = 8192,
    parameter int SPARE_ROWS     = 8,
    parameter int STRETCH_WINDOW = 8,
    parameter int DIDT_THRESH    = 64
) (
    input  logic                            clk,
    input  logic                            rst_n,

    // -------------------------------------------------------------------------
    // 1. Background 6T SRAM Patrol Scrubber & Spare-Row Repair Interface
    // -------------------------------------------------------------------------
    input  logic                            active_sram_req_i,
    input  logic [$clog2(NUM_BANKS)-1:0]    active_sram_bank_i,
    input  logic [$clog2(BANK_DEPTH)-1:0]   active_sram_addr_i,

    output logic                            scrub_sram_re_o,
    output logic [$clog2(NUM_BANKS)-1:0]    scrub_sram_bank_o,
    output logic [$clog2(BANK_DEPTH)-1:0]   scrub_sram_addr_o,

    input  logic                            scrub_sram_rvalid_i,
    input  logic [$clog2(NUM_BANKS)-1:0]    scrub_sram_rbank_i,
    input  logic [$clog2(BANK_DEPTH)-1:0]   scrub_sram_raddr_i,
    input  logic [RAW_WIDTH-1:0]            scrub_sram_rdata_i,

    output logic                            scrub_wb_we_o,
    output logic [$clog2(NUM_BANKS)-1:0]    scrub_wb_bank_o,
    output logic [$clog2(BANK_DEPTH)-1:0]   scrub_wb_addr_o,
    output logic [RAW_WIDTH-1:0]            scrub_wb_data_o,

    output logic [31:0]                     sbe_scrubbed_cnt_o,
    output logic [15:0]                     dbe_detected_cnt_o,
    output logic                            uncorrectable_dbe_irq_o,
    output logic [15:0]                     fault_log_reg_o,

    output logic                            remap_valid_o,
    output logic [12:0]                     remap_src_addr_o,
    output logic [$clog2(SPARE_ROWS)-1:0]   remap_dst_row_o,
    output logic                            active_hit_spare_o,
    output logic [$clog2(SPARE_ROWS)-1:0]   active_spare_row_o,
    output logic [$clog2(SPARE_ROWS):0]     spare_rows_used_o,

    // -------------------------------------------------------------------------
    // 2. Power-On & Periodic Via-ROM CRC-16-CCITT BIST Interface
    // -------------------------------------------------------------------------
    input  logic                            bist_start_i,
    input  logic [DATA_WIDTH-1:0]           bist_rom_data_i,
    input  logic [15:0]                     expected_crc16_i,

    output logic                            bist_running_o,
    output logic                            bist_rom_re_o,
    output logic [$clog2(ROM_DEPTH)-1:0]    bist_rom_addr_o,
    output logic [15:0]                     bist_crc16_o,
    output logic                            bist_done_o,
    output logic                            bist_pass_o,

    // -------------------------------------------------------------------------
    // 3. Transient L*di/dt Voltage-Droop Monitor & Clock-Stretch Interface
    // -------------------------------------------------------------------------
    input  logic [7:0]                      canary_taps_i,
    input  logic [7:0]                      mac_active_lanes_i,

    output logic                            clk_stretch_en_o,
    output logic                            gated_clk_en_o,
    output logic [15:0]                     droop_event_cnt_o
);

    localparam int BANK_W = $clog2(NUM_BANKS);
    localparam int ADDR_W = $clog2(BANK_DEPTH);
    localparam int ROM_W  = $clog2(ROM_DEPTH);
    localparam int SPARE_W = $clog2(SPARE_ROWS);

    // -------------------------------------------------------------------------
    // A. (72,64) SECDED Syndrome Generator & Single-Bit Corrector
    // -------------------------------------------------------------------------
    function automatic logic [6:0] get_syndrome_col(input logic [5:0] bit_idx);
        logic [6:0] col_val;
        if (bit_idx == 6'd0)       col_val = 7'd3;
        else if (bit_idx <= 6'd3)  col_val = {1'b0, bit_idx} + 7'd4; // 5..7
        else if (bit_idx <= 6'd10) col_val = {1'b0, bit_idx} + 7'd5; // 9..15
        else if (bit_idx <= 6'd25) col_val = {1'b0, bit_idx} + 7'd6; // 17..31
        else if (bit_idx <= 6'd56) col_val = {1'b0, bit_idx} + 7'd7; // 33..63
        else                       col_val = {1'b0, bit_idx} + 7'd8; // 65..71
        get_syndrome_col = col_val;
    endfunction

    function automatic logic [7:0] secded_encode_72_64(input logic [63:0] d_in);
        logic [6:0] p_hamming;
        logic       p_overall;
        p_hamming[0] = ^(d_in & 64'hAB55555556AAAD5B);
        p_hamming[1] = ^(d_in & 64'hCD9999999B33366D);
        p_hamming[2] = ^(d_in & 64'hF1E1E1E1E3C3C78E);
        p_hamming[3] = ^(d_in & 64'h01FE01FE03FC07F0);
        p_hamming[4] = ^(d_in & 64'h01FFFE0003FFF800);
        p_hamming[5] = ^(d_in & 64'h01FFFFFFFC000000);
        p_hamming[6] = ^(d_in & 64'hFE00000000000000);
        p_overall    = (^d_in) ^ (^p_hamming);
        secded_encode_72_64 = {p_overall, p_hamming};
    endfunction

    logic [63:0] scrub_data_rx;
    logic [7:0]  scrub_ecc_rx;
    logic [7:0]  scrub_ecc_calc;
    logic [6:0]  scrub_syndrome_7b;
    logic        scrub_overall_par;
    logic        scrub_sbe_detected;
    logic        scrub_dbe_detected;
    logic        scrub_is_data_err;
    logic [63:0] scrub_data_corrected;
    logic [7:0]  scrub_ecc_corrected;

    assign scrub_data_rx     = scrub_sram_rdata_i[63:0];
    assign scrub_ecc_rx      = scrub_sram_rdata_i[71:64];
    assign scrub_ecc_calc    = secded_encode_72_64(scrub_data_rx);
    assign scrub_syndrome_7b = scrub_ecc_rx[6:0] ^ scrub_ecc_calc[6:0];
    assign scrub_overall_par = scrub_ecc_rx[7] ^ scrub_ecc_calc[7] ^ (^scrub_syndrome_7b);

    always_comb begin
        scrub_data_corrected = scrub_data_rx;
        scrub_sbe_detected   = 1'b0;
        scrub_dbe_detected   = 1'b0;
        scrub_is_data_err    = 1'b0;

        if (scrub_sram_rvalid_i) begin
            if ((scrub_overall_par == 1'b1) && (scrub_syndrome_7b <= 7'd71)) begin
                // [STAGE-23 FIX AUDIT-FINDING-003]: Valid Single-Bit Error (SBE) in data[63:0] or ecc[7:0]
                scrub_sbe_detected = 1'b1;
                for (int i = 0; i < 64; i++) begin
                    if (scrub_syndrome_7b == get_syndrome_col(i[5:0])) begin
                        scrub_data_corrected[i] = ~scrub_data_rx[i];
                        scrub_is_data_err       = 1'b1;
                    end
                end
            end else if (scrub_syndrome_7b != 7'd0) begin
                // Double-Bit Error (DBE) or unmapped odd-parity MBU (syndrome in [72..127])
                scrub_dbe_detected = 1'b1;
            end
        end
        // Linear SECDED identity: if data bit flipped, ecc_rx is already valid for
        // scrub_data_corrected; otherwise data_rx is clean and scrub_ecc_calc is valid.
        scrub_ecc_corrected = scrub_is_data_err ? scrub_ecc_rx : scrub_ecc_calc;
    end

    // -------------------------------------------------------------------------
    // B. Zero-Overhead Background Patrol Scrubber & 8-Entry CAM Spare-Row Table
    // -------------------------------------------------------------------------
    logic [BANK_W-1:0] patrol_bank_q;
    logic [ADDR_W-1:0] patrol_addr_q;

    // Steal 0% bandwidth from active LLM token decode SRAM traffic
    assign scrub_sram_re_o   = !active_sram_req_i;
    assign scrub_sram_bank_o = patrol_bank_q;
    assign scrub_sram_addr_o = patrol_addr_q;

    // 8-Entry CAM Spare-Row Repair Table
    logic [SPARE_ROWS-1:0] cam_valid_q;
    logic [12:0]           cam_tag_q [0:SPARE_ROWS-1];
    logic [SPARE_W:0]      cam_alloc_ptr_q;
    logic [12:0]           fault_full_addr_w;
    logic [12:0]           active_full_addr_w;
    logic                  cam_already_mapped;
    logic [SPARE_W-1:0]    cam_existing_idx;

    assign fault_full_addr_w  = {{(5-BANK_W){1'b0}}, scrub_sram_rbank_i,
                                 {(8-ADDR_W){1'b0}}, scrub_sram_raddr_i};
    assign active_full_addr_w = {{(5-BANK_W){1'b0}}, active_sram_bank_i,
                                 {(8-ADDR_W){1'b0}}, active_sram_addr_i};

    always_comb begin
        cam_already_mapped = 1'b0;
        cam_existing_idx   = '0;
        active_hit_spare_o = 1'b0;
        active_spare_row_o = '0;

        for (int s = 0; s < SPARE_ROWS; s++) begin
            if (cam_valid_q[s] && (cam_tag_q[s] == fault_full_addr_w)) begin
                cam_already_mapped = 1'b1;
                cam_existing_idx   = s[SPARE_W-1:0];
            end
            if (active_sram_req_i && cam_valid_q[s] && (cam_tag_q[s] == active_full_addr_w)) begin
                active_hit_spare_o = 1'b1;
                active_spare_row_o = s[SPARE_W-1:0];
            end
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            patrol_bank_q           <= '0;
            patrol_addr_q           <= '0;
            scrub_wb_we_o           <= 1'b0;
            scrub_wb_bank_o         <= '0;
            scrub_wb_addr_o         <= '0;
            scrub_wb_data_o         <= '0;
            sbe_scrubbed_cnt_o      <= 32'd0;
            dbe_detected_cnt_o      <= 16'd0;
            uncorrectable_dbe_irq_o <= 1'b0;
            fault_log_reg_o         <= 16'd0;
            remap_valid_o           <= 1'b0;
            remap_src_addr_o        <= 13'd0;
            remap_dst_row_o         <= '0;
            cam_valid_q             <= '0;
            cam_alloc_ptr_q         <= '0;
            for (int s = 0; s < SPARE_ROWS; s++) begin
                cam_tag_q[s] <= 13'd0;
            end
        end else begin
            // Advance patrol address on idle cycles when scrubber read issues
            if (!active_sram_req_i) begin
                if (patrol_addr_q == ADDR_W'(BANK_DEPTH - 1)) begin
                    patrol_addr_q <= '0;
                    patrol_bank_q <= patrol_bank_q + 1'b1;
                end else begin
                    patrol_addr_q <= patrol_addr_q + 1'b1;
                end
            end

            // Default single-cycle pulses
            scrub_wb_we_o           <= 1'b0;
            uncorrectable_dbe_irq_o <= 1'b0;
            remap_valid_o           <= 1'b0;

            if (scrub_sbe_detected) begin
                scrub_wb_we_o      <= 1'b1;
                scrub_wb_bank_o    <= scrub_sram_rbank_i;
                scrub_wb_addr_o    <= scrub_sram_raddr_i;
                scrub_wb_data_o    <= {scrub_ecc_corrected, scrub_data_corrected};
                sbe_scrubbed_cnt_o <= sbe_scrubbed_cnt_o + 32'd1;
            end else if (scrub_dbe_detected) begin
                uncorrectable_dbe_irq_o <= 1'b1;
                dbe_detected_cnt_o      <= dbe_detected_cnt_o + 16'd1;
                fault_log_reg_o         <= {3'b000, fault_full_addr_w};
                remap_src_addr_o        <= fault_full_addr_w;

                if (cam_already_mapped) begin
                    remap_valid_o   <= 1'b1;
                    remap_dst_row_o <= cam_existing_idx;
                end else if (cam_alloc_ptr_q < (SPARE_W+1)'(SPARE_ROWS)) begin
                    cam_valid_q[cam_alloc_ptr_q[SPARE_W-1:0]] <= 1'b1;
                    cam_tag_q[cam_alloc_ptr_q[SPARE_W-1:0]]   <= fault_full_addr_w;
                    remap_valid_o                             <= 1'b1;
                    remap_dst_row_o                           <= cam_alloc_ptr_q[SPARE_W-1:0];
                    cam_alloc_ptr_q                           <= cam_alloc_ptr_q + 1'b1;
                end
            end
        end
    end

    assign spare_rows_used_o = cam_alloc_ptr_q;

    // -------------------------------------------------------------------------
    // C. Power-On & Periodic Via-ROM CRC-16-CCITT (0x1021) BIST Engine
    // -------------------------------------------------------------------------
    function automatic logic [15:0] crc16_ccitt_step64(
        input logic [15:0] crc_in,
        input logic [63:0] data_in
    );
        logic [15:0] c;
        c[ 0] = ^(crc_in & 16'h859B) ^ ^(data_in & 64'h859B040B1C581911);
        c[ 1] = ^(crc_in & 16'h0B36) ^ ^(data_in & 64'h0B36081638B03222);
        c[ 2] = ^(crc_in & 16'h166C) ^ ^(data_in & 64'h166C102C71606444);
        c[ 3] = ^(crc_in & 16'h2CD8) ^ ^(data_in & 64'h2CD82058E2C0C888);
        c[ 4] = ^(crc_in & 16'h59B0) ^ ^(data_in & 64'h59B040B1C5819110);
        c[ 5] = ^(crc_in & 16'h36FB) ^ ^(data_in & 64'h36FB8568975B3B31);
        c[ 6] = ^(crc_in & 16'h6DF7) ^ ^(data_in & 64'h6DF70AD12EB67662);
        c[ 7] = ^(crc_in & 16'hDBEE) ^ ^(data_in & 64'hDBEE15A25D6CECC4);
        c[ 8] = ^(crc_in & 16'hB7DC) ^ ^(data_in & 64'hB7DC2B44BAD9D988);
        c[ 9] = ^(crc_in & 16'h6FB8) ^ ^(data_in & 64'h6FB8568975B3B310);
        c[10] = ^(crc_in & 16'hDF70) ^ ^(data_in & 64'hDF70AD12EB676620);
        c[11] = ^(crc_in & 16'hBEE1) ^ ^(data_in & 64'hBEE15A25D6CECC40);
        c[12] = ^(crc_in & 16'hF859) ^ ^(data_in & 64'hF859B040B1C58191);
        c[13] = ^(crc_in & 16'hF0B3) ^ ^(data_in & 64'hF0B36081638B0322);
        c[14] = ^(crc_in & 16'hE166) ^ ^(data_in & 64'hE166C102C7160644);
        c[15] = ^(crc_in & 16'hC2CD) ^ ^(data_in & 64'hC2CD82058E2C0C88);
        crc16_ccitt_step64 = c;
    endfunction

    logic             bist_running_q;
    logic [ROM_W-1:0] bist_addr_q;
    logic [15:0]      bist_crc_q;
    logic             bist_done_q;
    logic             bist_pass_q;
    logic [15:0]      bist_crc_next_w;

    assign bist_crc_next_w = crc16_ccitt_step64(bist_crc_q, bist_rom_data_i);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bist_running_q <= 1'b0;
            bist_addr_q    <= '0;
            bist_crc_q     <= 16'hFFFF;
            bist_done_q    <= 1'b0;
            bist_pass_q    <= 1'b0;
        end else if (bist_start_i) begin
            bist_running_q <= 1'b1;
            bist_addr_q    <= '0;
            bist_crc_q     <= 16'hFFFF;
            bist_done_q    <= 1'b0;
            bist_pass_q    <= 1'b0;
        end else if (bist_running_q) begin
            bist_crc_q <= bist_crc_next_w;
            if (bist_addr_q == ROM_W'(ROM_DEPTH - 1)) begin
                bist_running_q <= 1'b0;
                bist_done_q    <= 1'b1;
                bist_pass_q    <= (bist_crc_next_w == expected_crc16_i);
            end else begin
                bist_addr_q <= bist_addr_q + 1'b1;
            end
        end
    end

    assign bist_running_o  = bist_running_q;
    assign bist_rom_re_o   = bist_running_q;
    assign bist_rom_addr_o = bist_addr_q;
    assign bist_crc16_o    = bist_crc_q;
    assign bist_done_o     = bist_done_q;
    assign bist_pass_o     = bist_pass_q;

    // -------------------------------------------------------------------------
    // D. Transient L*di/dt Voltage-Droop Monitor & 1-Cycle Clock-Stretch
    // -------------------------------------------------------------------------
    logic [7:0] prev_mac_lanes_q;
    logic [3:0] stretch_cnt_q;
    logic       clk_stretch_en_q;
    logic       stretch_phase_q;
    logic [15:0] droop_event_cnt_q;
    logic       canary_droop_w;
    logic       didt_spike_w;
    logic       droop_trigger_w;

    assign canary_droop_w  = (canary_taps_i[5] == 1'b0);
    assign didt_spike_w    = ({1'b0, mac_active_lanes_i} >= ({1'b0, prev_mac_lanes_q} + 9'(DIDT_THRESH)));
    assign droop_trigger_w = canary_droop_w || didt_spike_w;
    logic _unused_canary_taps_w;
    assign _unused_canary_taps_w = &{1'b0, canary_taps_i[7:6], canary_taps_i[4:0]};

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            prev_mac_lanes_q  <= 8'd0;
            stretch_cnt_q     <= 4'd0;
            clk_stretch_en_q  <= 1'b0;
            stretch_phase_q   <= 1'b0;
            droop_event_cnt_q <= 16'd0;
        end else begin
            prev_mac_lanes_q <= mac_active_lanes_i;
            if (droop_trigger_w) begin
                clk_stretch_en_q  <= 1'b1;
                stretch_cnt_q     <= 4'(STRETCH_WINDOW - 1);
                stretch_phase_q   <= ~stretch_phase_q;
                droop_event_cnt_q <= droop_event_cnt_q + 16'd1;
            end else if (stretch_cnt_q != 4'd0) begin
                clk_stretch_en_q <= 1'b1;
                stretch_cnt_q    <= stretch_cnt_q - 4'd1;
                stretch_phase_q  <= ~stretch_phase_q;
            end else begin
                clk_stretch_en_q <= 1'b0;
                stretch_phase_q  <= 1'b0;
            end
        end
    end

    assign clk_stretch_en_o  = clk_stretch_en_q;
    assign gated_clk_en_o    = clk_stretch_en_q ? stretch_phase_q : 1'b1;
    assign droop_event_cnt_o = droop_event_cnt_q;

    // -------------------------------------------------------------------------
    // E. Formal Verification Properties (Yosys SAT Bounded Model Checking)
    // -------------------------------------------------------------------------
`ifdef FORMAL
    logic f_past_valid;
    initial f_past_valid = 1'b0;

    always_ff @(posedge clk) begin
        f_past_valid <= 1'b1;
    end

    always_comb begin
        if (!f_past_valid) begin
            assume (!rst_n);
        end else begin
            assume (rst_n);
        end
    end

    // Property 1: Zero active-traffic starvation (0% bandwidth stolen from LLM decode)
    always_comb begin
        if (active_sram_req_i) begin
            PROP_S18_ZERO_STARVATION: assert (!scrub_sram_re_o);
        end
    end

    always_ff @(posedge clk) begin
        if (f_past_valid && $past(rst_n) && rst_n) begin
            // Property 2: Every SBE detected during patrol scrub triggers atomic write-back
            // with valid SECDED codeword & increments sbe_scrubbed_cnt_o
            if ($past(scrub_sbe_detected)) begin
                PROP_S18_SBE_WB_WE:  assert (scrub_wb_we_o == 1'b1);
                PROP_S18_SBE_CNT:    assert (sbe_scrubbed_cnt_o == $past(sbe_scrubbed_cnt_o) + 32'd1);
                PROP_S18_SBE_CLEAN:  assert (scrub_wb_data_o[71:64] == secded_encode_72_64(scrub_wb_data_o[63:0]));
            end

            // Property 3: Every DBE detected asserts uncorrectable_dbe_irq_o and allocates
            // or maps a spare-row CAM repair entry when spare slots remain
            if ($past(scrub_dbe_detected)) begin
                PROP_S18_DBE_IRQ: assert (uncorrectable_dbe_irq_o == 1'b1);
                if ($past(cam_alloc_ptr_q) < (SPARE_W+1)'(SPARE_ROWS)) begin
                    PROP_S18_DBE_REMAP: assert (remap_valid_o == 1'b1);
                end
            end

            // Property 4: Voltage droop (canary_taps_i[5] == 1'b0) immediately asserts
            // clk_stretch_en_o on the very next clock cycle
            if ($past(canary_taps_i[5] == 1'b0)) begin
                PROP_S18_DROOP_1CYC_STRETCH: assert (clk_stretch_en_o == 1'b1);
            end

            // Property 5: BIST CRC-16 deterministic match/mismatch correctness upon completion
            if (bist_done_o && !$past(bist_start_i) && $past(bist_running_o)) begin
                PROP_S18_BIST_CRC_MATCH: assert (bist_pass_o == (bist_crc16_o == $past(expected_crc16_i)));
            end
        end
    end
`endif

endmodule
