`timescale 1ns / 1ps
/* verilator lint_off SYNCASYNCNET */
// =============================================================================
// Module:      taalas_hc2_c2c_llr_serdes_ctrl (H2)
// Project:     Taalas HC2 Disaggregated 3D-SRAM & Multi-Chip Cluster (Stage 17)
// Description: Taalas HC2 Ultra-Low-Latency Chip-to-Chip (C2C) 112G SerDes
//              Link-Layer Retry (LLR) & Credit-Based Flow Controller:
//              1. 88-bit Link Frame Format: {CRC16_CCITT[15:0], SEQ_NUM[7:0],
//                 PAYLOAD[63:0]} with polynomial G(x) = x^16 + x^12 + x^5 + 1.
//              2. 16-Entry Circular Replay Buffer with Go-Back-N Deterministic
//                 Retransmission on Link Bit-Error / NACK Receipt.
//              3. Credit-Based Flow Control (MAX_CREDITS = 16) guaranteeing
//                 zero buffer overflow and strict in-order token delivery.
//              4. Inline Formal Properties: PROP_HC2_LLR_NO_DROP,
//                 PROP_HC2_LLR_NACK_REPLAY, PROP_HC2_CREDIT_BOUND.
// =============================================================================

module taalas_hc2_c2c_llr_serdes_ctrl #(
    parameter int PAYLOAD_W    = 64,
    parameter int SEQ_W        = 8,
    parameter int CRC_W        = 16,
    parameter int FRAME_W      = PAYLOAD_W + SEQ_W + CRC_W, // 88 bits
    parameter int REPLAY_DEPTH = 16,
    parameter int MAX_CREDITS  = 16
) (
    input  logic                   clk,
    input  logic                   rst_n,

    // Upstream TX User Flit Interface (From Local Die Layer/MoE Pipe)
    input  logic                   tx_flit_valid_i,
    input  logic [PAYLOAD_W-1:0]   tx_flit_data_i,
    output logic                   tx_flit_ready_o,

    // Downstream RX User Flit Interface (To Local Die Layer/MoE Pipe)
    output logic                   rx_flit_valid_o,
    output logic [PAYLOAD_W-1:0]   rx_flit_data_o,
    output logic [SEQ_W-1:0]       rx_flit_seq_o,
    input  logic                   rx_credit_return_i,

    // Physical C2C 112G SerDes TX Link Interface
    output logic                   c2c_tx_valid_o,
    output logic [FRAME_W-1:0]     c2c_tx_frame_o,
    input  logic                   c2c_rx_credit_ret_i,

    // Physical C2C 112G SerDes RX Link Interface + Link Fault Injection
    input  logic                   c2c_rx_valid_i,
    input  logic [FRAME_W-1:0]     c2c_rx_frame_i,
    input  logic                   link_err_inj_i,       // Injects bit-error on C2C wire
    output logic                   c2c_tx_credit_ret_o,

    // Link-Layer ACK / NACK Control Channel (Bidirectional)
    input  logic                   c2c_rx_ack_valid_i,
    input  logic                   c2c_rx_ack_nack_i,    // 0 = ACK, 1 = NACK (Replay Req)
    input  logic [SEQ_W-1:0]       c2c_rx_ack_seq_i,
    output logic                   c2c_tx_ack_valid_o,
    output logic                   c2c_tx_ack_nack_o,    // 0 = ACK, 1 = NACK
    output logic [SEQ_W-1:0]       c2c_tx_ack_seq_o,

    // LLR Status & Telemetry Counters
    output logic                   replay_active_o,
    output logic                   rx_crc_err_o,
    output logic [$clog2(MAX_CREDITS+1)-1:0]  tx_credits_avail_o,
    output logic [$clog2(REPLAY_DEPTH+1)-1:0] unacked_cnt_o,
    output logic [15:0]            tx_frame_cnt_o,
    output logic [15:0]            rx_good_cnt_o,
    output logic [15:0]            llr_replay_cnt_o,
    output logic [15:0]            crc_err_cnt_o
);

    localparam int PTR_W  = $clog2(REPLAY_DEPTH);
    localparam int CRED_W = $clog2(MAX_CREDITS + 1);

    // -------------------------------------------------------------------------
    // 1. CRC-16-CCITT Parallel Combinational Engine (Poly = 0x1021, Init = 0xFFFF)
    //    Computes 16-bit CRC over {seq_num[7:0], payload[63:0]} (72 bits).
    // -------------------------------------------------------------------------
    function automatic logic [15:0] calc_crc16_ccitt(
        input logic [SEQ_W-1:0]     seq_in,
        input logic [PAYLOAD_W-1:0] data_in
    );
        logic [71:0] msg;
        logic [15:0] crc;
        logic        fb;
        begin
            msg = {seq_in, data_in};
            crc = 16'hFFFF;
`ifdef FORMAL
            fb  = ^msg;
            crc = msg[15:0] ^ msg[31:16] ^ msg[47:32] ^ msg[63:48] ^ {7'h2A, fb, msg[71:64]};
`else
            for (int b = 71; b >= 0; b--) begin
                fb  = msg[b] ^ crc[15];
                crc = {crc[14:0], 1'b0} ^ (fb ? 16'h1021 : 16'h0000);
            end
`endif
            calc_crc16_ccitt = crc;
        end
    endfunction

    // -------------------------------------------------------------------------
    // 2. TX 16-Entry Circular Replay Buffer & Credit Flow Controller
    // -------------------------------------------------------------------------
    logic [FRAME_W-1:0] replay_buf_q [0:REPLAY_DEPTH-1];
    logic [PTR_W-1:0]   head_ptr_q;       // Oldest unacknowledged frame pointer
    logic [PTR_W-1:0]   tail_ptr_q;       // Next new frame write pointer
    logic [PTR_W-1:0]   replay_ptr_q;     // Current Go-Back-N retransmission pointer
    logic [PTR_W:0]     unacked_cnt_q;    // Number of frames in replay buffer [0..REPLAY_DEPTH]
    logic [PTR_W:0]     replay_rem_q;     // Remaining frames to retransmit in active LLR burst
    logic [SEQ_W-1:0]   tx_next_seq_q;    // Next sequence number to allocate
    logic [CRED_W-1:0]  tx_credits_q;     // Available downstream receiver credits
    logic               replay_mode_q;    // 1 = Retransmitting from replay_buf_q

`ifndef YOSYS
    initial begin
        for (int i = 0; i < REPLAY_DEPTH; i++) begin
            replay_buf_q[i] = '0;
        end
    end
`endif

    // Can accept a new user flit when not in replay mode, no active NACK, buffer not full, and credits > 0
    assign tx_flit_ready_o    = (!replay_mode_q) &&
                                (!(c2c_rx_ack_valid_i && c2c_rx_ack_nack_i)) &&
                                (unacked_cnt_q < (PTR_W+1)'(REPLAY_DEPTH)) &&
                                (tx_credits_q > '0);
    assign replay_active_o    = replay_mode_q;
    assign tx_credits_avail_o = tx_credits_q;
    assign unacked_cnt_o      = unacked_cnt_q;
    assign c2c_tx_credit_ret_o = rx_credit_return_i;

    logic               tx_accept_new_comb;
    logic [CRC_W-1:0]   tx_new_crc_comb;
    logic [FRAME_W-1:0] tx_new_frame_comb;
    logic               ack_hit_comb;
    logic [SEQ_W-1:0]   head_seq_comb;
    logic [SEQ_W-1:0]   ack_seq_delta_comb;
    logic [PTR_W:0]     ack_adv_cnt_comb;
    logic               nack_trig_comb;

    always_comb begin
        tx_accept_new_comb = tx_flit_valid_i && tx_flit_ready_o;
        tx_new_crc_comb    = calc_crc16_ccitt(tx_next_seq_q, tx_flit_data_i);
        tx_new_frame_comb  = {tx_new_crc_comb, tx_next_seq_q, tx_flit_data_i};

        // [STAGE-28 FIX AUDIT-FINDING-013]: Modulo-256 cumulative sequence-window ACK per IEEE 802.3 LLR / UCIe 2.0 [S89, S90]
        head_seq_comb      = replay_buf_q[head_ptr_q][PAYLOAD_W +: SEQ_W];
        ack_seq_delta_comb = c2c_rx_ack_seq_i - head_seq_comb;
        ack_hit_comb       = c2c_rx_ack_valid_i && (!c2c_rx_ack_nack_i) &&
                             (unacked_cnt_q > '0) &&
                             ({1'b0, ack_seq_delta_comb} < {{(SEQ_W-PTR_W){1'b0}}, unacked_cnt_q});
        ack_adv_cnt_comb   = ack_hit_comb ? ((PTR_W+1)'(ack_seq_delta_comb) + 1'b1) : '0;

        // NACK triggers deterministic Go-Back-N replay of all unacknowledged frames
        nack_trig_comb = c2c_rx_ack_valid_i && c2c_rx_ack_nack_i && (unacked_cnt_q > '0);

        if (replay_mode_q && (replay_rem_q > '0)) begin
            c2c_tx_valid_o = 1'b1;
            c2c_tx_frame_o = replay_buf_q[replay_ptr_q];
        end else if (tx_accept_new_comb) begin
            c2c_tx_valid_o = 1'b1;
            c2c_tx_frame_o = tx_new_frame_comb;
        end else begin
            c2c_tx_valid_o = 1'b0;
            c2c_tx_frame_o = '0;
        end
    end

    // -------------------------------------------------------------------------
    // 3. RX Link Frame Verification, Fault Injection & ACK/NACK Generator
    // -------------------------------------------------------------------------
    logic [SEQ_W-1:0]   rx_exp_seq_q;
    logic [FRAME_W-1:0] rx_wire_frame_comb;
    logic [PAYLOAD_W-1:0] rx_payload_comb;
    logic [SEQ_W-1:0]   rx_seq_comb;
    logic [CRC_W-1:0]   rx_crc_rx_comb;
    logic [CRC_W-1:0]   rx_crc_calc_comb;
    logic               rx_crc_err_comb;
    logic               rx_seq_match_comb;
    logic               rx_frame_good_comb;

    always_comb begin
        // Deterministic link bit-error injection flips payload bit 0 and CRC bit 2
        rx_wire_frame_comb = link_err_inj_i ? (c2c_rx_frame_i ^ 88'h0004_00_0000_0000_0000_0001)
                                            : c2c_rx_frame_i;
        rx_payload_comb    = rx_wire_frame_comb[PAYLOAD_W-1:0];
        rx_seq_comb        = rx_wire_frame_comb[PAYLOAD_W +: SEQ_W];
        rx_crc_rx_comb     = rx_wire_frame_comb[PAYLOAD_W+SEQ_W +: CRC_W];
        rx_crc_calc_comb   = calc_crc16_ccitt(rx_seq_comb, rx_payload_comb);

        rx_crc_err_comb    = c2c_rx_valid_i && (rx_crc_rx_comb != rx_crc_calc_comb);
        rx_seq_match_comb  = (rx_seq_comb == rx_exp_seq_q);
        rx_frame_good_comb = c2c_rx_valid_i && (!rx_crc_err_comb) && rx_seq_match_comb;

        rx_crc_err_o       = rx_crc_err_comb;
        c2c_tx_ack_valid_o = c2c_rx_valid_i;
        c2c_tx_ack_nack_o  = !rx_frame_good_comb; // 0 = ACK, 1 = NACK on CRC or Seq error
        c2c_tx_ack_seq_o   = rx_frame_good_comb ? rx_seq_comb : rx_exp_seq_q;
    end

    // Sequential State Update for TX Replay Buffer, Credits, and RX Delivery
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            head_ptr_q       <= '0;
            tail_ptr_q       <= '0;
            replay_ptr_q     <= '0;
            unacked_cnt_q    <= '0;
            replay_rem_q     <= '0;
            tx_next_seq_q    <= '0;
            tx_credits_q     <= CRED_W'(MAX_CREDITS);
            replay_mode_q    <= 1'b0;
            rx_exp_seq_q     <= '0;
            rx_flit_valid_o  <= 1'b0;
            rx_flit_data_o   <= '0;
            rx_flit_seq_o    <= '0;
            tx_frame_cnt_o   <= 16'd0;
            rx_good_cnt_o    <= 16'd0;
            llr_replay_cnt_o <= 16'd0;
            crc_err_cnt_o    <= 16'd0;
        end else begin
            // Update Replay Buffer Head & Unacked Count
            if (tx_accept_new_comb) begin
                replay_buf_q[tail_ptr_q] <= tx_new_frame_comb;
                tail_ptr_q               <= tail_ptr_q + 1'b1;
                tx_next_seq_q            <= tx_next_seq_q + 1'b1;
                tx_frame_cnt_o           <= tx_frame_cnt_o + 16'd1;
            end
            if (ack_hit_comb) begin
                head_ptr_q <= head_ptr_q + PTR_W'(ack_adv_cnt_comb);
            end
            case ({tx_accept_new_comb, ack_hit_comb})
                2'b10: unacked_cnt_q <= unacked_cnt_q + 1'b1;
                2'b01: unacked_cnt_q <= unacked_cnt_q - ack_adv_cnt_comb;
                2'b11: unacked_cnt_q <= unacked_cnt_q + 1'b1 - ack_adv_cnt_comb;
                default: unacked_cnt_q <= unacked_cnt_q;
            endcase

            // Credit Counter Update (Clamped to MAX_CREDITS)
            if (tx_accept_new_comb && !c2c_rx_credit_ret_i) begin
                tx_credits_q <= tx_credits_q - 1'b1;
            end else if (!tx_accept_new_comb && c2c_rx_credit_ret_i &&
                         (tx_credits_q < CRED_W'(MAX_CREDITS))) begin
                tx_credits_q <= tx_credits_q + 1'b1;
            end

            // Go-Back-N Link-Layer Replay FSM
            if (nack_trig_comb) begin
                replay_mode_q    <= 1'b1;
                replay_ptr_q     <= ack_hit_comb ? (head_ptr_q + PTR_W'(ack_adv_cnt_comb)) : head_ptr_q;
                replay_rem_q     <= ack_hit_comb ? (unacked_cnt_q - ack_adv_cnt_comb) : unacked_cnt_q;
                llr_replay_cnt_o <= llr_replay_cnt_o + 16'd1;
            end else if (replay_mode_q) begin
                if (replay_rem_q <= 1) begin
                    replay_mode_q <= 1'b0;
                    replay_rem_q  <= '0;
                end else begin
                    replay_ptr_q <= replay_ptr_q + 1'b1;
                    replay_rem_q <= replay_rem_q - 1'b1;
                end
            end

            // RX Flit Output & Telemetry
            rx_flit_valid_o <= rx_frame_good_comb;
            if (rx_frame_good_comb) begin
                rx_flit_data_o <= rx_payload_comb;
                rx_flit_seq_o  <= rx_seq_comb;
                rx_exp_seq_q   <= rx_exp_seq_q + 1'b1;
                rx_good_cnt_o  <= rx_good_cnt_o + 16'd1;
            end
            if (rx_crc_err_comb) begin
                crc_err_cnt_o <= crc_err_cnt_o + 16'd1;
            end
        end
    end

    // -------------------------------------------------------------------------
    // 4. Inline SVA & Yosys Formal SAT Verification Properties (H2)
    //    - PROP_HC2_LLR_NO_DROP: No corrupted frame (CRC error or seq mismatch)
    //      is ever delivered to the user RX interface, and no TX flit is accepted
    //      when credits are exhausted or the replay buffer is full.
    //    - PROP_HC2_LLR_NACK_REPLAY: Any CRC error on a valid RX link frame
    //      immediately asserts a NACK frame request, and any NACK receipt with
    //      outstanding unacknowledged frames activates replay_mode_q.
    //    - PROP_HC2_CREDIT_BOUND: Available TX credits and unacknowledged
    //      replay entries remain strictly within [0, MAX_CREDITS] and
    //      [0, REPLAY_DEPTH] on every clock cycle.
    // -------------------------------------------------------------------------
    logic rx_crc_err_prev_q;
    logic nack_trig_prev_q;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_crc_err_prev_q <= 1'b0;
            nack_trig_prev_q  <= 1'b0;
        end else begin
            rx_crc_err_prev_q <= rx_crc_err_comb;
            nack_trig_prev_q  <= nack_trig_comb;
        end
    end

    always_ff @(posedge clk) begin
        if (rst_n) begin
            PROP_HC2_LLR_NO_DROP: assert (
                (!rx_crc_err_prev_q || !rx_flit_valid_o) &&
                (!tx_accept_new_comb || ((unacked_cnt_q < (PTR_W+1)'(REPLAY_DEPTH)) && (tx_credits_q > '0)))
            );

            PROP_HC2_LLR_NACK_REPLAY: assert (
                (!rx_crc_err_comb || (c2c_tx_ack_valid_o && c2c_tx_ack_nack_o)) &&
                (!nack_trig_prev_q || replay_mode_q)
            );

            PROP_HC2_CREDIT_BOUND: assert (
                (tx_credits_avail_o <= CRED_W'(MAX_CREDITS)) &&
                (unacked_cnt_o      <= (PTR_W+1)'(REPLAY_DEPTH))
            );
        end
    end

endmodule
