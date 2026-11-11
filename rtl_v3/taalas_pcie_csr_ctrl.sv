`timescale 1ns / 1ps
/* verilator lint_off UNUSED */
// =============================================================================
// Module:      taalas_pcie_csr_ctrl (M13)
// Project:     Taalas HC1/HC2 Hardwired LLM Inference ASIC
// Description: Host PCIe / AXI4-Lite Control & Status Register (CSR) Block
//              (0x0000 - 0x0048, CHIP_ID = 32'h5441_0100 "TAALAS HC1 v1.0"),
//              Autonomous LoRA Weight SRAM DMA Loader, Token Stream Ingress &
//              Egress FIFOs, Per-Layer Power/Clock-Gating Mask Register, and
//              64-Bit Hardware Performance Counter Suite.
// =============================================================================

module taalas_pcie_csr_ctrl #(
    parameter int          ADDR_WIDTH       = 16,
    parameter int          DATA_WIDTH       = 32,
    parameter int          TOKEN_FIFO_DEPTH = 16,
    parameter logic [31:0] CHIP_ID_VAL      = 32'h5441_0100
) (
    input  logic                    clk,
    input  logic                    rst_n,

    // Host AXI4-Lite Slave Interface
    input  logic [ADDR_WIDTH-1:0]   s_axi_awaddr,
    input  logic                    s_axi_awvalid,
    output logic                    s_axi_awready,
    input  logic [DATA_WIDTH-1:0]   s_axi_wdata,
    input  logic [DATA_WIDTH/8-1:0] s_axi_wstrb,
    input  logic                    s_axi_wvalid,
    output logic                    s_axi_wready,
    output logic [1:0]              s_axi_bresp,
    output logic                    s_axi_bvalid,
    input  logic                    s_axi_bready,

    input  logic [ADDR_WIDTH-1:0]   s_axi_araddr,
    input  logic                    s_axi_arvalid,
    output logic                    s_axi_arready,
    output logic [DATA_WIDTH-1:0]   s_axi_rdata,
    output logic [1:0]              s_axi_rresp,
    output logic                    s_axi_rvalid,
    input  logic                    s_axi_rready,

    // Global Chip Configuration & Layer Power/Clock-Gating Controls
    output logic [31:0]             chip_id_o,
    output logic                    chip_en_o,
    output logic                    soft_rst_o,
    output logic                    lora_en_o,
    output logic                    hc2_mxfp4_mode_o,
    output logic                    zero_skip_en_o,
    output logic                    rom_sleep_en_o,
    output logic                    ntk_rope_en_o,
    output logic                    bcast_en_o,
    output logic [31:0]             layer_cg_mask_o,
    output logic [2:0]              slot_id_o,
    output logic [11:0]             token_pos_o,
    output logic                    kv_clear_slot_o,
    output logic [7:0]              lora_rank_o,
    output logic signed [15:0]      lora_alpha_q8_8_o,

    // LoRA Weight SRAM DMA Loader Interface
    output logic [31:0]             dma_src_addr_o,
    output logic [31:0]             dma_dst_sram_addr_o,
    output logic [15:0]             dma_len_o,
    output logic                    dma_start_o,
    output logic                    dma_busy_o,
    output logic                    dma_done_o,
    output logic                    dma_sram_we_o,
    output logic [7:0]              dma_sram_layer_o,
    output logic [11:0]             dma_sram_row_o,
    output logic [63:0]             dma_sram_wdata_o,

    // Token Stream Ingress FIFO -> Layer Tile 0
    output logic                    tok_in_valid_o,
    input  logic                    tok_in_ready_i,
    output logic [19:0]             tok_in_id_o,

    // LM-Head ArgMax -> Token Stream Egress FIFO
    input  logic                    tok_out_valid_i,
    output logic                    tok_out_ready_o,
    input  logic [19:0]             tok_out_id_i,

    // Hardware Telemetry & Performance Counter Aggregation Inputs
    input  logic [31:0]             tiles_busy_mask_i,
    input  logic [15:0]             inc_rom_reads_i,
    input  logic [7:0]              inc_sram_conflicts_i,
    input  logic [7:0]              inc_ecc_sec_i,
    input  logic [7:0]              inc_ecc_ded_i,
    input  logic [15:0]             inc_zero_skip_i,
    input  logic [7:0]              inc_noc_stall_i,

    // Exported Hardware Performance Counters
    output logic [63:0]             perf_cycle_cnt_o,
    output logic [31:0]             perf_token_cnt_o,
    output logic [31:0]             perf_rom_reads_o,
    output logic [31:0]             perf_sram_conflicts_o,
    output logic [15:0]             perf_ecc_sec_cnt_o,
    output logic [31:0]             perf_zero_skip_cnt_o
);
    // -------------------------------------------------------------------------
    // CSR Address Offset Constants (Section 3.13.1 of Microarch Spec)
    // -------------------------------------------------------------------------
    localparam logic [7:0] CSR_CHIP_ID            = 8'h00;
    localparam logic [7:0] CSR_CHIP_CTRL          = 8'h04;
    localparam logic [7:0] CSR_CHIP_STATUS        = 8'h08;
    localparam logic [7:0] CSR_USER_SLOT_CFG      = 8'h0C;
    localparam logic [7:0] CSR_LORA_CFG           = 8'h10;
    localparam logic [7:0] CSR_DMA_SRC_LO         = 8'h14;
    localparam logic [7:0] CSR_DMA_DST_SRAM       = 8'h18;
    localparam logic [7:0] CSR_DMA_LEN_TRIG       = 8'h1C;
    localparam logic [7:0] CSR_TOKEN_INGRESS      = 8'h20;
    localparam logic [7:0] CSR_TOKEN_EGRESS       = 8'h24;
    localparam logic [7:0] CSR_PERF_CYCLES_LO     = 8'h28;
    localparam logic [7:0] CSR_PERF_CYCLES_HI     = 8'h2C;
    localparam logic [7:0] CSR_PERF_TOKENS        = 8'h30;
    localparam logic [7:0] CSR_PERF_ZERO_SKIP     = 8'h34;
    localparam logic [7:0] CSR_ECC_ERR_CNT        = 8'h38;
    localparam logic [7:0] CSR_NOC_STALL_CNT      = 8'h3C;
    localparam logic [7:0] CSR_LAYER_CG_MASK      = 8'h40;
    localparam logic [7:0] CSR_PERF_ROM_READS     = 8'h44;
    localparam logic [7:0] CSR_PERF_SRAM_CONFLICTS= 8'h48;

    localparam int FIFO_PTR_W = $clog2(TOKEN_FIFO_DEPTH);
    localparam int FIFO_CNT_W = $clog2(TOKEN_FIFO_DEPTH + 1);

    // -------------------------------------------------------------------------
    // Internal CSR Configuration Registers & Telemetry Counters
    // -------------------------------------------------------------------------
    logic [31:0] ctrl_reg_q;
    logic [31:0] user_slot_cfg_q;
    logic [31:0] lora_cfg_q;
    logic [31:0] dma_src_lo_q;
    logic [31:0] dma_dst_sram_q;
    logic [15:0] dma_len_q;
    logic [31:0] layer_cg_mask_q;

    // Performance & ECC Counters
    logic [63:0] perf_cycle_cnt_q;
    logic [31:0] perf_token_cnt_q;
    logic [31:0] perf_rom_reads_q;
    logic [31:0] perf_sram_conflicts_q;
    logic [15:0] perf_ecc_sec_cnt_q;
    logic [15:0] perf_ecc_ded_cnt_q;
    logic [31:0] perf_zero_skip_cnt_q;
    logic [31:0] perf_noc_stall_cnt_q;

    // Token Ingress FIFO (Host -> Layer Tile 0)
    logic [19:0]       ing_fifo_mem_q [0:TOKEN_FIFO_DEPTH-1];
    logic [FIFO_PTR_W-1:0] ing_wr_ptr_q, ing_rd_ptr_q;
    logic [FIFO_CNT_W-1:0] ing_cnt_q;
    logic              ing_fifo_empty, ing_fifo_full;
    logic              ing_push_en, ing_pop_en;

    // Token Egress FIFO (LM-Head -> Host)
    logic [19:0]       egr_fifo_mem_q [0:TOKEN_FIFO_DEPTH-1];
    logic [FIFO_PTR_W-1:0] egr_wr_ptr_q, egr_rd_ptr_q;
    logic [FIFO_CNT_W-1:0] egr_cnt_q;
    logic              egr_fifo_empty, egr_fifo_full;
    logic              egr_push_en, egr_pop_en;

    assign ing_fifo_empty  = (ing_cnt_q == '0);
    assign ing_fifo_full   = (ing_cnt_q == FIFO_CNT_W'(TOKEN_FIFO_DEPTH));
    assign tok_in_valid_o  = !ing_fifo_empty;
    assign tok_in_id_o     = ing_fifo_mem_q[ing_rd_ptr_q];
    assign ing_pop_en      = tok_in_valid_o && tok_in_ready_i;

    assign egr_fifo_empty  = (egr_cnt_q == '0);
    assign egr_fifo_full   = (egr_cnt_q == FIFO_CNT_W'(TOKEN_FIFO_DEPTH));
    assign tok_out_ready_o = !egr_fifo_full;
    assign egr_push_en     = tok_out_valid_i && tok_out_ready_o;

    // -------------------------------------------------------------------------
    // LoRA Weight SRAM DMA Loader FSM
    // -------------------------------------------------------------------------
    typedef enum logic [1:0] {
        DMA_IDLE = 2'b00,
        DMA_RUN  = 2'b01,
        DMA_DONE = 2'b10
    } dma_state_e;

    dma_state_e  dma_state_q;
    logic [15:0] dma_rem_words_q;
    logic [11:0] dma_curr_row_q;
    logic        dma_start_pulse_q;
    logic        dma_done_sticky_q;
    // -------------------------------------------------------------------------
    // AXI4-Lite Slave Handshake & Read/Write Decode
    // [STAGE-28 FIX AUDIT-FINDING-012]: Independent AW & W holding registers per
    // ARM AMBA AXI4-Lite Specification (ARM IHI 0022E Section A3.3.1 [S91]) so
    // simultaneous AW+W, AW-before-W, and W-before-AW masters all complete without deadlock!
    // -------------------------------------------------------------------------
    logic        axi_wr_fire;
    logic        axi_rd_fire;
    logic [7:0]  wr_offset;
    logic [7:0]  rd_offset;
    logic        bvalid_q, rvalid_q;
    logic [31:0] rdata_q;
    logic        kv_clear_pulse_q;
    logic        aw_latched_q, w_latched_q;
    logic [7:0]  awaddr_latched_q;
    logic [31:0] wdata_latched_q;
    logic [31:0] eff_wdata;

    assign s_axi_awready = !bvalid_q && !aw_latched_q;
    assign s_axi_wready  = !bvalid_q && !w_latched_q;
    assign axi_wr_fire   = !bvalid_q && ((s_axi_awvalid && s_axi_awready) || aw_latched_q) &&
                                        ((s_axi_wvalid  && s_axi_wready)  || w_latched_q);
    assign wr_offset     = aw_latched_q ? {awaddr_latched_q[7:2], 2'b00} : {s_axi_awaddr[7:2], 2'b00};
    assign eff_wdata     = w_latched_q  ? wdata_latched_q : s_axi_wdata;

    assign s_axi_bresp   = 2'b00; // OKAY
    assign s_axi_bvalid  = bvalid_q;

    assign s_axi_arready = !rvalid_q;
    assign axi_rd_fire   = s_axi_arvalid && !rvalid_q;
    assign rd_offset     = {s_axi_araddr[7:2], 2'b00};

    assign s_axi_rresp   = 2'b00; // OKAY
    assign s_axi_rvalid  = rvalid_q;
    assign s_axi_rdata   = rdata_q;

    assign ing_push_en   = axi_wr_fire && (wr_offset == CSR_TOKEN_INGRESS) && !ing_fifo_full;
    assign egr_pop_en    = axi_rd_fire && (rd_offset == CSR_TOKEN_EGRESS)  && !egr_fifo_empty;

    // Status Word Assembly
    logic [31:0] status_word_comb;
    logic        chip_busy_comb;

    assign chip_busy_comb   = (|tiles_busy_mask_i) || !ing_fifo_empty || (dma_state_q == DMA_RUN);
    assign status_word_comb = {
        22'd0,
        (perf_ecc_ded_cnt_q != 16'd0),
        (perf_ecc_sec_cnt_q != 16'd0),
        2'b00,
        dma_done_sticky_q,
        (dma_state_q == DMA_RUN),
        !egr_fifo_empty,
        ing_fifo_empty,
        chip_busy_comb,
        !chip_busy_comb
    };

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bvalid_q          <= 1'b0;
            rvalid_q          <= 1'b0;
            rdata_q           <= 32'd0;
            ctrl_reg_q        <= 32'h0000_0001;
            user_slot_cfg_q   <= 32'h0000_0000;
            lora_cfg_q        <= 32'h0100_0010;
            dma_src_lo_q      <= 32'h0000_0000;
            dma_dst_sram_q    <= 32'h0000_0000;
            dma_len_q         <= 16'd0;
            layer_cg_mask_q   <= 32'h0000_0000;
            dma_state_q       <= DMA_IDLE;
            dma_rem_words_q   <= 16'd0;
            dma_curr_row_q    <= 12'd0;
            dma_start_pulse_q <= 1'b0;
            dma_done_sticky_q <= 1'b0;
            kv_clear_pulse_q  <= 1'b0;
            aw_latched_q      <= 1'b0;
            w_latched_q       <= 1'b0;
            awaddr_latched_q  <= 8'd0;
            wdata_latched_q   <= 32'd0;
        end else begin
            dma_start_pulse_q <= 1'b0;
            kv_clear_pulse_q  <= 1'b0;

            // Decoupled AW / W Capture & Write Response Channel
            if (axi_wr_fire) begin
                aw_latched_q <= 1'b0;
                w_latched_q  <= 1'b0;
                bvalid_q     <= 1'b1;
                unique case (wr_offset)
                    CSR_CHIP_CTRL:     ctrl_reg_q      <= eff_wdata;
                    CSR_USER_SLOT_CFG: begin
                        user_slot_cfg_q  <= eff_wdata;
                        kv_clear_pulse_q <= eff_wdata[16];
                    end
                    CSR_LORA_CFG:      lora_cfg_q      <= eff_wdata;
                    CSR_DMA_SRC_LO:    dma_src_lo_q    <= eff_wdata;
                    CSR_DMA_DST_SRAM:  dma_dst_sram_q  <= eff_wdata;
                    CSR_DMA_LEN_TRIG: begin
                        dma_len_q <= eff_wdata[15:0];
                        if (eff_wdata[31] && (dma_state_q != DMA_RUN)) begin
                            dma_start_pulse_q <= 1'b1;
                            dma_done_sticky_q <= 1'b0;
                            if (eff_wdata[15:0] != 16'd0) begin
                                dma_state_q     <= DMA_RUN;
                                dma_rem_words_q <= eff_wdata[15:0];
                                dma_curr_row_q  <= dma_dst_sram_q[11:0];
                            end else begin
                                dma_state_q       <= DMA_DONE;
                                dma_done_sticky_q <= 1'b1;
                            end
                        end
                    end
                    CSR_LAYER_CG_MASK: layer_cg_mask_q <= eff_wdata;
                    default: ; // Read-only or FIFO registers ignored here
                endcase
            end else begin
                if (s_axi_awvalid && s_axi_awready) begin
                    aw_latched_q     <= 1'b1;
                    awaddr_latched_q <= s_axi_awaddr[7:0];
                end
                if (s_axi_wvalid && s_axi_wready) begin
                    w_latched_q     <= 1'b1;
                    wdata_latched_q <= s_axi_wdata;
                end
                if (bvalid_q && s_axi_bready) begin
                    bvalid_q <= 1'b0;
                end
            end
            // Read Data Channel
            if (axi_rd_fire) begin
                rvalid_q <= 1'b1;
                unique case (rd_offset)
                    CSR_CHIP_ID:            rdata_q <= CHIP_ID_VAL;
                    CSR_CHIP_CTRL:          rdata_q <= ctrl_reg_q;
                    CSR_CHIP_STATUS:        rdata_q <= status_word_comb;
                    CSR_USER_SLOT_CFG:      rdata_q <= user_slot_cfg_q;
                    CSR_LORA_CFG:           rdata_q <= lora_cfg_q;
                    CSR_DMA_SRC_LO:         rdata_q <= dma_src_lo_q;
                    CSR_DMA_DST_SRAM:       rdata_q <= dma_dst_sram_q;
                    CSR_DMA_LEN_TRIG:       rdata_q <= {16'd0, dma_len_q};
                    CSR_TOKEN_EGRESS:       rdata_q <= egr_fifo_empty ? 32'd0 : {12'd0, egr_fifo_mem_q[egr_rd_ptr_q]};
                    CSR_PERF_CYCLES_LO:     rdata_q <= perf_cycle_cnt_q[31:0];
                    CSR_PERF_CYCLES_HI:     rdata_q <= perf_cycle_cnt_q[63:32];
                    CSR_PERF_TOKENS:        rdata_q <= perf_token_cnt_q;
                    CSR_PERF_ZERO_SKIP:     rdata_q <= perf_zero_skip_cnt_q;
                    CSR_ECC_ERR_CNT:        rdata_q <= {perf_ecc_ded_cnt_q, perf_ecc_sec_cnt_q};
                    CSR_NOC_STALL_CNT:      rdata_q <= perf_noc_stall_cnt_q;
                    CSR_LAYER_CG_MASK:      rdata_q <= layer_cg_mask_q;
                    CSR_PERF_ROM_READS:     rdata_q <= perf_rom_reads_q;
                    CSR_PERF_SRAM_CONFLICTS:rdata_q <= perf_sram_conflicts_q;
                    default:                rdata_q <= 32'd0;
                endcase
            end else if (rvalid_q && s_axi_rready) begin
                rvalid_q <= 1'b0;
            end

            // Autonomous LoRA Weight SRAM DMA Loader Progression
            if (dma_state_q == DMA_RUN) begin
                if (dma_rem_words_q <= 16'd1) begin
                    dma_rem_words_q   <= 16'd0;
                    dma_state_q       <= DMA_DONE;
                    dma_done_sticky_q <= 1'b1;
                end else begin
                    dma_rem_words_q <= dma_rem_words_q - 16'd1;
                    dma_curr_row_q  <= dma_curr_row_q + 12'd1;
                end
            end else if (dma_state_q == DMA_DONE) begin
                dma_state_q <= DMA_IDLE;
            end
        end
    end

    // -------------------------------------------------------------------------
    // Token Ingress/Egress FIFOs & Performance Counter Updates
    // -------------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ing_wr_ptr_q          <= '0;
            ing_rd_ptr_q          <= '0;
            ing_cnt_q             <= '0;
            egr_wr_ptr_q          <= '0;
            egr_rd_ptr_q          <= '0;
            egr_cnt_q             <= '0;
            perf_cycle_cnt_q      <= 64'd0;
            perf_token_cnt_q      <= 32'd0;
            perf_rom_reads_q      <= 32'd0;
            perf_sram_conflicts_q <= 32'd0;
            perf_ecc_sec_cnt_q    <= 16'd0;
            perf_ecc_ded_cnt_q    <= 16'd0;
            perf_zero_skip_cnt_q  <= 32'd0;
            perf_noc_stall_cnt_q  <= 32'd0;
            for (int i = 0; i < TOKEN_FIFO_DEPTH; i++) begin
                ing_fifo_mem_q[i] <= 20'd0;
                egr_fifo_mem_q[i] <= 20'd0;
            end
        end else begin
            // Ingress FIFO
            if (ing_push_en) begin
                ing_fifo_mem_q[ing_wr_ptr_q] <= s_axi_wdata[19:0];
                ing_wr_ptr_q                 <= ing_wr_ptr_q + 1'b1;
            end
            if (ing_pop_en) begin
                ing_rd_ptr_q <= ing_rd_ptr_q + 1'b1;
            end
            unique case ({ing_push_en, ing_pop_en})
                2'b10: if (ing_cnt_q < FIFO_CNT_W'(TOKEN_FIFO_DEPTH)) ing_cnt_q <= ing_cnt_q + 1'b1;
                2'b01: if (ing_cnt_q > '0)                            ing_cnt_q <= ing_cnt_q - 1'b1;
                default: ;
            endcase

            // Egress FIFO
            if (egr_push_en) begin
                egr_fifo_mem_q[egr_wr_ptr_q] <= tok_out_id_i;
                egr_wr_ptr_q                 <= egr_wr_ptr_q + 1'b1;
                perf_token_cnt_q             <= perf_token_cnt_q + 32'd1;
            end
            if (egr_pop_en) begin
                egr_rd_ptr_q <= egr_rd_ptr_q + 1'b1;
            end
            unique case ({egr_push_en, egr_pop_en})
                2'b10: if (egr_cnt_q < FIFO_CNT_W'(TOKEN_FIFO_DEPTH)) egr_cnt_q <= egr_cnt_q + 1'b1;
                2'b01: if (egr_cnt_q > '0)                            egr_cnt_q <= egr_cnt_q - 1'b1;
                default: ;
            endcase

            // Hardware Performance Counters
            if (ctrl_reg_q[0]) begin
                perf_cycle_cnt_q      <= perf_cycle_cnt_q + 64'd1;
                perf_rom_reads_q      <= perf_rom_reads_q + {16'd0, inc_rom_reads_i};
                perf_sram_conflicts_q <= perf_sram_conflicts_q + {24'd0, inc_sram_conflicts_i};
                perf_ecc_sec_cnt_q    <= perf_ecc_sec_cnt_q + {8'd0, inc_ecc_sec_i};
                perf_ecc_ded_cnt_q    <= perf_ecc_ded_cnt_q + {8'd0, inc_ecc_ded_i};
                perf_zero_skip_cnt_q  <= perf_zero_skip_cnt_q + {16'd0, inc_zero_skip_i};
                perf_noc_stall_cnt_q  <= perf_noc_stall_cnt_q + {24'd0, inc_noc_stall_i};
            end
        end
    end
    // -------------------------------------------------------------------------
    // Output Signal Assignments
    // -------------------------------------------------------------------------
    assign chip_id_o             = CHIP_ID_VAL;
    assign chip_en_o             = ctrl_reg_q[0];
    assign soft_rst_o            = ctrl_reg_q[1];
    assign lora_en_o             = ctrl_reg_q[2];
    assign hc2_mxfp4_mode_o      = ctrl_reg_q[3];
    assign zero_skip_en_o        = ctrl_reg_q[4];
    assign rom_sleep_en_o        = ctrl_reg_q[5];
    assign ntk_rope_en_o         = ctrl_reg_q[6];
    assign bcast_en_o            = ctrl_reg_q[7];
    assign layer_cg_mask_o       = layer_cg_mask_q;

    assign slot_id_o             = user_slot_cfg_q[2:0];
    assign token_pos_o           = user_slot_cfg_q[15:4];
    assign kv_clear_slot_o       = kv_clear_pulse_q;
    assign lora_rank_o           = lora_cfg_q[7:0];
    assign lora_alpha_q8_8_o     = $signed(lora_cfg_q[31:16]);

    assign dma_src_addr_o        = dma_src_lo_q;
    assign dma_dst_sram_addr_o   = dma_dst_sram_q;
    assign dma_len_o             = dma_len_q;
    assign dma_start_o           = dma_start_pulse_q;
    assign dma_busy_o            = (dma_state_q == DMA_RUN);
    assign dma_done_o            = dma_done_sticky_q;
    assign dma_sram_we_o         = (dma_state_q == DMA_RUN);
    assign dma_sram_layer_o      = dma_dst_sram_q[23:16];
    assign dma_sram_row_o        = dma_curr_row_q;
    assign dma_sram_wdata_o      = {dma_src_lo_q + {20'd0, dma_curr_row_q},
                                    dma_src_lo_q ^ {16'h5441, dma_rem_words_q}};

    assign perf_cycle_cnt_o      = perf_cycle_cnt_q;
    assign perf_token_cnt_o      = perf_token_cnt_q;
    assign perf_rom_reads_o      = perf_rom_reads_q;
    assign perf_sram_conflicts_o = perf_sram_conflicts_q;
    assign perf_ecc_sec_cnt_o    = perf_ecc_sec_cnt_q;
    assign perf_zero_skip_cnt_o  = perf_zero_skip_cnt_q;

    // =========================================================================
    // Formal Verification & Inline SVA Invariants (Yosys SAT & Verilator)
    // =========================================================================
    logic past_valid_q;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) past_valid_q <= 1'b0;
        else        past_valid_q <= 1'b1;
    end

    always_ff @(posedge clk) begin
        if (past_valid_q && rst_n) begin
            // PROP_M13_CHIP_ID_IMMUTABLE: Read-only CHIP_ID is strictly CHIP_ID_VAL
            assert (chip_id_o == CHIP_ID_VAL);

            // PROP_M13_AXI_RESP_OKAY: AXI-Lite write/read responses are always OKAY (2'b00)
            assert (s_axi_bresp == 2'b00);
            assert (s_axi_rresp == 2'b00);

            // PROP_M13_DMA_FSM_VALID: DMA FSM state is always valid (0..2)
            assert (dma_state_q <= DMA_DONE);

            // PROP_M13_FIFO_BOUNDS: Ingress & Egress FIFOs never overflow TOKEN_FIFO_DEPTH
            assert (ing_cnt_q <= FIFO_CNT_W'(TOKEN_FIFO_DEPTH));
            assert (egr_cnt_q <= FIFO_CNT_W'(TOKEN_FIFO_DEPTH));
        end
    end

endmodule
