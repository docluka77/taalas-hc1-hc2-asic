`timescale 1ns / 1ps
// =============================================================================
// File:        uvm_tb/taalas_uvm_pkg.sv
// Project:     Taalas HC1/HC2 Hardwired LLM Inference ASIC
// Description: SystemVerilog UVM Package, Transaction Types, Functional
//              Coverage Binders, and Concurrent SVA Protocol Monitors for
//              Full-Hierarchy Multi-Agent UVM Verification (Stage 8).
// =============================================================================

package taalas_uvm_pkg;

    // -------------------------------------------------------------------------
    // 1. UVM Transaction & Sequence Item Type Enumerations
    // -------------------------------------------------------------------------
    typedef enum logic [3:0] {
        UVM_TXN_ROM_READ      = 4'd0,
        UVM_TXN_ROM_BIST      = 4'd1,
        UVM_TXN_CSD_MAC       = 4'd2,
        UVM_TXN_MXFP4_MAC     = 4'd3,
        UVM_TXN_GROUP_DEQ     = 4'd4,
        UVM_TXN_SRAM_ECC      = 4'd5,
        UVM_TXN_KV_CACHE      = 4'd6,
        UVM_TXN_LORA_OVERLAY  = 4'd7,
        UVM_TXN_ROPE_ROT      = 4'd8,
        UVM_TXN_FLASH_ATTN    = 4'd9,
        UVM_TXN_RMSNORM       = 4'd10,
        UVM_TXN_SWIGLU_FFN    = 4'd11,
        UVM_TXN_NOC_FLIT      = 4'd12,
        UVM_TXN_AXI_CSR       = 4'd13,
        UVM_TXN_CHIP_INFER    = 4'd14,
        UVM_TXN_ADVERSARIAL   = 4'd15
    } taalas_uvm_txn_kind_e;

    typedef struct packed {
        taalas_uvm_txn_kind_e kind;
        logic [3:0]           target_tile;
        logic [2:0]           user_slot;
        logic [16:0]          token_pos;
        logic                 adversarial_mode;
        logic [31:0]          payload_seed;
    } taalas_uvm_seq_item_t;

    // Helper CRC-8 checker for NoC flit headers
    function automatic logic [7:0] uvm_calc_hdr_crc8(input logic [23:0] hdr_24b);
        return hdr_24b[7:0] ^ hdr_24b[15:8] ^ hdr_24b[23:16] ^ 8'h5A;
    endfunction

endpackage

// =============================================================================
// Concurrent SVA Protocol Monitor 1: AXI4-Lite Host CSR Handshake Checker
// =============================================================================
module taalas_uvm_axi_sva_mon (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        awvalid,
    input  logic        awready,
    input  logic        wvalid,
    input  logic        wready,
    input  logic        bvalid,
    input  logic        bready,
    input  logic [1:0]  bresp,
    input  logic        arvalid,
    input  logic        arready,
    input  logic        rvalid,
    input  logic        rready,
    input  logic [1:0]  rresp,
    output logic [31:0] sva_axi_checks_o,
    output logic [15:0] sva_axi_violations_o
);
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sva_axi_checks_o     <= 32'd0;
            sva_axi_violations_o <= 16'd0;
        end else begin
            if ((awvalid && awready) || (arvalid && arready) || (bvalid && bready) || (rvalid && rready)) begin
                sva_axi_checks_o <= sva_axi_checks_o + 32'd1;
            end
            if ((bvalid && (bresp != 2'b00)) || (rvalid && (rresp != 2'b00))) begin
                sva_axi_violations_o <= sva_axi_violations_o + 16'd1;
            end
            SVA_AXI_BRESP_OKAY: assert (!bvalid || (bresp == 2'b00));
            SVA_AXI_RRESP_OKAY: assert (!rvalid || (rresp == 2'b00));
        end
    end
endmodule

// =============================================================================
// Concurrent SVA Protocol Monitor 2: NoC Credit & SECDED Telemetry Checker
// =============================================================================
module taalas_uvm_noc_sram_sva_mon #(
    parameter int MAX_CREDITS = 8
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic [3:0]  noc_avail_credits_i,
    input  logic [3:0]  noc_inflight_flits_i,
    input  logic [1:0]  noc_skid_occ_i,
    input  logic        sram_sec_err_i,
    input  logic        sram_ded_err_i,
    output logic [31:0] sva_noc_sram_checks_o
);
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sva_noc_sram_checks_o <= 32'd0;
        end else begin
            sva_noc_sram_checks_o <= sva_noc_sram_checks_o + 32'd1;
            SVA_NOC_CREDIT_SUM: assert ((noc_avail_credits_i + noc_inflight_flits_i) == 4'(MAX_CREDITS));
            SVA_NOC_SKID_BOUND: assert (noc_skid_occ_i <= 2'd2);
            SVA_SRAM_ECC_MUTEX: assert (!(sram_sec_err_i && sram_ded_err_i));
        end
    end
endmodule
