`timescale 1ns / 1ps
/* verilator lint_off PINCONNECTEMPTY */
/* verilator lint_off UNUSED */
/* verilator lint_off SYNCASYNCNET */
// =============================================================================
// Module:      taalas_hc1_32layer_reticle_top (Stage 16 Reticle-Scale Top)
// Project:     Taalas HC1/HC2 Hardwired LLM Inference ASIC (TSMC N6 / N4P)
// Description: Full 32-Layer Llama-3.1-8B Reticle-Scale Serpentine (4x8)
//              Spatial Daisy-Chain ASIC Top-Level Integrating:
//              1. Host PCIe / AXI4-Lite CSR & LoRA DMA Controller (M13)
//              2. 8-User Concurrent Round-Robin Hardware Context Switcher
//                 with Per-User Sequence Position & LoRA Rank/Alpha Table
//              3. Hardwired Via-Mask ROM Token Embedding Lookup Unit (M1)
//              4. 32 Hardwired Transformer Layer Tiles (Layer 00 .. Layer 31)
//                 Arranged in a 4x8 Serpentine Reticle Token-Pipe Pipeline
//              5. Per-Tile Token-Wavefront Dynamic Clock-Gating Controller
//                 (31/32 = 96.875% Tiles Clock-Gated in Single-User Decode)
//              6. Final Newton-Raphson RMSNorm (M10) + Hardwired LM-Head
//                 Tournament ArgMax Sampler & 32-Layer Latency Profiler
// =============================================================================

module taalas_hc1_32layer_reticle_top #(
    parameter int NUM_LAYERS_PARAM = 32,
    parameter int NUM_USERS        = 8,
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

    // 8-User Concurrent Hardware Context Switcher & Token Wavefront Interface
    input  logic                    usr_cfg_we_i,
    input  logic [2:0]              usr_cfg_slot_i,
    input  logic [7:0]              usr_cfg_lora_rank_i,
    input  logic signed [15:0]      usr_cfg_lora_alpha_i,
    input  logic                    usr_cfg_hc2_mode_i,
    input  logic                    usr_cfg_kv_clear_i,
    input  logic [7:0]              usr_req_valid_i,
    output logic [7:0]              usr_req_ready_o,
    input  logic [8*20-1:0]         usr_req_tok_id_i,
    input  logic [11:0]             inter_token_cooldown_i,

    // Chip-to-Chip (C2C) Multi-Die Pipeline Extension Ports (HC2 Scale-Out)
    input  logic                    c2c_ext_en_i,
    output logic                    c2c_tx_valid_o,
    input  logic                    c2c_tx_ready_i,
    output logic [FLIT_WIDTH-1:0]   c2c_tx_flit_o,
    input  logic                    c2c_rx_valid_i,
    output logic                    c2c_rx_ready_o,
    input  logic [FLIT_WIDTH-1:0]   c2c_rx_flit_i,

    // 32-Layer Reticle Wavefront, Power-Gating & Multi-User Telemetry Outputs
    output logic [31:0]             chip_id_o,
    output logic                    chip_busy_o,
    output logic [31:0]             wavefront_tile_busy_o,
    output logic [31:0]             wavefront_tile_cg_o,
    output logic [31:0]             wavefront_tile_done_o,
    output logic [5:0]              active_wavefront_count_o,
    output logic [3:0]              reticle_active_row_mask_o,
    output logic [19:0]             last_sampled_token_o,
    output logic                    token_sampled_pulse_o,
    output logic [2:0]              sampled_user_slot_o,
    output logic [11:0]             sampled_user_tok_pos_o,
    output logic [8*12-1:0]         user_token_pos_flat_o,
    output logic [8*16-1:0]         user_completed_cnt_flat_o,
    output logic [63:0]             perf_cycle_cnt_o,
    output logic [31:0]             perf_token_cnt_o,
    output logic [31:0]             perf_rom_reads_o,
    output logic [31:0]             perf_zero_skip_cnt_o,
    output logic [31:0]             last_token_e2e_cycles_o,
    output logic [15:0]             last_layer0_cycles_o,
    output logic [15:0]             last_layer31_cycles_o
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
    logic [31:0]        tiles_busy_mask;
    logic [15:0]        sum_rom_reads_inc;
    logic [7:0]         sum_sram_conflicts_inc;
    logic [7:0]         sum_ecc_sec_inc;
    logic [7:0]         sum_ecc_ded_inc;
    logic [15:0]        sum_zero_skip_inc;
    logic [7:0]         sum_noc_stall_inc;
    logic [31:0]        perf_sram_conflicts;
    logic [15:0]        perf_ecc_sec_cnt;

    taalas_pcie_csr_ctrl #(
        .ADDR_WIDTH       (16),
        .DATA_WIDTH       (32),
        .TOKEN_FIFO_DEPTH (16),
        .CHIP_ID_VAL      (32'h5441_3200)
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
    // 2. 8-User Round-Robin Hardware Context Switcher & Per-User Context Table
    // -------------------------------------------------------------------------
    logic [11:0]        user_token_pos_q   [0:NUM_USERS-1];
    logic [7:0]         user_lora_rank_q   [0:NUM_USERS-1];
    logic signed [15:0] user_lora_alpha_q  [0:NUM_USERS-1];
    logic               user_hc2_mode_q    [0:NUM_USERS-1];
    logic [15:0]        user_completed_cnt_q [0:NUM_USERS-1];

    logic [2:0]         rr_ptr_q;
    logic [11:0]        cooldown_cnt_q;
    logic               can_launch_tok;
    logic               arb_usr_found;
    logic [2:0]         arb_usr_slot;
    logic               launch_fire;
    logic [2:0]         launch_slot;
    logic [19:0]        launch_tok_id;
    logic [11:0]        launch_tok_pos;

    logic                  embed_rom_valid;
    logic [511:0]          embed_rom_rdata;
    logic [9:0]            embed_active_vias;
    logic                  embed_flit_valid_q;
    logic [FLIT_WIDTH-1:0] embed_flit_q;
    logic [2:0]            embed_slot_q, embed_flit_slot_q;
    logic [11:0]           embed_tok_pos_q, embed_flit_tok_pos_q;
    logic [31:0]           embed_launch_cyc_q, embed_flit_launch_cyc_q;

    logic [NUM_LAYERS_PARAM:0]   link_valid;
    logic [NUM_LAYERS_PARAM:0]   link_ready;
    logic [FLIT_WIDTH-1:0]       link_flit [0:NUM_LAYERS_PARAM];
    logic [NUM_LAYERS_PARAM:0]   link_credit_ret;
    logic [NUM_LAYERS_PARAM-1:0] tile_busy;
    logic [NUM_LAYERS_PARAM:0]   tile_in_valid;
    logic [NUM_LAYERS_PARAM-1:0] tile_out_ready;

    // Strict backpressure & cooldown gate for token injection
    assign can_launch_tok = chip_en && (!embed_rom_valid) && (cooldown_cnt_q == 12'd0) &&
                            (!embed_flit_valid_q || (link_ready[0] && !tile_busy[0]));

    always_comb begin
        arb_usr_found   = 1'b0;
        arb_usr_slot    = rr_ptr_q;
        usr_req_ready_o = 8'h00;
        tok_in_ready    = 1'b0;
        launch_fire     = 1'b0;
        launch_slot     = slot_id;
        launch_tok_id   = tok_in_id;
        launch_tok_pos  = user_token_pos_q[slot_id];

        for (int k = 0; k < NUM_USERS; k++) begin
            logic [2:0] cand;
            cand = rr_ptr_q + 3'(k);
            if (!arb_usr_found && usr_req_valid_i[cand]) begin
                arb_usr_found = 1'b1;
                arb_usr_slot  = cand;
            end
        end

        if (can_launch_tok) begin
            if (arb_usr_found) begin
                usr_req_ready_o[arb_usr_slot] = 1'b1;
                launch_fire                   = 1'b1;
                launch_slot                   = arb_usr_slot;
                launch_tok_id                 = usr_req_tok_id_i[arb_usr_slot*20 +: 20];
                launch_tok_pos                = user_token_pos_q[arb_usr_slot];
            end else if (tok_in_valid) begin
                tok_in_ready                  = 1'b1;
                launch_fire                   = 1'b1;
                launch_slot                   = slot_id;
                launch_tok_id                 = tok_in_id;
                launch_tok_pos                = (token_pos != 12'd0) ? token_pos : user_token_pos_q[slot_id];
            end
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rr_ptr_q           <= 3'd0;
            cooldown_cnt_q     <= 12'd0;
            embed_slot_q       <= 3'd0;
            embed_tok_pos_q    <= 12'd0;
            embed_launch_cyc_q <= 32'd0;
            for (int u = 0; u < NUM_USERS; u++) begin
                user_token_pos_q[u]   <= 12'd0;
                user_lora_rank_q[u]   <= 8'd0;
                user_lora_alpha_q[u]  <= 16'sd256;
                user_hc2_mode_q[u]    <= 1'b0;
            end
        end else if (soft_rst) begin
            rr_ptr_q           <= 3'd0;
            cooldown_cnt_q     <= 12'd0;
            for (int u = 0; u < NUM_USERS; u++) begin
                user_token_pos_q[u]   <= 12'd0;
            end
        end else begin
            if (usr_cfg_we_i) begin
                user_lora_rank_q[usr_cfg_slot_i]  <= usr_cfg_lora_rank_i;
                user_lora_alpha_q[usr_cfg_slot_i] <= usr_cfg_lora_alpha_i;
                user_hc2_mode_q[usr_cfg_slot_i]   <= usr_cfg_hc2_mode_i;
                if (usr_cfg_kv_clear_i) begin
                    user_token_pos_q[usr_cfg_slot_i] <= 12'd0;
                end
            end else if (kv_clear_slot) begin
                user_token_pos_q[slot_id] <= 12'd0;
            end

            if (launch_fire) begin
                embed_slot_q       <= launch_slot;
                embed_tok_pos_q    <= launch_tok_pos;
                embed_launch_cyc_q <= perf_cycle_cnt_o[31:0];
                user_token_pos_q[launch_slot] <= launch_tok_pos + 12'd1;
                if (arb_usr_found) begin
                    rr_ptr_q <= arb_usr_slot + 3'd1;
                end
                cooldown_cnt_q <= inter_token_cooldown_i;
            end else if (cooldown_cnt_q != 12'd0) begin
                cooldown_cnt_q <= cooldown_cnt_q - 12'd1;
            end
        end
    end

    // -------------------------------------------------------------------------
    // 3. Token Embedding Via-Mask ROM Lookup & Initial Flit Packetizer
    // -------------------------------------------------------------------------
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
        .cs_en              (launch_fire),
        .precharge_en       (launch_fire),
        .sa_en              (launch_fire),
        .bank_sel_i         (launch_tok_id[7:6]),
        .addr_i             (launch_tok_id[5:0]),
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

    logic [23:0] embed_hdr_base;
    logic [7:0]  embed_hdr_crc8;
    assign embed_hdr_base = {4'b1000, 2'b00, 6'd0, 6'd0, 3'b000, embed_slot_q};
    assign embed_hdr_crc8 = embed_hdr_base[7:0] ^ embed_hdr_base[15:8] ^ embed_hdr_base[23:16] ^ 8'h5A;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            embed_flit_valid_q      <= 1'b0;
            embed_flit_q            <= '0;
            embed_flit_slot_q       <= 3'd0;
            embed_flit_tok_pos_q    <= 12'd0;
            embed_flit_launch_cyc_q <= 32'd0;
        end else if (soft_rst) begin
            embed_flit_valid_q      <= 1'b0;
            embed_flit_q            <= '0;
            embed_flit_slot_q       <= 3'd0;
            embed_flit_tok_pos_q    <= 12'd0;
            embed_flit_launch_cyc_q <= 32'd0;
        end else begin
            if (embed_rom_valid) begin
                embed_flit_valid_q      <= 1'b1;
                embed_flit_q            <= {embed_hdr_base, embed_hdr_crc8, embed_rom_rdata[FLIT_WIDTH-33:0]};
                embed_flit_slot_q       <= embed_slot_q;
                embed_flit_tok_pos_q    <= embed_tok_pos_q;
                embed_flit_launch_cyc_q <= embed_launch_cyc_q;
            end else if (embed_flit_valid_q && link_ready[0] && !tile_busy[0]) begin
                embed_flit_valid_q      <= 1'b0;
            end
        end
    end

    // -------------------------------------------------------------------------
    // 4. 32-Layer Serpentine Reticle Array (4x8) & Per-Tile Context Wavefront
    // -------------------------------------------------------------------------
    logic [NUM_LAYERS_PARAM-1:0] tile_done_pulse;
    logic [3:0]                  tile_fsm_state  [0:NUM_LAYERS_PARAM-1];
    logic [255:0]                tile_out_vec    [0:NUM_LAYERS_PARAM-1];
    logic [15:0]                 tile_rom_inc    [0:NUM_LAYERS_PARAM-1];
    logic [7:0]                  tile_sram_conf  [0:NUM_LAYERS_PARAM-1];
    logic [NUM_LAYERS_PARAM-1:0] tile_ecc_sec;
    logic [NUM_LAYERS_PARAM-1:0] tile_ecc_ded;
    logic [15:0]                 tile_zskip_inc  [0:NUM_LAYERS_PARAM-1];
    logic [NUM_LAYERS_PARAM-1:0] tile_noc_stall;
    logic [NUM_LAYERS_PARAM-1:0] tile_cg_en;

    logic [2:0]            tile_slot_q       [0:NUM_LAYERS_PARAM-1];
    logic [11:0]           tile_tok_pos_q    [0:NUM_LAYERS_PARAM-1];
    logic [31:0]           tile_launch_cyc_q [0:NUM_LAYERS_PARAM-1];
    logic [15:0]           tile_busy_cyc_q   [0:NUM_LAYERS_PARAM-1];

    assign link_valid[0]  = c2c_ext_en_i ? c2c_rx_valid_i : embed_flit_valid_q;
    assign link_flit[0]   = c2c_ext_en_i ? c2c_rx_flit_i  : embed_flit_q;
    assign c2c_rx_ready_o = c2c_ext_en_i && link_ready[0] && !tile_busy[0];

    always_comb begin
        for (int l = 0; l < NUM_LAYERS_PARAM; l++) begin
            tile_in_valid[l]  = link_valid[l] && !tile_busy[l];
            tile_out_ready[l] = (l < (NUM_LAYERS_PARAM - 1)) ?
                                (link_ready[l+1] && !tile_busy[l+1]) : link_ready[NUM_LAYERS_PARAM];
            tile_cg_en[l]     = !chip_en || layer_cg_mask[l] ||
                                (!tile_busy[l] && !(dma_sram_we && (dma_sram_layer == 8'(l))));
        end
        tile_in_valid[NUM_LAYERS_PARAM] = link_valid[NUM_LAYERS_PARAM];
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            last_layer0_cycles_o  <= 16'd0;
            last_layer31_cycles_o <= 16'd0;
            for (int l = 0; l < NUM_LAYERS_PARAM; l++) begin
                tile_slot_q[l]       <= 3'd0;
                tile_tok_pos_q[l]    <= 12'd0;
                tile_launch_cyc_q[l] <= 32'd0;
                tile_busy_cyc_q[l]   <= 16'd0;
            end
        end else if (soft_rst) begin
            last_layer0_cycles_o  <= 16'd0;
            last_layer31_cycles_o <= 16'd0;
            for (int l = 0; l < NUM_LAYERS_PARAM; l++) begin
                tile_slot_q[l]       <= 3'd0;
                tile_tok_pos_q[l]    <= 12'd0;
                tile_launch_cyc_q[l] <= 32'd0;
                tile_busy_cyc_q[l]   <= 16'd0;
            end
        end else begin
            for (int l = 0; l < NUM_LAYERS_PARAM; l++) begin
                if (tile_in_valid[l] && link_ready[l]) begin
                    tile_busy_cyc_q[l] <= 16'd1;
                    if (l == 0) begin
                        tile_slot_q[0]       <= c2c_ext_en_i ? c2c_rx_flit_i[106:104] : embed_flit_slot_q;
                        tile_tok_pos_q[0]    <= embed_flit_tok_pos_q;
                        tile_launch_cyc_q[0] <= embed_flit_launch_cyc_q;
                    end else begin
                        tile_slot_q[l]       <= tile_slot_q[l-1];
                        tile_tok_pos_q[l]    <= tile_tok_pos_q[l-1];
                        tile_launch_cyc_q[l] <= tile_launch_cyc_q[l-1];
                    end
                end else if (tile_busy[l]) begin
                    tile_busy_cyc_q[l] <= tile_busy_cyc_q[l] + 16'd1;
                end

                if (tile_done_pulse[l]) begin
                    if (l == 0)                     last_layer0_cycles_o  <= tile_busy_cyc_q[0];
                    if (l == NUM_LAYERS_PARAM - 1)  last_layer31_cycles_o <= tile_busy_cyc_q[NUM_LAYERS_PARAM-1];
                end
            end
        end
    end

    generate
        for (genvar l = 0; l < NUM_LAYERS_PARAM; l++) begin : gen_layer_tiles
            logic [2:0]         eff_tile_slot;
            logic               eff_tile_kv_clr;
            logic               eff_tile_lora_en;
            logic [7:0]         eff_tile_lora_rank;
            logic signed [15:0] eff_tile_lora_alpha;
            logic               eff_tile_hc2_mode;

            assign eff_tile_slot       = (!tile_busy[l] && usr_cfg_we_i && usr_cfg_kv_clear_i) ? usr_cfg_slot_i :
                                         (!tile_busy[l] && kv_clear_slot) ? slot_id : tile_slot_q[l];
            assign eff_tile_kv_clr     = (!tile_busy[l] && usr_cfg_we_i && usr_cfg_kv_clear_i) ||
                                         (!tile_busy[l] && kv_clear_slot);
            assign eff_tile_lora_en    = lora_en || (user_lora_rank_q[tile_slot_q[l]] != 8'd0);
            assign eff_tile_lora_rank  = (user_lora_rank_q[tile_slot_q[l]] != 8'd0) ?
                                         user_lora_rank_q[tile_slot_q[l]] : lora_rank;
            assign eff_tile_lora_alpha = (user_lora_rank_q[tile_slot_q[l]] != 8'd0) ?
                                         user_lora_alpha_q[tile_slot_q[l]] : lora_alpha_q8_8;
            assign eff_tile_hc2_mode   = hc2_mxfp4_mode || user_hc2_mode_q[tile_slot_q[l]];

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
                .hc2_mxfp4_mode_i    (eff_tile_hc2_mode),
                .zero_skip_en_i      (zero_skip_en),
                .lora_en_i           (eff_tile_lora_en),
                .lora_rank_i         (eff_tile_lora_rank),
                .lora_alpha_q8_8_i   (eff_tile_lora_alpha),
                .ntk_rope_en_i       (ntk_rope_en),
                .bcast_en_i          (bcast_en),
                .slot_id_i           (eff_tile_slot),
                .token_pos_i         (tile_tok_pos_q[l]),
                .kv_clear_slot_i     (eff_tile_kv_clr),
                .dma_sram_we_i       (dma_sram_we),
                .dma_sram_layer_i    (dma_sram_layer),
                .dma_sram_row_i      (dma_sram_row),
                .dma_sram_wdata_i    (dma_sram_wdata),
                .noc_in_valid_i      (tile_in_valid[l]),
                .noc_in_ready_o      (link_ready[l]),
                .noc_in_flit_i       (link_flit[l]),
                .noc_up_credit_ret_o (link_credit_ret[l]),
                .noc_out_valid_o     (link_valid[l+1]),
                .noc_out_ready_i     (tile_out_ready[l]),
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
    // 5. Final RMSNorm (M10) + Hardwired LM-Head Tournament ArgMax Sampler
    // -------------------------------------------------------------------------
    logic         final_norm_start, final_norm_busy, final_norm_valid, final_norm_done;
    logic [255:0] final_norm_vec;
    logic [255:0] final_in_vec_q;
    logic         final_credit_ret_q;
    logic [2:0]   final_slot_q;
    logic [11:0]  final_tok_pos_q;
    logic [31:0]  final_launch_cyc_q;

    assign link_ready[NUM_LAYERS_PARAM]      = c2c_ext_en_i ? c2c_tx_ready_i : !final_norm_busy;
    assign link_credit_ret[NUM_LAYERS_PARAM] = final_credit_ret_q;
    assign c2c_tx_valid_o                    = c2c_ext_en_i && link_valid[NUM_LAYERS_PARAM];
    assign c2c_tx_flit_o                     = link_flit[NUM_LAYERS_PARAM];
    assign final_norm_start                  = (!c2c_ext_en_i) && tile_in_valid[NUM_LAYERS_PARAM] && !final_norm_busy;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            final_in_vec_q     <= 256'd0;
            final_credit_ret_q <= 1'b0;
            final_slot_q       <= 3'd0;
            final_tok_pos_q    <= 12'd0;
            final_launch_cyc_q <= 32'd0;
        end else if (soft_rst) begin
            final_in_vec_q     <= 256'd0;
            final_credit_ret_q <= 1'b0;
            final_slot_q       <= 3'd0;
            final_tok_pos_q    <= 12'd0;
            final_launch_cyc_q <= 32'd0;
        end else begin
            final_credit_ret_q <= final_norm_start || (c2c_ext_en_i && c2c_tx_valid_o && c2c_tx_ready_i);
            if (final_norm_start) begin
                final_in_vec_q     <= tile_out_vec[NUM_LAYERS_PARAM-1];
                final_slot_q       <= tile_slot_q[NUM_LAYERS_PARAM-1];
                final_tok_pos_q    <= tile_tok_pos_q[NUM_LAYERS_PARAM-1];
                final_launch_cyc_q <= tile_launch_cyc_q[NUM_LAYERS_PARAM-1];
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
            sampled_tok_q           <= 20'd0;
            sampled_valid_q         <= 1'b0;
            sampled_user_slot_o     <= 3'd0;
            sampled_user_tok_pos_o  <= 12'd0;
            last_token_e2e_cycles_o <= 32'd0;
            for (int u = 0; u < NUM_USERS; u++) begin
                user_completed_cnt_q[u] <= 16'd0;
            end
        end else if (soft_rst) begin
            sampled_tok_q           <= 20'd0;
            sampled_valid_q         <= 1'b0;
            sampled_user_slot_o     <= 3'd0;
            sampled_user_tok_pos_o  <= 12'd0;
            last_token_e2e_cycles_o <= 32'd0;
            for (int u = 0; u < NUM_USERS; u++) begin
                user_completed_cnt_q[u] <= 16'd0;
            end
        end else begin
            sampled_valid_q <= final_norm_done;
            if (final_norm_valid) begin
                sampled_tok_q <= {1'b0, final_slot_q, best_val_comb[11:0], best_idx_comb} ^ 20'h00100;
            end
            if (final_norm_done) begin
                sampled_user_slot_o     <= final_slot_q;
                sampled_user_tok_pos_o  <= final_tok_pos_q;
                last_token_e2e_cycles_o <= perf_cycle_cnt_o[31:0] - final_launch_cyc_q;
                user_completed_cnt_q[final_slot_q] <= user_completed_cnt_q[final_slot_q] + 16'd1;
            end
        end
    end

    assign tok_out_valid         = sampled_valid_q;
    assign tok_out_id            = sampled_tok_q;
    assign last_sampled_token_o  = sampled_tok_q;
    assign token_sampled_pulse_o = sampled_valid_q;

    // -------------------------------------------------------------------------
    // 6. 32-Layer Reticle Wavefront, Power-Gating & Multi-User Telemetry
    // -------------------------------------------------------------------------
    logic [31:0] tile_in_valid_vec;

    always_comb begin
        tiles_busy_mask          = 32'd0;
        wavefront_tile_cg_o      = 32'hFFFF_FFFF;
        wavefront_tile_done_o    = 32'd0;
        tile_in_valid_vec        = 32'd0;
        active_wavefront_count_o = 6'd0;
        sum_rom_reads_inc        = embed_rom_valid ? {6'd0, embed_active_vias} : 16'd0;
        sum_sram_conflicts_inc   = 8'd0;
        sum_ecc_sec_inc          = 8'd0;
        sum_ecc_ded_inc          = 8'd0;
        sum_zero_skip_inc        = 16'd0;
        sum_noc_stall_inc        = 8'd0;

        for (int l = 0; l < NUM_LAYERS_PARAM; l++) begin
            tiles_busy_mask[l]       = tile_busy[l];
            wavefront_tile_cg_o[l]   = tile_cg_en[l];
            wavefront_tile_done_o[l] = tile_done_pulse[l];
            tile_in_valid_vec[l]     = tile_in_valid[l];
            active_wavefront_count_o = active_wavefront_count_o + {5'd0, tile_busy[l]};
            sum_rom_reads_inc        = sum_rom_reads_inc + tile_rom_inc[l];
            sum_sram_conflicts_inc   = sum_sram_conflicts_inc + tile_sram_conf[l];
            sum_ecc_sec_inc          = sum_ecc_sec_inc + {7'd0, tile_ecc_sec[l]};
            sum_ecc_ded_inc          = sum_ecc_ded_inc + {7'd0, tile_ecc_ded[l]};
            sum_zero_skip_inc        = sum_zero_skip_inc + tile_zskip_inc[l];
            sum_noc_stall_inc        = sum_noc_stall_inc + {7'd0, tile_noc_stall[l]};
        end

        for (int u = 0; u < NUM_USERS; u++) begin
            user_token_pos_flat_o[u*12 +: 12]     = user_token_pos_q[u];
            user_completed_cnt_flat_o[u*16 +: 16] = user_completed_cnt_q[u];
        end
    end

    assign wavefront_tile_busy_o    = tiles_busy_mask;
    assign reticle_active_row_mask_o = {|tiles_busy_mask[31:24], |tiles_busy_mask[23:16],
                                        |tiles_busy_mask[15:8],  |tiles_busy_mask[7:0]};
    assign chip_busy_o              = (|tiles_busy_mask) || embed_flit_valid_q || final_norm_busy || dma_busy;

    // -------------------------------------------------------------------------
    // 7. Inline SVA Formal Properties for 32-Layer Reticle & 8-User Switcher
    // -------------------------------------------------------------------------
    always_comb begin
        if (rst_n) begin
            PROP_RETICLE32_WAVEFRONT_CONSERVATION: assert (
                (active_wavefront_count_o <= 6'd32) &&
                ((active_wavefront_count_o == 6'd0) == (wavefront_tile_busy_o == 32'd0)) &&
                (!embed_rom_valid || (!tok_in_ready && (usr_req_ready_o == 8'h00)))
            );
            PROP_RETICLE32_CG_COMPLEMENT: assert (
                ((wavefront_tile_busy_o & ~layer_cg_mask & {32{chip_en}}) & wavefront_tile_cg_o) == 32'd0
            );
            PROP_RETICLE32_USER_SLOT_ISOLATION: assert (
                ((usr_req_ready_o & (usr_req_ready_o - 8'd1)) == 8'd0) &&
                ((tile_in_valid_vec & wavefront_tile_busy_o) == 32'd0)
            );
        end
    end

endmodule
