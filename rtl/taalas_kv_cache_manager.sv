// =============================================================================
// Module:      taalas_kv_cache_manager (M6)
// Project:     Taalas HC1/HC2 Hardwired LLM Inference ASIC
// Description: Grouped-Query Attention (GQA 4:1: 32 Query Heads sharing 8 KV
//              Heads) On-Die SRAM KV-Cache Controller featuring:
//              1. Multi-User Context Slot Allocation (MAX_USERS=8) with Circular
//                 Ring-Buffer Pointers (wr_ptr, rd_ptr, seq_len_cnt)
//              2. StreamingLLM / Attention-Sink Sliding-Window Eviction Policy
//              3. INT4/FP4 Asymmetric KV Compression & Dynamic Scale Dequantizer
//              4. 1-to-GQA_RATIO (4:1) Simultaneous Broadcast Hold Register
// =============================================================================

`timescale 1ns / 1ps

module taalas_kv_cache_manager #(
    parameter int MAX_USERS    = 8,
    parameter int MAX_SEQ_LEN  = 32,
    parameter int NUM_KV_HEADS = 8,
    parameter int GQA_RATIO    = 4,
    parameter int HEAD_DIM     = 16
) (
    input  logic                                    clk,
    input  logic                                    rst_n,

    // Context Slot & Operation Command Interface
    input  logic [$clog2(MAX_USERS)-1:0]            slot_id_i,
    input  logic [$clog2(NUM_KV_HEADS)-1:0]         kv_head_id_i,
    input  logic                                    append_en_i,
    input  logic                                    read_seq_en_i,
    input  logic                                    clear_slot_i,
    input  logic                                    sliding_win_en_i,
    input  logic [3:0]                              sink_tokens_cfg_i,

    // Incoming Compressed INT4/FP4 KV Vector & Dynamic Scale/Zero-Point Metadata
    input  logic [HEAD_DIM*4-1:0]                   k_vec_in_i,
    input  logic [HEAD_DIM*4-1:0]                   v_vec_in_i,
    input  logic [15:0]                             k_scale_in_i,
    input  logic [15:0]                             v_scale_in_i,
    input  logic [3:0]                              k_zp_in_i,
    input  logic [3:0]                              v_zp_in_i,

    // On-Die 16-Bank 6T SRAM Macro (M5) Command Interface
    output logic                                    sram_req_valid_o,
    output logic                                    sram_req_we_o,
    output logic [3:0]                              sram_req_bank_o,
    output logic [9:0]                              sram_req_row_o,
    output logic [63:0]                             sram_req_wdata_o,

    // Dequantized INT8 KV & 4:1 GQA Broadcast Outputs to Flash-Decode (M9)
    output logic [HEAD_DIM*8-1:0]                   k_dequant_o,
    output logic [HEAD_DIM*8-1:0]                   v_dequant_o,
    output logic [GQA_RATIO*HEAD_DIM*8-1:0]         gqa_k_bcast_o,
    output logic [GQA_RATIO*HEAD_DIM*8-1:0]         gqa_v_bcast_o,

    // Ring-Buffer Pointer & Streaming Status Telemetry
    output logic [$clog2(MAX_SEQ_LEN)-1:0]          wr_ptr_o,
    output logic [$clog2(MAX_SEQ_LEN)-1:0]          rd_ptr_o,
    output logic [11:0]                             seq_pos_o,
    output logic [12:0]                             curr_seq_len_o,
    output logic [MAX_USERS-1:0]                    slot_active_mask_o,
    output logic [15:0]                             eviction_cnt_o,
    output logic                                    kv_valid_o,
    output logic                                    kv_last_o,
    output logic                                    seq_done_o,
    output logic [2:0]                              fsm_state_o
);

    localparam int SLOT_W = $clog2(MAX_USERS);
    localparam int HEAD_W = $clog2(NUM_KV_HEADS);
    localparam int PTR_W  = $clog2(MAX_SEQ_LEN);
    localparam int LEN_W  = $clog2(MAX_SEQ_LEN + 1);

    // -------------------------------------------------------------------------
    // FSM State Encoding (Aligned with Stage 2 Section 6.1 Table)
    // -------------------------------------------------------------------------
    typedef enum logic [2:0] {
        ST_IDLE        = 3'b000,
        ST_WRITE_K     = 3'b001,
        ST_WRITE_V     = 3'b010,
        ST_READ_STREAM = 3'b011,
        ST_CLEAR_SLOT  = 3'b100,
        ST_DONE        = 3'b101
    } kv_fsm_e;

    kv_fsm_e              state_q, state_d;
    logic [SLOT_W-1:0]    act_slot_q, act_slot_d;
    logic [HEAD_W-1:0]    act_head_q, act_head_d;
    logic                 read_after_wr_q, read_after_wr_d;
    logic [PTR_W-1:0]     rd_idx_q, rd_idx_d;

    // Per-User-Slot Ring-Buffer Pointers & Sequence Length Counters
    logic [PTR_W-1:0]     wr_ptr_q   [0:MAX_USERS-1];
    logic [LEN_W-1:0]     seq_len_q  [0:MAX_USERS-1];
    logic [MAX_USERS-1:0] slot_active_q;
    logic [15:0]          eviction_cnt_q;

    // -------------------------------------------------------------------------
    // Compressed INT4 KV Storage & Per-Token Scale / Zero-Point Metadata Arrays
    // Indexed by {slot_id, pos} for clean synthesis and cycle-accurate streaming
    // -------------------------------------------------------------------------
    localparam int TOTAL_ENTRIES = MAX_USERS * MAX_SEQ_LEN;

    logic [HEAD_DIM*4-1:0] k_q4_mem     [0:TOTAL_ENTRIES-1];
    logic [HEAD_DIM*4-1:0] v_q4_mem     [0:TOTAL_ENTRIES-1];
    logic [15:0]           k_scale_mem  [0:TOTAL_ENTRIES-1];
    logic [15:0]           v_scale_mem  [0:TOTAL_ENTRIES-1];
    logic [3:0]            k_zp_mem     [0:TOTAL_ENTRIES-1];
    logic [3:0]            v_zp_mem     [0:TOTAL_ENTRIES-1];

    // Latch incoming vectors at start of append transaction
    logic [HEAD_DIM*4-1:0] lat_k_vec_q,   lat_v_vec_q;
    logic [15:0]           lat_k_scale_q, lat_v_scale_q;
    logic [3:0]            lat_k_zp_q,    lat_v_zp_q;

    // -------------------------------------------------------------------------
    // Hardware INT4 Asymmetric Dequantizer:
    //   deq_int8[i] = clamp_s8( ((q4[i] - zp) * scale_q4_4) >>> 4 )
    // -------------------------------------------------------------------------
    function automatic logic signed [7:0] dequant_elem_int4(
        input logic [3:0]  q4_val,
        input logic [3:0]  zp_val,
        input logic [15:0] scale_val
    );
        logic signed [5:0]  diff_s6;
        logic signed [15:0] scale_s16;
        logic signed [21:0] prod_s22;
        logic signed [21:0] shifted_s22;
        logic signed [7:0]  res_s8;

        diff_s6     = $signed({2'b00, q4_val}) - $signed({2'b00, zp_val});
        scale_s16   = $signed((scale_val == 16'd0) ? 16'd16 : scale_val);
        prod_s22    = diff_s6 * scale_s16;
        shifted_s22 = (prod_s22 + 22'sd8) >>> 4;

        if (shifted_s22 > 22'sd127)       res_s8 = 8'sd127;
        else if (shifted_s22 < -22'sd128) res_s8 = -8'sd128;
        else                              res_s8 = shifted_s22[7:0];
        dequant_elem_int4 = res_s8;
    endfunction

    function automatic logic [HEAD_DIM*8-1:0] dequant_vec_int4(
        input logic [HEAD_DIM*4-1:0] vec_q4,
        input logic [3:0]            zp_val,
        input logic [15:0]           scale_val
    );
        logic [HEAD_DIM*8-1:0] out_vec;
        for (int d = 0; d < HEAD_DIM; d++) begin
            out_vec[d*8 +: 8] = dequant_elem_int4(vec_q4[d*4 +: 4], zp_val, scale_val);
        end
        dequant_vec_int4 = out_vec;
    endfunction

    // -------------------------------------------------------------------------
    // Ring-Buffer Next Write Pointer with Attention-Sink Sliding-Window Eviction
    // -------------------------------------------------------------------------
    localparam logic [PTR_W-1:0] LAST_SEQ_PTR = MAX_SEQ_LEN[PTR_W-1:0] - 1'b1;
    localparam logic [LEN_W-1:0] FULL_SEQ_LEN = MAX_SEQ_LEN[LEN_W-1:0];

    logic [PTR_W-1:0] sink_ptr_comb;
    generate
        if (PTR_W > 4) begin : gen_sink_pad
            assign sink_ptr_comb = {{(PTR_W-4){1'b0}}, sink_tokens_cfg_i};
        end else begin : gen_sink_slice
            assign sink_ptr_comb = sink_tokens_cfg_i[PTR_W-1:0];
        end
    endgenerate

    function automatic logic [PTR_W-1:0] calc_next_wr_ptr(
        input logic [PTR_W-1:0] cur_ptr,
        input logic [LEN_W-1:0] cur_len,
        input logic             slide_en,
        input logic [PTR_W-1:0] sink_ptr
    );
        logic [PTR_W-1:0] safe_sink;
        safe_sink = ({1'b0, sink_ptr} < {1'b0, LAST_SEQ_PTR}) ? sink_ptr : '0;
        if (cur_ptr == LAST_SEQ_PTR) begin
            if (slide_en && ((cur_len + 1'b1) >= FULL_SEQ_LEN)) begin
                // Preserve attention sink tokens [0 .. safe_sink-1]
                calc_next_wr_ptr = safe_sink;
            end else begin
                calc_next_wr_ptr = '0;
            end
        end else begin
            calc_next_wr_ptr = cur_ptr + 1'b1;
        end
    endfunction

    // -------------------------------------------------------------------------
    // Combinational FSM Next-State & SRAM Command Generation
    // -------------------------------------------------------------------------
    logic [$clog2(TOTAL_ENTRIES)-1:0] wr_mem_idx;
    logic [$clog2(TOTAL_ENTRIES)-1:0] rd_mem_idx;
    logic [PTR_W-1:0]                 cur_slot_wr_ptr;
    logic [LEN_W-1:0]                 cur_slot_seq_len;

    assign cur_slot_wr_ptr  = wr_ptr_q[act_slot_q];
    assign cur_slot_seq_len = seq_len_q[act_slot_q];
    assign wr_mem_idx       = {act_slot_q, cur_slot_wr_ptr};
    assign rd_mem_idx       = {act_slot_q, rd_idx_q};

    always_comb begin
        state_d          = state_q;
        act_slot_d       = act_slot_q;
        act_head_d       = act_head_q;
        read_after_wr_d  = read_after_wr_q;
        rd_idx_d         = rd_idx_q;

        sram_req_valid_o = 1'b0;
        sram_req_we_o    = 1'b0;
        sram_req_bank_o  = 4'd0;
        sram_req_row_o   = 10'd0;
        sram_req_wdata_o = 64'd0;

        case (state_q)
            ST_IDLE: begin
                if (clear_slot_i) begin
                    act_slot_d = slot_id_i;
                    state_d    = ST_CLEAR_SLOT;
                end else if (append_en_i) begin
                    act_slot_d      = slot_id_i;
                    act_head_d      = kv_head_id_i;
                    read_after_wr_d = read_seq_en_i;
                    state_d         = ST_WRITE_K;
                end else if (read_seq_en_i) begin
                    act_slot_d = slot_id_i;
                    act_head_d = kv_head_id_i;
                    rd_idx_d   = '0;
                    if (seq_len_q[slot_id_i] != '0) begin
                        state_d = ST_READ_STREAM;
                    end else begin
                        state_d = ST_DONE;
                    end
                end
            end

            ST_WRITE_K: begin
                // Issue K-vector write to even SRAM bank (2 * kv_head)
                sram_req_valid_o = 1'b1;
                sram_req_we_o    = 1'b1;
                sram_req_bank_o  = {act_head_q, 1'b0};
                sram_req_row_o   = {{(10-SLOT_W-PTR_W){1'b0}}, act_slot_q, cur_slot_wr_ptr};
                sram_req_wdata_o = {{(64-HEAD_DIM*4){1'b0}}, lat_k_vec_q};
                state_d          = ST_WRITE_V;
            end

            ST_WRITE_V: begin
                // Issue V-vector write to odd SRAM bank (2 * kv_head + 1)
                sram_req_valid_o = 1'b1;
                sram_req_we_o    = 1'b1;
                sram_req_bank_o  = {act_head_q, 1'b1};
                sram_req_row_o   = {{(10-SLOT_W-PTR_W){1'b0}}, act_slot_q, cur_slot_wr_ptr};
                sram_req_wdata_o = {{(64-HEAD_DIM*4){1'b0}}, lat_v_vec_q};
                rd_idx_d         = '0;
                if (read_after_wr_q) begin
                    state_d = ST_READ_STREAM;
                end else begin
                    state_d = ST_DONE;
                end
            end

            ST_READ_STREAM: begin
                // Issue streaming read from SRAM bank while dequantizing & broadcasting
                sram_req_valid_o = 1'b1;
                sram_req_we_o    = 1'b0;
                sram_req_bank_o  = {act_head_q, 1'b0};
                sram_req_row_o   = {{(10-SLOT_W-PTR_W){1'b0}}, act_slot_q, rd_idx_q};
                if (({1'b0, rd_idx_q} + 1'b1) >= cur_slot_seq_len) begin
                    state_d = ST_DONE;
                end else begin
                    rd_idx_d = rd_idx_q + 1'b1;
                end
            end

            ST_CLEAR_SLOT: begin
                state_d = ST_IDLE;
            end

            ST_DONE: begin
                state_d = ST_IDLE;
            end

            default: state_d = ST_IDLE;
        endcase
    end

    // -------------------------------------------------------------------------
    // Sequential FSM, Ring-Buffer Pointers & Compressed KV Memory Update
    // -------------------------------------------------------------------------
    logic [HEAD_DIM*8-1:0] k_dequant_q;
    logic [HEAD_DIM*8-1:0] v_dequant_q;
    logic                  kv_valid_q;
    logic                  kv_last_q;
    logic [11:0]           seq_pos_q;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_q         <= ST_IDLE;
            act_slot_q      <= '0;
            act_head_q      <= '0;
            read_after_wr_q <= 1'b0;
            rd_idx_q        <= '0;
            slot_active_q   <= '0;
            eviction_cnt_q  <= 16'd0;
            lat_k_vec_q     <= '0;
            lat_v_vec_q     <= '0;
            lat_k_scale_q   <= 16'd16;
            lat_v_scale_q   <= 16'd16;
            lat_k_zp_q      <= 4'd0;
            lat_v_zp_q      <= 4'd0;
            k_dequant_q     <= '0;
            v_dequant_q     <= '0;
            kv_valid_q      <= 1'b0;
            kv_last_q       <= 1'b0;
            seq_pos_q       <= 12'd0;
            for (int s = 0; s < MAX_USERS; s++) begin
                wr_ptr_q[s]  <= '0;
                seq_len_q[s] <= '0;
            end
        end else begin
            state_q         <= state_d;
            act_slot_q      <= act_slot_d;
            act_head_q      <= act_head_d;
            read_after_wr_q <= read_after_wr_d;
            rd_idx_q        <= rd_idx_d;

            if ((state_q == ST_IDLE) && append_en_i && !clear_slot_i) begin
                lat_k_vec_q   <= k_vec_in_i;
                lat_v_vec_q   <= v_vec_in_i;
                lat_k_scale_q <= k_scale_in_i;
                lat_v_scale_q <= v_scale_in_i;
                lat_k_zp_q    <= k_zp_in_i;
                lat_v_zp_q    <= v_zp_in_i;
            end

            if (state_q == ST_WRITE_K) begin
                k_q4_mem[wr_mem_idx]    <= lat_k_vec_q;
                k_scale_mem[wr_mem_idx] <= lat_k_scale_q;
                k_zp_mem[wr_mem_idx]    <= lat_k_zp_q;
            end

            if (state_q == ST_WRITE_V) begin
                v_q4_mem[wr_mem_idx]    <= lat_v_vec_q;
                v_scale_mem[wr_mem_idx] <= lat_v_scale_q;
                v_zp_mem[wr_mem_idx]    <= lat_v_zp_q;
                slot_active_q[act_slot_q] <= 1'b1;
                wr_ptr_q[act_slot_q] <= calc_next_wr_ptr(
                    cur_slot_wr_ptr, cur_slot_seq_len, sliding_win_en_i, sink_ptr_comb
                );
                if (cur_slot_seq_len < FULL_SEQ_LEN) begin
                    seq_len_q[act_slot_q] <= cur_slot_seq_len + 1'b1;
                end else begin
                    eviction_cnt_q <= eviction_cnt_q + 16'd1;
                end
            end

            if (state_q == ST_CLEAR_SLOT) begin
                wr_ptr_q[act_slot_q]      <= '0;
                seq_len_q[act_slot_q]     <= '0;
                slot_active_q[act_slot_q] <= 1'b0;
            end

            if (state_q == ST_READ_STREAM) begin
                k_dequant_q <= dequant_vec_int4(
                    k_q4_mem[rd_mem_idx], k_zp_mem[rd_mem_idx], k_scale_mem[rd_mem_idx]
                );
                v_dequant_q <= dequant_vec_int4(
                    v_q4_mem[rd_mem_idx], v_zp_mem[rd_mem_idx], v_scale_mem[rd_mem_idx]
                );
                kv_valid_q <= 1'b1;
                kv_last_q  <= (({1'b0, rd_idx_q} + 1'b1) >= cur_slot_seq_len);
                seq_pos_q  <= {{(12-PTR_W){1'b0}}, rd_idx_q};
            end else begin
                kv_valid_q <= 1'b0;
                kv_last_q  <= 1'b0;
            end
        end
    end

    // -------------------------------------------------------------------------
    // GQA 1-to-GQA_RATIO (4:1) Simultaneous Broadcast Hold Fanout
    // -------------------------------------------------------------------------
    assign k_dequant_o   = k_dequant_q;
    assign v_dequant_o   = v_dequant_q;
    assign gqa_k_bcast_o = {GQA_RATIO{k_dequant_q}};
    assign gqa_v_bcast_o = {GQA_RATIO{v_dequant_q}};

    assign wr_ptr_o           = wr_ptr_q[slot_id_i];
    assign rd_ptr_o           = rd_idx_q;
    assign seq_pos_o          = seq_pos_q;
    assign curr_seq_len_o     = {{(13-LEN_W){1'b0}}, seq_len_q[slot_id_i]};
    assign slot_active_mask_o = slot_active_q;
    assign eviction_cnt_o     = eviction_cnt_q;
    assign kv_valid_o         = kv_valid_q;
    assign kv_last_o          = kv_last_q;
    assign seq_done_o         = (state_q == ST_DONE);
    assign fsm_state_o        = state_q;

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

    always_ff @(posedge clk) begin
        if (past_valid_q) begin
            // PROP_M6_SEQ_LEN_BOUND: Active sequence length never exceeds MAX_SEQ_LEN
            assert (curr_seq_len_o <= {{(13-LEN_W){1'b0}}, FULL_SEQ_LEN});

            // PROP_M6_GQA_BCAST_EQUIV: All GQA_RATIO query head lanes receive identical KV
            for (int g = 0; g < GQA_RATIO; g++) begin
                assert (gqa_k_bcast_o[g*HEAD_DIM*8 +: HEAD_DIM*8] == k_dequant_o);
                assert (gqa_v_bcast_o[g*HEAD_DIM*8 +: HEAD_DIM*8] == v_dequant_o);
            end

            // PROP_M6_VALID_STATE_ENCODING: FSM state is always within valid enum [0..5]
            assert (fsm_state_o <= 3'b101);
        end
    end

endmodule
