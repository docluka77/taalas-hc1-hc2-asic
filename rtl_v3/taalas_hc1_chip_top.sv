`timescale 1ns / 1ps
/* verilator lint_off PINCONNECTEMPTY */
/* verilator lint_off UNUSED */
/* verilator lint_off SYNCASYNCNET */
// =============================================================================
// Module:      taalas_hc1_chip_top (M15 / Full-Chip Top)
// Project:     Taalas HC1/HC2 Hardwired LLM Inference ASIC (TSMC N6 / N4P)
// Description: Full-Chip Top-Level ASIC Hierarchy Integrating:
//              1. Host PCIe / AXI4-Lite CSR Controller & LoRA DMA Engine (M13)
//              2. Hardwired Via-Mask ROM Token Embedding Lookup Unit (M1)
//              3. Daisy-Chained Spatial Array of NUM_LAYERS_PARAM Hardwired
//                 Transformer Decoder Layer Tiles (M14) Connected via Wormhole
//                 Token-Pipe NoC Routers (M12)
//              4. Global Token-Wavefront Dynamic Clock/Power-Gating Controller
//              5. Final Newton-Raphson RMSNorm (M10) + Hardwired LM-Head
//                 Logit Projection & Tournament ArgMax Token Sampler
// =============================================================================

module taalas_hc1_chip_top #(
    parameter int NUM_LAYERS_PARAM = 4,
    parameter int FLIT_WIDTH       = 128,
    parameter int HIDDEN_DIM       = 16,
    parameter int HEAD_DIM         = 16,
    parameter int GQA_RATIO        = 4,
    parameter bit HC2_MXFP4_MODE   = 1'b0
) (
    input  logic                    clk,
    input  logic                    rst_n,

    // Host PCIe / AXI4-Lite Control & Status Register (CSR) Slave Interface
    input  logic [15:0]             s_axi_awaddr,
    input  logic                    s_axi_awvalid,
    output logic                    s_axi_awready,
    input  logic [31:0]             s_axi_wdata,
    input  logic [3:0]              s_axi_wstrb,
    input  logic                    s_axi_wvalid,
    output logic                    s_axi_wready,
    output logic [1:0]              s_axi_bresp,
    output logic                    s_axi_bvalid,
    input  logic                    s_axi_bready,

    input  logic [15:0]             s_axi_araddr,
    input  logic                    s_axi_arvalid,
    output logic                    s_axi_arready,
    output logic [31:0]             s_axi_rdata,
    output logic [1:0]              s_axi_rresp,
    output logic                    s_axi_rvalid,
    input  logic                    s_axi_rready,

    // Chip-to-Chip (C2C) Multi-Die Pipeline Extension Ports (HC2 Scale-Out)
    input  logic                    c2c_ext_en_i,
    output logic                    c2c_tx_valid_o,
    input  logic                    c2c_tx_ready_i,
    output logic [FLIT_WIDTH-1:0]   c2c_tx_flit_o,
    input  logic                    c2c_rx_valid_i,
    output logic                    c2c_rx_ready_o,
    input  logic [FLIT_WIDTH-1:0]   c2c_rx_flit_i,

    // Top-Level Chip Status, Power-Gating & Performance Telemetry Outputs
    output logic [31:0]             chip_id_o,
    output logic                    chip_busy_o,
    output logic [31:0]             active_tile_mask_o,
    output logic [31:0]             clock_gated_tile_mask_o,
    output logic [19:0]             last_sampled_token_o,
    output logic                    token_sampled_pulse_o,
    output logic [63:0]             perf_cycle_cnt_o,
    output logic [31:0]             perf_token_cnt_o,
    output logic [31:0]             perf_rom_reads_o,
    output logic [31:0]             perf_zero_skip_cnt_o
);

    // -------------------------------------------------------------------------
    // 1. Host PCIe / AXI4-Lite CSR Controller & LoRA DMA Engine (M13)
    // -------------------------------------------------------------------------
    logic               chip_en, soft_rst, lora_en, hc2_mxfp4_mode;
    logic               zero_skip_en, rom_sleep_en, ntk_rope_en, bcast_en;
    logic [31:0]        layer_cg_mask;
    logic [2:0]         slot_id;
    logic [11:0]        token_pos;
    logic               kv_clear_slot;
    logic [7:0]         lora_rank;
    logic signed [15:0] lora_alpha_q8_8;

    logic [31:0]        dma_src_addr, dma_dst_sram_addr;
    logic [15:0]        dma_len;
    logic               dma_start, dma_busy, dma_done;
    logic               dma_sram_we;
    logic [7:0]         dma_sram_layer;
    logic [11:0]        dma_sram_row;
    logic [63:0]        dma_sram_wdata;

    logic               tok_in_valid, tok_in_ready;
    logic [19:0]        tok_in_id;
    logic               tok_out_valid, tok_out_ready;
    logic [19:0]        tok_out_id;
    logic [31:0] tiles_busy_mask;
    logic [15:0] sum_rom_reads_inc;
    logic [7:0]  sum_sram_conflicts_inc;
    logic [7:0]  sum_ecc_sec_inc;
    logic [7:0]  sum_ecc_ded_inc;
    logic [15:0] sum_zero_skip_inc;
    logic [7:0]  sum_noc_stall_inc;
    logic [31:0] perf_sram_conflicts;
    logic [15:0] perf_ecc_sec_cnt;

    taalas_pcie_csr_ctrl #(
        .ADDR_WIDTH       (16),
        .DATA_WIDTH       (32),
        .TOKEN_FIFO_DEPTH (16),
        .CHIP_ID_VAL      (32'h5441_0100)
    ) u_pcie_csr_ctrl (
        .clk                   (clk),
        .rst_n                 (rst_n),
        .s_axi_awaddr          (s_axi_awaddr),
        .s_axi_awvalid         (s_axi_awvalid),
        .s_axi_awready         (s_axi_awready),
        .s_axi_wdata           (s_axi_wdata),
        .s_axi_wstrb           (s_axi_wstrb),
        .s_axi_wvalid          (s_axi_wvalid),
        .s_axi_wready          (s_axi_wready),
        .s_axi_bresp           (s_axi_bresp),
        .s_axi_bvalid          (s_axi_bvalid),
        .s_axi_bready          (s_axi_bready),
        .s_axi_araddr          (s_axi_araddr),
        .s_axi_arvalid         (s_axi_arvalid),
        .s_axi_arready         (s_axi_arready),
        .s_axi_rdata           (s_axi_rdata),
        .s_axi_rresp           (s_axi_rresp),
        .s_axi_rvalid          (s_axi_rvalid),
        .s_axi_rready          (s_axi_rready),
        .chip_id_o             (chip_id_o),
        .chip_en_o             (chip_en),
        .soft_rst_o            (soft_rst),
        .lora_en_o             (lora_en),
        .hc2_mxfp4_mode_o      (hc2_mxfp4_mode),
        .zero_skip_en_o        (zero_skip_en),
        .rom_sleep_en_o        (rom_sleep_en),
        .ntk_rope_en_o         (ntk_rope_en),
        .bcast_en_o            (bcast_en),
        .layer_cg_mask_o       (layer_cg_mask),
        .slot_id_o             (slot_id),
        .token_pos_o           (token_pos),
        .kv_clear_slot_o       (kv_clear_slot),
        .lora_rank_o           (lora_rank),
        .lora_alpha_q8_8_o     (lora_alpha_q8_8),
        .dma_src_addr_o        (dma_src_addr),
        .dma_dst_sram_addr_o   (dma_dst_sram_addr),
        .dma_len_o             (dma_len),
        .dma_start_o           (dma_start),
        .dma_busy_o            (dma_busy),
        .dma_done_o            (dma_done),
        .dma_sram_we_o         (dma_sram_we),
        .dma_sram_layer_o      (dma_sram_layer),
        .dma_sram_row_o        (dma_sram_row),
        .dma_sram_wdata_o      (dma_sram_wdata),
        .tok_in_valid_o        (tok_in_valid),
        .tok_in_ready_i        (tok_in_ready),
        .tok_in_id_o           (tok_in_id),
        .tok_out_valid_i       (tok_out_valid),
        .tok_out_ready_o       (tok_out_ready),
        .tok_out_id_i          (tok_out_id),
        .tiles_busy_mask_i     (tiles_busy_mask),
        .inc_rom_reads_i       (sum_rom_reads_inc),
        .inc_sram_conflicts_i  (sum_sram_conflicts_inc),
        .inc_ecc_sec_i         (sum_ecc_sec_inc),
        .inc_ecc_ded_i         (sum_ecc_ded_inc),
        .inc_zero_skip_i       (sum_zero_skip_inc),
        .inc_noc_stall_i       (sum_noc_stall_inc),
        .perf_cycle_cnt_o      (perf_cycle_cnt_o),
        .perf_token_cnt_o      (perf_token_cnt_o),
        .perf_rom_reads_o      (perf_rom_reads_o),
        .perf_sram_conflicts_o (perf_sram_conflicts),
        .perf_ecc_sec_cnt_o    (perf_ecc_sec_cnt),
        .perf_zero_skip_cnt_o  (perf_zero_skip_cnt_o)
    );

    // -------------------------------------------------------------------------
    // 2. Token Embedding Via-Mask ROM Lookup & Initial Flit Packetizer
    // -------------------------------------------------------------------------
    logic                  embed_rom_valid;
    logic [511:0]          embed_rom_rdata;
    logic [9:0]            embed_active_vias;
    logic                  embed_flit_valid_q;
    logic [FLIT_WIDTH-1:0] embed_flit_q;
    logic                  link_ready [0:NUM_LAYERS_PARAM];

    // [STAGE-10 FIX BUG-HC1-008]: Gate tok_in_ready with !embed_rom_valid so 1-cycle ROM read cannot be overwritten
    assign tok_in_ready = chip_en && (!embed_rom_valid) && (!embed_flit_valid_q || link_ready[0]);

    taalas_via_mask_rom_macro #(
        .NUM_BANKS     (4),
        .ROWS          (64),
        .COLS          (512),
        .COLS_3B       (64),
        .OUTLIER_SLOTS (8),
        .MASK_SEED     (32'h5441_E000)
    ) u_token_embed_rom (
        .clk                (clk),
        .rst_n              (rst_n),
        .sleep_n            (chip_en && !rom_sleep_en),
        .sleep_i            (!chip_en || rom_sleep_en),
        .iso_en_i           (!chip_en || rom_sleep_en),
        .cs_en              (tok_in_valid && tok_in_ready),
        .precharge_en       (tok_in_valid && tok_in_ready),
        .sa_en              (tok_in_valid && tok_in_ready),
        .bank_sel_i         (tok_in_id[7:6]),
        .addr_i             (tok_in_id[5:0]),
        .prog_en_i          (1'b0),
        .prog_bank_i        ('0),
        .prog_row_i         ('0),
        .prog_wdata_i       ('0),
        .bist_start_i       (1'b0),
        .bist_busy_o        (),
        .bist_done_o        (),
        .bist_crc16_o       (),
        .bist_pass_o        (),
        .rdata_o            (embed_rom_rdata),
        .weights_3b_o       (),
        .outlier_idx_o      (),
        .outlier_val6b_o    (),
        .group_scale_fp16_o (),
        .group_zp_int8_o    (),
        .rvalid_o           (embed_rom_valid),
        .active_vias_o            (embed_active_vias),
        .bank_active_o            (),
        .bl_precharged_o          (),
        .bl_contention_prevented_o()
    );
    // Format initial embedding flit targeting Layer Tile 0 (dst_tile = 0)
    logic [23:0] embed_hdr_base;
    logic [7:0]  embed_hdr_crc8;
    assign embed_hdr_base = {4'b1000, 2'b00, 6'd0, 6'd0, 3'b000, slot_id};
    assign embed_hdr_crc8 = embed_hdr_base[7:0] ^ embed_hdr_base[15:8] ^ embed_hdr_base[23:16] ^ 8'h5A;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            embed_flit_valid_q <= 1'b0;
            embed_flit_q       <= '0;
        end else if (soft_rst) begin
            embed_flit_valid_q <= 1'b0;
            embed_flit_q       <= '0;
        end else begin
            if (embed_rom_valid) begin
                embed_flit_valid_q <= 1'b1;
                embed_flit_q       <= {embed_hdr_base, embed_hdr_crc8, embed_rom_rdata[FLIT_WIDTH-33:0]};
            end else if (embed_flit_valid_q && link_ready[0]) begin
                embed_flit_valid_q <= 1'b0;
            end
        end
    end

    // -------------------------------------------------------------------------
    // 3. Daisy-Chained Array of NUM_LAYERS_PARAM Transformer Layer Tiles (M14)
    //    & Global Token-Wavefront Clock/Power-Gating Controller
    // -------------------------------------------------------------------------
    logic                  link_valid      [0:NUM_LAYERS_PARAM];
    logic [FLIT_WIDTH-1:0] link_flit       [0:NUM_LAYERS_PARAM];
    logic                  link_credit_ret [0:NUM_LAYERS_PARAM];

    logic                  tile_busy       [0:NUM_LAYERS_PARAM-1];
    logic                  tile_done_pulse [0:NUM_LAYERS_PARAM-1];
    logic [3:0]            tile_fsm_state  [0:NUM_LAYERS_PARAM-1];
    logic [255:0]          tile_out_vec    [0:NUM_LAYERS_PARAM-1];
    logic [15:0]           tile_rom_inc    [0:NUM_LAYERS_PARAM-1];
    logic [7:0]            tile_sram_conf  [0:NUM_LAYERS_PARAM-1];
    logic                  tile_ecc_sec    [0:NUM_LAYERS_PARAM-1];
    logic                  tile_ecc_ded    [0:NUM_LAYERS_PARAM-1];
    logic [15:0]           tile_zskip_inc  [0:NUM_LAYERS_PARAM-1];
    logic                  tile_noc_stall  [0:NUM_LAYERS_PARAM-1];
    logic                  tile_cg_en      [0:NUM_LAYERS_PARAM-1];

    assign link_valid[0] = c2c_ext_en_i ? c2c_rx_valid_i : embed_flit_valid_q;
    assign link_flit[0]  = c2c_ext_en_i ? c2c_rx_flit_i  : embed_flit_q;
    assign c2c_rx_ready_o = c2c_ext_en_i && link_ready[0];

    generate
        for (genvar l = 0; l < NUM_LAYERS_PARAM; l++) begin : gen_layer_tiles
            // Token-Wavefront Clock-Gating: gate tile when masked by CSR or
            // when chip is disabled; wake immediately when upstream link_valid[l]
            // asserts or while tile_busy[l] is active.
            assign tile_cg_en[l] = !chip_en || layer_cg_mask[l] ||
                                   (!tile_busy[l] && !link_valid[l] && !dma_sram_we);

            taalas_hc1_layer_tile #(
                .TILE_ID        (l),
                .FLIT_WIDTH     (FLIT_WIDTH),
                .HIDDEN_DIM     (HIDDEN_DIM),
                .HEAD_DIM       (HEAD_DIM),
                .GQA_RATIO      (GQA_RATIO),
                .HC2_MXFP4_MODE (HC2_MXFP4_MODE)
            ) u_layer_tile (
                .clk                 (clk),
                .rst_n               (rst_n && !soft_rst),
                .tile_cg_en_i        (layer_cg_mask[l] || !chip_en),
                .rom_sleep_en_i      (rom_sleep_en),
                .hc2_mxfp4_mode_i    (hc2_mxfp4_mode),
                .zero_skip_en_i      (zero_skip_en),
                .lora_en_i           (lora_en),
                .lora_rank_i         (lora_rank),
                .lora_alpha_q8_8_i   (lora_alpha_q8_8),
                .ntk_rope_en_i       (ntk_rope_en),
                .bcast_en_i          (bcast_en),
                .slot_id_i           (slot_id),
                .token_pos_i         (token_pos),
                .kv_clear_slot_i     (kv_clear_slot),
                .dma_sram_we_i       (dma_sram_we),
                .dma_sram_layer_i    (dma_sram_layer),
                .dma_sram_row_i      (dma_sram_row),
                .dma_sram_wdata_i    (dma_sram_wdata),
                .noc_in_valid_i      (link_valid[l]),
                .noc_in_ready_o      (link_ready[l]),
                .noc_in_flit_i       (link_flit[l]),
                .noc_up_credit_ret_o (link_credit_ret[l]),
                .noc_out_valid_o     (link_valid[l+1]),
                .noc_out_ready_i     (link_ready[l+1]),
                .noc_out_flit_o      (link_flit[l+1]),
                .noc_dn_credit_ret_i (link_credit_ret[l+1]),
                .tile_busy_o         (tile_busy[l]),
                .tile_done_pulse_o   (tile_done_pulse[l]),
                .tile_fsm_state_o    (tile_fsm_state[l]),
                .layer_out_vec_o     (tile_out_vec[l]),
                .rom_reads_inc_o     (tile_rom_inc[l]),
                .sram_conflict_inc_o (tile_sram_conf[l]),
                .ecc_sec_pulse_o     (tile_ecc_sec[l]),
                .ecc_ded_pulse_o     (tile_ecc_ded[l]),
                .zero_skip_inc_o     (tile_zskip_inc[l]),
                .noc_stall_pulse_o   (tile_noc_stall[l])
            );
        end
    endgenerate
    // -------------------------------------------------------------------------
    // 4. Final RMSNorm (M10) + Hardwired LM-Head Tournament ArgMax Sampler
    // -------------------------------------------------------------------------
    logic         final_norm_start, final_norm_busy, final_norm_valid, final_norm_done;
    logic [255:0] final_norm_vec;
    logic [255:0] final_in_vec_q;
    logic         final_credit_ret_q;

    assign link_ready[NUM_LAYERS_PARAM]      = c2c_ext_en_i ? c2c_tx_ready_i : !final_norm_busy;
    assign link_credit_ret[NUM_LAYERS_PARAM] = final_credit_ret_q;
    assign c2c_tx_valid_o                    = c2c_ext_en_i && link_valid[NUM_LAYERS_PARAM];
    assign c2c_tx_flit_o                     = link_flit[NUM_LAYERS_PARAM];

    assign final_norm_start = (!c2c_ext_en_i) && link_valid[NUM_LAYERS_PARAM] && !final_norm_busy;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            final_in_vec_q     <= 256'd0;
            final_credit_ret_q <= 1'b0;
        end else begin
            final_credit_ret_q <= final_norm_start || (c2c_ext_en_i && c2c_tx_valid_o && c2c_tx_ready_i);
            if (final_norm_start) begin
                final_in_vec_q <= tile_out_vec[NUM_LAYERS_PARAM-1];
            end
        end
    end

    taalas_rmsnorm_engine #(
        .HIDDEN_DIM  (32),
        .VEC_W       (16),
        .DATA_W      (16),
        .EPS_DEFAULT (4)
    ) u_final_rmsnorm (
        .clk            (clk),
        .rst_n          (rst_n && !soft_rst),
        .start_i        (final_norm_start),
        .in_valid_i     (1'b1),
        .x_vec_i        (final_norm_start ? tile_out_vec[NUM_LAYERS_PARAM-1] : final_in_vec_q),
        .eps_q16_i      (16'd4),
        .ext_gamma_en_i (1'b0),
        .gamma_vec_i    ('0),
        .busy_o         (final_norm_busy),
        .out_valid_o    (final_norm_valid),
        .out_last_o     (),
        .done_o         (final_norm_done),
        .y_vec_o        (final_norm_vec),
        .var_eps_o      (),
        .inv_rms_q8_8_o (),
        .fsm_state_o    ()
    );

    // 4-Level Balanced Binary Tournament ArgMax Tree over 16 LM-Head Logit Channels
    logic [3:0]         best_idx_comb;
    logic signed [15:0] best_val_comb;
    logic [19:0]        sampled_tok_q;
    logic               sampled_valid_q;

    always_comb begin
        logic signed [15:0] l1_val [0:7];
        logic [3:0]         l1_idx [0:7];
        logic signed [15:0] l2_val [0:3];
        logic [3:0]         l2_idx [0:3];
        logic signed [15:0] l3_val [0:1];
        logic [3:0]         l3_idx [0:1];

        for (int i = 0; i < 8; i++) begin
            logic signed [15:0] v_l, v_r;
            v_l = $signed(final_norm_vec[(2*i)*16 +: 16]);
            v_r = $signed(final_norm_vec[(2*i + 1)*16 +: 16]);
            if (v_r > v_l) begin
                l1_val[i] = v_r;
                l1_idx[i] = 4'(2*i + 1);
            end else begin
                l1_val[i] = v_l;
                l1_idx[i] = 4'(2*i);
            end
        end
        for (int i = 0; i < 4; i++) begin
            if (l1_val[2*i + 1] > l1_val[2*i]) begin
                l2_val[i] = l1_val[2*i + 1];
                l2_idx[i] = l1_idx[2*i + 1];
            end else begin
                l2_val[i] = l1_val[2*i];
                l2_idx[i] = l1_idx[2*i];
            end
        end
        for (int i = 0; i < 2; i++) begin
            if (l2_val[2*i + 1] > l2_val[2*i]) begin
                l3_val[i] = l2_val[2*i + 1];
                l3_idx[i] = l2_idx[2*i + 1];
            end else begin
                l3_val[i] = l2_val[2*i];
                l3_idx[i] = l2_idx[2*i];
            end
        end
        if (l3_val[1] > l3_val[0]) begin
            best_val_comb = l3_val[1];
            best_idx_comb = l3_idx[1];
        end else begin
            best_val_comb = l3_val[0];
            best_idx_comb = l3_idx[0];
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sampled_tok_q   <= 20'd0;
            sampled_valid_q <= 1'b0;
        end else if (soft_rst) begin
            sampled_tok_q   <= 20'd0;
            sampled_valid_q <= 1'b0;
        end else begin
            sampled_valid_q <= final_norm_done;
            if (final_norm_valid) begin
                sampled_tok_q <= {4'd0, best_val_comb[11:0], best_idx_comb} ^ 20'h00100;
            end
        end
    end

    assign tok_out_valid         = sampled_valid_q;
    assign tok_out_id            = sampled_tok_q;
    assign last_sampled_token_o  = sampled_tok_q;
    assign token_sampled_pulse_o = sampled_valid_q;

    // -------------------------------------------------------------------------
    // 5. Global Telemetry & Power/Clock-Gating Mask Aggregation
    // -------------------------------------------------------------------------
    always_comb begin
        tiles_busy_mask        = 32'd0;
        clock_gated_tile_mask_o= 32'hFFFF_FFFF;
        sum_rom_reads_inc      = embed_rom_valid ? {6'd0, embed_active_vias} : 16'd0;
        sum_sram_conflicts_inc = 8'd0;
        sum_ecc_sec_inc        = 8'd0;
        sum_ecc_ded_inc        = 8'd0;
        sum_zero_skip_inc      = 16'd0;
        sum_noc_stall_inc      = 8'd0;

        for (int l = 0; l < NUM_LAYERS_PARAM; l++) begin
            tiles_busy_mask[l]         = tile_busy[l];
            clock_gated_tile_mask_o[l] = tile_cg_en[l];
            sum_rom_reads_inc          = sum_rom_reads_inc + tile_rom_inc[l];
            sum_sram_conflicts_inc     = sum_sram_conflicts_inc + tile_sram_conf[l];
            sum_ecc_sec_inc            = sum_ecc_sec_inc + {7'd0, tile_ecc_sec[l]};
            sum_ecc_ded_inc            = sum_ecc_ded_inc + {7'd0, tile_ecc_ded[l]};
            sum_zero_skip_inc          = sum_zero_skip_inc + tile_zskip_inc[l];
            sum_noc_stall_inc          = sum_noc_stall_inc + {7'd0, tile_noc_stall[l]};
        end
    end

    assign active_tile_mask_o = tiles_busy_mask;
    assign chip_busy_o        = (|tiles_busy_mask) || embed_flit_valid_q || final_norm_busy || dma_busy;

    // Inline SVA Formal Invariant: Embedding ROM 1-cycle read latency never permits simultaneous token pop
    always_comb begin
        if (rst_n && embed_rom_valid) begin
            PROP_BUG008_EMBED_BACKPRESSURE: assert (!tok_in_ready);
        end
    end

endmodule
