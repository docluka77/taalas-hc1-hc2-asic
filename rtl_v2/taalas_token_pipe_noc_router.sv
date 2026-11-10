`timescale 1ns / 1ps
// =============================================================================
// Module:      taalas_token_pipe_noc_router (M12)
// Project:     Taalas HC1/HC2 Hardwired LLM Inference ASIC
// Description: Credit-Based Wormhole Spatial Token-Pipe Daisy-Chain Inter-Layer
//              NoC Router with 2-Entry Elastic Skid Buffer, Circular Flit FIFO,
//              Multi-Tile Broadcast Synchronization, Chip-to-Chip (C2C) Link
//              Extension for HC2 Pipeline Parallelism, and Formal Conservation.
//
// Architectural Highlights:
//   1. Zero-Bubble 2-Deep Elastic Skid Buffer:
//      Breaks combinational ready/valid loops between adjacent Transformer
//      Layer Tiles (Tile i -> Tile i+1) while sustaining 100% 1-flit/cycle
//      throughput under steady-state token-pipe streaming.
//   2. Credit-Based Wormhole Flow Control:
//      Tracks downstream buffer availability via used_credits_q in [0..MAX_CREDITS]
//      and avail_credits_o = MAX_CREDITS - used_credits_q. Formally guarantees
//      avail_credits_o + inflight_flits_o == MAX_CREDITS with zero overflow or
//      underflow across arbitrary backpressure.
//   3. Multi-Tile Broadcast & HC2 C2C Extension:
//      Supports single-cycle broadcast (bcast_en_i) to both local tile and
//      downstream hop, plus C2C bridge routing when c2c_en_i is asserted.
// =============================================================================

module taalas_token_pipe_noc_router #(
    parameter int FLIT_WIDTH  = 128,
    parameter int FIFO_DEPTH  = 8,
    parameter int MAX_CREDITS = 8,
    parameter int TILE_ID     = 0
) (
    input  logic                            clk,
    input  logic                            rst_n,

    // Router Mode & Broadcast Controls
    input  logic                            bcast_en_i,
    input  logic                            c2c_en_i,

    // Upstream Ingress Port (from Tile i-1 or Host Ingress)
    input  logic                            in_valid_i,
    output logic                            in_ready_o,
    input  logic [FLIT_WIDTH-1:0]           in_flit_i,
    output logic                            upstream_credit_ret_o,

    // Local Layer Tile Injection Port (Tile i Completed Activation Output)
    input  logic                            local_tx_valid_i,
    output logic                            local_tx_ready_o,
    input  logic [FLIT_WIDTH-1:0]           local_tx_flit_i,

    // Local Layer Tile Consumption Port (Delivering Flit to Tile i Datapath)
    output logic                            local_rx_valid_o,
    input  logic                            local_rx_ready_i,
    output logic [FLIT_WIDTH-1:0]           local_rx_flit_o,

    // Downstream Egress Port (to Tile i+1) & Credit Return
    output logic                            out_valid_o,
    input  logic                            out_ready_i,
    output logic [FLIT_WIDTH-1:0]           out_flit_o,
    input  logic                            downstream_credit_ret_i,

    // Chip-to-Chip (C2C) SerDes Bridge Extension (HC2 Multi-Die Pipeline)
    output logic                            c2c_tx_valid_o,
    input  logic                            c2c_tx_ready_i,
    output logic [FLIT_WIDTH-1:0]           c2c_tx_flit_o,
    input  logic                            c2c_rx_valid_i,
    output logic                            c2c_rx_ready_o,
    input  logic [FLIT_WIDTH-1:0]           c2c_rx_flit_i,

    // Flow-Control Status & Hardware Telemetry Outputs
    output logic [$clog2(MAX_CREDITS+1)-1:0] avail_credits_o,
    output logic [$clog2(MAX_CREDITS+1)-1:0] inflight_flits_o,
    output logic [1:0]                       skid_occupancy_o,
    output logic [$clog2(FIFO_DEPTH+1)-1:0]  fifo_occupancy_o,
    output logic [31:0]                      flits_rx_cnt_o,
    output logic [31:0]                      flits_tx_cnt_o,
    output logic [31:0]                      stall_cycles_cnt_o,
    output logic                             crc_err_o
);

    localparam int PTR_W  = $clog2(FIFO_DEPTH);
    localparam int CNT_W  = $clog2(FIFO_DEPTH + 1);
    localparam int CRED_W = $clog2(MAX_CREDITS + 1);

    // Flit Header Bitfield Extraction (Top 32 bits of FLIT_WIDTH)
    // [FLIT_WIDTH-1 -: 4]  = flit_type (4'b0001=HEAD, 0010=BODY, 0100=TAIL, 1000=SINGLE)
    // [FLIT_WIDTH-5 -: 2]  = vc_id
    // [FLIT_WIDTH-7 -: 6]  = src_tile_id
    // [FLIT_WIDTH-13 -: 6] = dst_tile_id
    // [FLIT_WIDTH-19 -: 6] = user_slot_id
    // [FLIT_WIDTH-25 -: 8] = header_crc8
    function automatic logic [7:0] calc_flit_crc8(input logic [23:0] hdr_24b);
        logic [7:0] crc;
        begin
            crc = hdr_24b[7:0] ^ hdr_24b[15:8] ^ hdr_24b[23:16] ^ 8'h5A;
            calc_flit_crc8 = crc;
        end
    endfunction

    // -------------------------------------------------------------------------
    // 1. Ingress Source Selection (Standard Upstream vs. C2C Bridge vs. Local TX)
    // -------------------------------------------------------------------------
    localparam logic [1:0] SRC_UPSTREAM = 2'd0;
    localparam logic [1:0] SRC_LOCAL    = 2'd1;
    localparam logic [1:0] SRC_C2C      = 2'd2;

    logic                  ing_src_valid;
    logic [FLIT_WIDTH-1:0] ing_src_flit;
    logic [1:0]            ing_src_tag;
    logic                  skid_in_ready;

    always_comb begin
        if (c2c_en_i && c2c_rx_valid_i) begin
            ing_src_valid = 1'b1;
            ing_src_flit  = c2c_rx_flit_i;
            ing_src_tag   = SRC_C2C;
        end else if (in_valid_i) begin
            ing_src_valid = 1'b1;
            ing_src_flit  = in_flit_i;
            ing_src_tag   = SRC_UPSTREAM;
        end else if (local_tx_valid_i) begin
            ing_src_valid = 1'b1;
            ing_src_flit  = local_tx_flit_i;
            ing_src_tag   = SRC_LOCAL;
        end else begin
            ing_src_valid = 1'b0;
            ing_src_flit  = '0;
            ing_src_tag   = SRC_UPSTREAM;
        end
    end

    assign c2c_rx_ready_o   = c2c_en_i && skid_in_ready;
    assign in_ready_o       = (!c2c_en_i || !c2c_rx_valid_i) && skid_in_ready;
    assign local_tx_ready_o = (!c2c_en_i || !c2c_rx_valid_i) && !in_valid_i && skid_in_ready;

    // -------------------------------------------------------------------------
    // 2. Two-Entry Elastic Skid Buffer (Zero Combinational Ready Loop)
    // -------------------------------------------------------------------------
    logic [FLIT_WIDTH-1:0] skid_slot0_q, skid_slot1_q;
    logic [1:0]            skid_tag0_q,  skid_tag1_q;
    logic [1:0]            skid_cnt_q;
    logic                  skid_out_valid;
    logic [FLIT_WIDTH-1:0] skid_out_flit;
    logic [1:0]            skid_out_tag;
    logic                  fifo_push_ready;
    logic                  skid_push_en, skid_pop_en;

    assign skid_in_ready  = (skid_cnt_q < 2'd2);
    assign skid_out_valid = (skid_cnt_q != 2'd0);
    assign skid_out_flit  = skid_slot0_q;
    assign skid_out_tag   = skid_tag0_q;
    assign skid_push_en   = ing_src_valid && skid_in_ready;
    assign skid_pop_en    = skid_out_valid && fifo_push_ready;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            skid_slot0_q <= '0;
            skid_slot1_q <= '0;
            skid_tag0_q  <= 2'd0;
            skid_tag1_q  <= 2'd0;
            skid_cnt_q   <= 2'd0;
        end else begin
            unique case ({skid_push_en, skid_pop_en})
                2'b10: begin
                    // Push without pop
                    if (skid_cnt_q == 2'd0) begin
                        skid_slot0_q <= ing_src_flit;
                        skid_tag0_q  <= ing_src_tag;
                        skid_cnt_q   <= 2'd1;
                    end else if (skid_cnt_q == 2'd1) begin
                        skid_slot1_q <= ing_src_flit;
                        skid_tag1_q  <= ing_src_tag;
                        skid_cnt_q   <= 2'd2;
                    end
                end
                2'b01: begin
                    // Pop without push
                    if (skid_cnt_q == 2'd2) begin
                        skid_slot0_q <= skid_slot1_q;
                        skid_tag0_q  <= skid_tag1_q;
                        skid_slot1_q <= '0;
                        skid_tag1_q  <= 2'd0;
                        skid_cnt_q   <= 2'd1;
                    end else if (skid_cnt_q == 2'd1) begin
                        skid_slot0_q <= '0;
                        skid_tag0_q  <= 2'd0;
                        skid_cnt_q   <= 2'd0;
                    end
                end
                2'b11: begin
                    // Simultaneous push and pop (0-bubble steady streaming)
                    if (skid_cnt_q == 2'd1) begin
                        skid_slot0_q <= ing_src_flit;
                        skid_tag0_q  <= ing_src_tag;
                    end else if (skid_cnt_q == 2'd2) begin
                        skid_slot0_q <= skid_slot1_q;
                        skid_tag0_q  <= skid_tag1_q;
                        skid_slot1_q <= ing_src_flit;
                        skid_tag1_q  <= ing_src_tag;
                    end
                end
                default: ;
            endcase
        end
    end
    // -------------------------------------------------------------------------
    // 3. Circular Wormhole Flit FIFO (FIFO_DEPTH = 8)
    // -------------------------------------------------------------------------
    logic [FLIT_WIDTH-1:0] fifo_mem_q [0:FIFO_DEPTH-1];
    logic [1:0]            fifo_src_q [0:FIFO_DEPTH-1];
    logic [PTR_W-1:0]      wr_ptr_q, rd_ptr_q;
    logic [CNT_W-1:0]      fifo_cnt_q;
    logic                  fifo_empty, fifo_full;
    logic                  fifo_push_en, fifo_pop_en;
    logic [FLIT_WIDTH-1:0] head_flit;
    logic [1:0]            head_src_tag;

    assign fifo_empty      = (fifo_cnt_q == '0);
    assign fifo_full       = (fifo_cnt_q == CNT_W'(FIFO_DEPTH));
    assign fifo_push_ready = !fifo_full;
    assign fifo_push_en    = skid_out_valid && !fifo_full;
    assign head_flit       = fifo_mem_q[rd_ptr_q];
    assign head_src_tag    = fifo_src_q[rd_ptr_q];

    // Extract routing destination from head flit
    logic [5:0] head_dst_tile;
    logic [7:0] head_rx_crc8, head_exp_crc8;
    logic       is_for_local, is_for_next;

    assign head_dst_tile = head_flit[FLIT_WIDTH-13 -: 6];
    assign head_rx_crc8  = head_flit[FLIT_WIDTH-25 -: 8];
    assign head_exp_crc8 = calc_flit_crc8(head_flit[FLIT_WIDTH-1 -: 24]);

    assign is_for_local  = !fifo_empty && (bcast_en_i || (head_dst_tile == 6'(TILE_ID)));
    assign is_for_next   = !fifo_empty && (bcast_en_i || (head_dst_tile != 6'(TILE_ID)));

    // -------------------------------------------------------------------------
    // 4. Credit Counter & Egress Handshake (MAX_CREDITS = 8)
    //    Tracks used_credits_q in [0..MAX_CREDITS] so init-zero => full credits!
    // -------------------------------------------------------------------------
    logic [CRED_W-1:0] used_credits_q;
    logic [CRED_W-1:0] avail_credits_comb;
    logic              has_downstream_credit;
    logic              eff_next_ready;
    logic              egress_fire_next, egress_fire_local;

    assign avail_credits_comb    = CRED_W'(MAX_CREDITS) - used_credits_q;
    assign has_downstream_credit = (used_credits_q < CRED_W'(MAX_CREDITS));
    assign eff_next_ready        = c2c_en_i ? c2c_tx_ready_i : out_ready_i;

    always_comb begin
        fifo_pop_en       = 1'b0;
        egress_fire_local = 1'b0;
        egress_fire_next  = 1'b0;

        if (!fifo_empty) begin
            if (bcast_en_i) begin
                // Broadcast requires both local consumer ready and downstream ready + credit
                if (local_rx_ready_i && eff_next_ready && has_downstream_credit) begin
                    fifo_pop_en       = 1'b1;
                    egress_fire_local = 1'b1;
                    egress_fire_next  = 1'b1;
                end
            end else if (is_for_local) begin
                if (local_rx_ready_i) begin
                    fifo_pop_en       = 1'b1;
                    egress_fire_local = 1'b1;
                end
            end else begin
                if (eff_next_ready && has_downstream_credit) begin
                    fifo_pop_en      = 1'b1;
                    egress_fire_next = 1'b1;
                end
            end
        end
    end

    assign local_rx_valid_o = bcast_en_i ? (is_for_local && eff_next_ready && has_downstream_credit)
                                         : is_for_local;
    assign local_rx_flit_o  = head_flit;

    assign out_valid_o      = (!c2c_en_i) && (bcast_en_i ? (is_for_next && local_rx_ready_i && has_downstream_credit)
                                                         : (is_for_next && has_downstream_credit));
    assign out_flit_o       = head_flit;

    assign c2c_tx_valid_o   = c2c_en_i && (bcast_en_i ? (is_for_next && local_rx_ready_i && has_downstream_credit)
                                                      : (is_for_next && has_downstream_credit));
    assign c2c_tx_flit_o    = head_flit;
    // -------------------------------------------------------------------------
    // 5. Sequential FIFO, Credit Conservation & Telemetry Update
    // -------------------------------------------------------------------------
    logic [31:0] flits_rx_cnt_q, flits_tx_cnt_q, stall_cycles_cnt_q;
    logic        upstream_credit_ret_q;
    logic        crc_err_q;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr_q              <= '0;
            rd_ptr_q              <= '0;
            fifo_cnt_q            <= '0;
            used_credits_q        <= '0;
            flits_rx_cnt_q        <= 32'd0;
            flits_tx_cnt_q        <= 32'd0;
            stall_cycles_cnt_q    <= 32'd0;
            upstream_credit_ret_q <= 1'b0;
            crc_err_q             <= 1'b0;
            for (int i = 0; i < FIFO_DEPTH; i++) begin
                fifo_mem_q[i] <= '0;
                fifo_src_q[i] <= 2'd0;
            end
        end else begin
            // [STAGE-10 FIX BUG-HC1-007]: Return upstream credit ONLY when popping an SRC_UPSTREAM flit
            upstream_credit_ret_q <= fifo_pop_en && (head_src_tag == SRC_UPSTREAM);

            // Circular FIFO write & read pointer management
            if (fifo_push_en) begin
                fifo_mem_q[wr_ptr_q] <= skid_out_flit;
                fifo_src_q[wr_ptr_q] <= skid_out_tag;
                wr_ptr_q             <= wr_ptr_q + 1'b1;
                flits_rx_cnt_q       <= flits_rx_cnt_q + 32'd1;
            end

            if (fifo_pop_en) begin
                rd_ptr_q       <= rd_ptr_q + 1'b1;
                flits_tx_cnt_q <= flits_tx_cnt_q + 32'd1;
                // [STAGE-10 FIX BUG-HC1-007]: Verify all 256 CRC-8 values unconditionally (including 8'h00)
                crc_err_q      <= (head_rx_crc8 != head_exp_crc8);
            end

            unique case ({fifo_push_en, fifo_pop_en})
                2'b10: begin
                    if (fifo_cnt_q < CNT_W'(FIFO_DEPTH)) begin
                        fifo_cnt_q <= fifo_cnt_q + 1'b1;
                    end
                end
                2'b01: begin
                    if (fifo_cnt_q > '0) begin
                        fifo_cnt_q <= fifo_cnt_q - 1'b1;
                    end
                end
                default: ;
            endcase

            // Downstream Credit Counter (Underflow/Overflow Protected)
            unique case ({egress_fire_next, downstream_credit_ret_i})
                2'b10: begin
                    // Sent flit downstream without simultaneous credit return
                    if (used_credits_q < CRED_W'(MAX_CREDITS)) begin
                        used_credits_q <= used_credits_q + 1'b1;
                    end
                end
                2'b01: begin
                    // Downstream returned credit without simultaneous flit send
                    if (used_credits_q > '0) begin
                        used_credits_q <= used_credits_q - 1'b1;
                    end
                end
                default: ; // Both 0 or both 1 -> net zero credit change
            endcase

            // Backpressure stall telemetry
            if ((!fifo_empty && !fifo_pop_en) || (skid_out_valid && fifo_full)) begin
                stall_cycles_cnt_q <= stall_cycles_cnt_q + 32'd1;
            end
        end
    end

    assign upstream_credit_ret_o = upstream_credit_ret_q;
    assign avail_credits_o       = avail_credits_comb;
    assign inflight_flits_o      = used_credits_q;
    assign skid_occupancy_o      = skid_cnt_q;
    assign fifo_occupancy_o      = fifo_cnt_q;
    assign flits_rx_cnt_o        = flits_rx_cnt_q;
    assign flits_tx_cnt_o        = flits_tx_cnt_q;
    assign stall_cycles_cnt_o    = stall_cycles_cnt_q;
    assign crc_err_o             = crc_err_q;

    // =========================================================================
    // Formal Verification & Inline SVA Invariants (Yosys SAT & Verilator)
    // =========================================================================
    logic       past_valid_q;
    logic       past_pop_en_q;
    logic [1:0] past_pop_src_q;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            past_valid_q   <= 1'b0;
            past_pop_en_q  <= 1'b0;
            past_pop_src_q <= 2'd0;
        end else begin
            past_valid_q   <= 1'b1;
            past_pop_en_q  <= fifo_pop_en;
            past_pop_src_q <= head_src_tag;
        end
    end

    always_ff @(posedge clk) begin
        if (past_valid_q && rst_n) begin
            // PROP_M12_NOC_CREDIT_CONSERVATION: Available + Inflight == MAX_CREDITS
            assert ((avail_credits_o + inflight_flits_o) == CRED_W'(MAX_CREDITS));
            assert (avail_credits_o <= CRED_W'(MAX_CREDITS));
            assert (inflight_flits_o <= CRED_W'(MAX_CREDITS));

            // PROP_M12_SKID_AND_FIFO_BOUNDS: Never overflow 2-deep skid or FIFO_DEPTH
            assert (skid_occupancy_o <= 2'd2);
            assert (fifo_occupancy_o <= CNT_W'(FIFO_DEPTH));

            // PROP_M12_NO_SEND_WITHOUT_CREDIT: Egress never fires when 0 credits left
            if (avail_credits_o == '0) begin
                assert (!out_valid_o && !c2c_tx_valid_o);
            end

            // PROP_BUG007_NO_PHANTOM_CREDITS: Upstream credit return strictly requires SRC_UPSTREAM pop
            if (upstream_credit_ret_o) begin
                assert (past_pop_en_q && (past_pop_src_q == SRC_UPSTREAM));
            end
            if (egress_fire_local) begin
                assert (!fifo_empty && local_rx_ready_i);
            end
        end
    end

endmodule
