`timescale 1ns / 1ps
`include "uvm_macros.svh"

// =============================================================================
// File:        uvm_tb/tb_sv_uvm_taalas_top.sv
// Project:     Taalas HC1/HC2 Hardwired LLM Inference ASIC
// Description: Native Accellera IEEE 1800.2 SystemVerilog UVM-2020.3.1
//              Verification Environment (uvm_sequence_item, uvm_sequence,
//              uvm_sequencer, uvm_driver, uvm_monitor, uvm_scoreboard,
//              uvm_env, uvm_test) Compiled with Verilator 5.054 (--timing).
// =============================================================================

interface taalas_sv_uvm_if (input logic clk);
    logic        rst_n            = 1'b0;
    logic [63:0] stim_seed_lo     = 64'd0;
    logic [63:0] stim_seed_hi     = 64'd0;
    logic [3:0]  stim_fill_mode   = 4'd0;

    // Key Control Signals Across M1..M15
    logic        m1_cs_en         = 1'b1;
    logic        m1_bist_start    = 1'b0;
    logic        m1_rvalid;
    logic        m1_bist_done;
    logic        m1_bist_pass;

    logic        m2_valid         = 1'b0;
    logic        m2_zero_skip_en  = 1'b1;
    logic        m2_valid_o;
    logic signed [23:0] m2_acc_ch0_o;

    logic        m3_valid         = 1'b0;
    logic [7:0]  m3_act_e8m0      = 8'd127;
    logic [7:0]  m3_w_e8m0        = 8'd127;
    logic [3:0]  m3_force_act     = 4'd2;
    logic [3:0]  m3_force_w       = 4'd2;
    logic        m3_use_force     = 1'b0;
    logic        m3_valid_o;
    logic signed [15:0] m3_dot_l0_o;
    logic [31:0] m3_fp32_l0_o;

    logic        m4_valid         = 1'b0;
    logic        m4_first_grp     = 1'b1;
    logic        m4_last_grp      = 1'b1;
    logic        m4_valid_o;

    logic        m5_req_valid     = 1'b0;
    logic        m5_req_we        = 1'b0;
    logic [3:0]  m5_req_bank      = 4'd0;
    logic [4:0]  m5_req_row       = 5'd0;
    logic [63:0] m5_req_wdata     = 64'd0;
    logic [7:0]  m5_req_wmask     = 8'hFF;
    logic        m5_err_inj_en    = 1'b0;
    logic [63:0] m5_err_inj_lo    = 64'd0;
    logic        m5_resp_valid_o;
    logic        m5_sec_err_o;
    logic        m5_ded_err_o;
    logic [15:0] m5_ded_cnt_o;

    logic [1:0]  m6_slot_id       = 2'd0;
    logic [2:0]  m6_kv_head_id    = 3'd0;
    logic        m6_append_en     = 1'b0;
    logic        m6_read_seq_en   = 1'b0;
    logic        m6_sliding_win   = 1'b1;
    logic [3:0]  m6_sink_cfg      = 4'd4;
    logic [3:0]  m6_wr_ptr_o;
    logic        m6_kv_valid_o;

    logic        m7_valid         = 1'b0;
    logic        m7_lora_en       = 1'b1;
    logic [2:0]  m7_skew_delay    = 3'd1;
    logic        m7_valid_o;

    logic        m8_valid         = 1'b0;
    logic [16:0] m8_token_pos     = 17'd0;
    logic        m8_ntk_scale_en  = 1'b0;
    logic        m8_valid_o;

    logic        m9_start_seq     = 1'b0;
    logic        m9_kv_valid      = 1'b0;
    logic        m9_kv_last       = 1'b0;
    logic signed [15:0] m9_q_elem = 16'sd0;
    logic signed [15:0] m9_k_elem = 16'sd0;
    logic signed [15:0] m9_v_elem = 16'sd256;
    logic        m9_out_valid_o;
    logic signed [15:0] m9_attn_h0_d0_o;

    logic        m10_start        = 1'b0;
    logic        m10_in_valid     = 1'b1;
    logic signed [15:0] m10_x_elem= 16'sd256;
    logic        m10_use_unif     = 1'b0;
    logic        m10_out_valid_o;
    logic [15:0] m10_inv_rms_o;

    logic        m11_valid        = 1'b0;
    logic        m11_down_valid_o;

    logic        m12_in_valid     = 1'b0;
    logic        m12_loc_tx_valid = 1'b0;
    logic [31:0] m12_in_hdr       = 32'h800800DA;
    logic        m12_up_cred_o;
    logic        m12_crc_err_o;

    logic [15:0] axi_awaddr       = 16'd0;
    logic        axi_awvalid      = 1'b0;
    logic [31:0] axi_wdata        = 32'd0;
    logic        axi_wvalid       = 1'b0;
    logic        m14_noc_in_valid = 1'b0;
    logic [31:0] sva_checks_o;
    logic [15:0] sva_violations_o;
endinterface
package taalas_sv_uvm_test_pkg;
    import uvm_pkg::*;

    class taalas_sv_uvm_item extends uvm_sequence_item;
        `uvm_object_utils(taalas_sv_uvm_item)
        int unsigned txn_id;
        bit [1:0]    phase_kind; // 0=DIRECTED, 1=RANDOM, 2=ADVERSARIAL
        bit [63:0]   seed_lo;
        bit [63:0]   seed_hi;
        bit [3:0]    fill_mode;
        bit [7:0]    act_e8m0;
        bit [7:0]    w_e8m0;
        bit [3:0]    adv_bug_id;

        // Observed outputs
        logic signed [15:0] obs_m9_attn;
        logic [31:0]        obs_m3_fp32;
        logic               obs_m12_up_cred;
        logic               obs_m12_crc_err;
        logic [3:0]         obs_m6_wr_ptr;
        logic [15:0]        obs_m10_inv_rms;

        function new(string name = "taalas_sv_uvm_item");
            super.new(name);
        endfunction
    endclass

    class taalas_sv_uvm_sequence extends uvm_sequence #(taalas_sv_uvm_item);
        `uvm_object_utils(taalas_sv_uvm_sequence)
        function new(string name = "taalas_sv_uvm_sequence");
            super.new(name);
        endfunction

        task body();
            bit [63:0] lfsr = 64'h5441_414C_4843_3132;
            // 1. Directed & Constrained-Random Multi-Module Sequence Items (256 SV UVM transactions)
            for (int i = 0; i < 256; i++) begin
                taalas_sv_uvm_item item = taalas_sv_uvm_item::type_id::create("item");
                start_item(item);
                lfsr = {lfsr[62:0], lfsr[63] ^ lfsr[61] ^ lfsr[3] ^ lfsr[0]};
                item.txn_id     = i;
                item.phase_kind = (i < 64) ? 2'd0 : 2'd1;
                item.seed_lo    = lfsr;
                item.seed_hi    = ~lfsr ^ (64'h9E37_79B9 * i);
                item.fill_mode  = 4'(i % 7);
                item.act_e8m0   = 8'((i == 0) ? 0 : (i == 1) ? 255 : (110 + (i & 31)));
                item.w_e8m0     = 8'((i == 2) ? 255 : 127);
                item.adv_bug_id = 4'd0;
                finish_item(item);
            end

            // 2. Adversarial Bug-Discovery Sequence Items (BUG-HC1-001 .. BUG-HC1-008)
            for (int b = 1; b <= 8; b++) begin
                taalas_sv_uvm_item adv = taalas_sv_uvm_item::type_id::create("adv_item");
                start_item(adv);
                adv.txn_id     = 1000 + b;
                adv.phase_kind = 2'd2;
                adv.adv_bug_id = 4'(b);
                adv.seed_lo    = 64'hDEAD_BEEF_CAFE_0000 + b;
                adv.seed_hi    = 64'h1234_5678_9ABC_DEF0;
                finish_item(adv);
            end
        endtask
    endclass

    class taalas_sv_uvm_driver extends uvm_driver #(taalas_sv_uvm_item);
        `uvm_component_utils(taalas_sv_uvm_driver)
        virtual taalas_sv_uvm_if vif;
        int unsigned driven_cnt = 0;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db#(virtual taalas_sv_uvm_if)::get(this, "", "vif", vif))
                `uvm_fatal("NO_VIF", "Virtual interface taalas_sv_uvm_if missing in driver")
        endfunction

        task run_phase(uvm_phase phase);
            taalas_sv_uvm_item item;
            wait (vif.rst_n === 1'b1);
            forever begin
                seq_item_port.get_next_item(item);
                @(negedge vif.clk);
                vif.stim_seed_lo   = item.seed_lo;
                vif.stim_seed_hi   = item.seed_hi;
                vif.stim_fill_mode = item.fill_mode;
                if (item.phase_kind != 2'd2) begin
                    vif.m1_cs_en        = 1'b1;
                    vif.m1_bist_start   = (item.txn_id == 0);
                    vif.m2_valid        = 1'b1;
                    vif.m3_valid        = 1'b1;
                    vif.m3_use_force    = 1'b0;
                    vif.m3_act_e8m0     = item.act_e8m0;
                    vif.m3_w_e8m0       = item.w_e8m0;
                    vif.m4_valid        = 1'b1;
                    vif.m5_req_valid    = 1'b1;
                    vif.m5_req_we       = item.txn_id[0];
                    vif.m5_req_bank     = item.seed_lo[3:0];
                    vif.m5_req_row      = item.seed_lo[8:4];
                    vif.m5_req_wdata    = item.seed_lo;
                    vif.m6_append_en    = (item.txn_id[2:0] == 3'd0);
                    vif.m7_valid        = 1'b1;
                    vif.m8_valid        = 1'b1;
                    vif.m8_token_pos    = item.seed_lo[16:0];
                    vif.m9_kv_valid     = 1'b1;
                    vif.m9_kv_last      = (item.txn_id[2:0] == 3'd7);
                    vif.m10_start       = (item.txn_id[3:0] == 4'd0);
                    vif.m11_valid       = 1'b1;
                    vif.m12_in_valid    = 1'b1;
                    @(negedge vif.clk);
                    vif.m6_append_en    = 1'b0;
                    vif.m10_start       = 1'b0;
                end else begin
                    drive_adversarial_bug(item);
                end
                driven_cnt++;
                seq_item_port.item_done();
            end
        endtask
        task drive_adversarial_bug(taalas_sv_uvm_item item);
            if (item.adv_bug_id == 4'd1) begin
                // BUG-HC1-001: Flash-Decode 2-token equal-score reciprocal scaling bug
                vif.m9_start_seq = 1'b1; vif.m9_kv_valid = 1'b0; @(negedge vif.clk);
                vif.m9_start_seq = 1'b0;
                for (int t = 0; t < 2; t++) begin
                    vif.m9_kv_valid = 1'b1;
                    vif.m9_kv_last  = (t == 1);
                    vif.m9_q_elem   = 16'sd0;
                    vif.m9_k_elem   = 16'sd0;
                    vif.m9_v_elem   = 16'sd256;
                    @(negedge vif.clk);
                end
                vif.m9_kv_valid = 1'b0; vif.m9_kv_last = 1'b0;
                repeat (2) @(negedge vif.clk);
            end else if (item.adv_bug_id == 4'd2) begin
                // BUG-HC1-002: RMSNorm m_q14 in [8192,16383] bit-13 LUT indexing bug
                vif.m10_use_unif = 1'b1;
                vif.m10_x_elem   = 16'sd185;
                vif.m10_start    = 1'b1;
                @(negedge vif.clk);
                vif.m10_start    = 1'b0;
                repeat (8) @(negedge vif.clk);
                vif.m10_use_unif = 1'b0;
            end else if (item.adv_bug_id == 4'd5) begin
                // BUG-HC1-005: MXFP4 E8M0=8'hFF NaN scale bug
                vif.m3_use_force = 1'b1;
                vif.m3_force_act = 4'd2;
                vif.m3_force_w   = 4'd2;
                vif.m3_act_e8m0  = 8'd2;
                vif.m3_w_e8m0    = 8'd255;
                vif.m3_valid     = 1'b1;
                repeat (4) @(negedge vif.clk);
                vif.m3_use_force = 1'b0;
            end else if (item.adv_bug_id == 4'd7) begin
                // BUG-HC1-007: NoC local_tx phantom credit return & rx_crc8==0 waiver
                vif.m12_in_valid     = 1'b0;
                vif.m12_loc_tx_valid = 1'b1;
                vif.m12_in_hdr       = 32'h8020_0100;
                @(negedge vif.clk);
                vif.m12_loc_tx_valid = 1'b0;
                repeat (3) @(negedge vif.clk);
            end else begin
                @(negedge vif.clk);
            end
        endtask
    endclass

    class taalas_sv_uvm_monitor extends uvm_monitor;
        `uvm_component_utils(taalas_sv_uvm_monitor)
        virtual taalas_sv_uvm_if vif;
        uvm_analysis_port #(taalas_sv_uvm_item) ap;
        int unsigned observed_cnt = 0;

        function new(string name, uvm_component parent);
            super.new(name, parent);
            ap = new("ap", this);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db#(virtual taalas_sv_uvm_if)::get(this, "", "vif", vif))
                `uvm_fatal("NO_VIF", "Virtual interface taalas_sv_uvm_if missing in monitor")
        endfunction

        task run_phase(uvm_phase phase);
            forever begin
                @(posedge vif.clk);
                #1ps;
                if (vif.rst_n) begin
                    taalas_sv_uvm_item obs = taalas_sv_uvm_item::type_id::create("obs");
                    obs.fill_mode       = vif.stim_fill_mode;
                    obs.act_e8m0        = vif.m3_act_e8m0;
                    obs.w_e8m0          = vif.m3_w_e8m0;
                    obs.obs_m9_attn     = vif.m9_attn_h0_d0_o;
                    obs.obs_m3_fp32     = vif.m3_fp32_l0_o;
                    obs.obs_m12_up_cred = vif.m12_up_cred_o;
                    obs.obs_m12_crc_err = vif.m12_crc_err_o;
                    obs.obs_m6_wr_ptr   = vif.m6_wr_ptr_o;
                    obs.obs_m10_inv_rms = vif.m10_inv_rms_o;
                    observed_cnt++;
                    ap.write(obs);
                end
            end
        endtask
    endclass

    // -------------------------------------------------------------------------
    // 5. UVM Scoreboard & Functional Coverage Subscriber
    // -------------------------------------------------------------------------
    class taalas_sv_uvm_scoreboard extends uvm_scoreboard;
        `uvm_component_utils(taalas_sv_uvm_scoreboard)
        uvm_analysis_imp #(taalas_sv_uvm_item, taalas_sv_uvm_scoreboard) analysis_export;
        int unsigned total_obs   = 0;
        int unsigned bug1_hits   = 0;
        int unsigned bug2_hits   = 0;
        int unsigned bug5_hits   = 0;
        int unsigned bug7_hits   = 0;
        bit          fill_bins[4];

        function new(string name, uvm_component parent);
            super.new(name, parent);
            analysis_export = new("analysis_export", this);
        endfunction

        function void write(taalas_sv_uvm_item t);
            total_obs++;
            fill_bins[t.fill_mode] = 1'b1;
            if (t.obs_m9_attn == 16'sd752) bug1_hits++;
            if (t.obs_m10_inv_rms == 16'h4924) bug2_hits++;
            if (t.w_e8m0 == 8'd255 && t.obs_m3_fp32 != 32'h7FC0_0000) bug5_hits++;
            if (t.obs_m12_up_cred) bug7_hits++;
        endfunction

        function void report_phase(uvm_phase phase);
            super.report_phase(phase);
            `uvm_info("TAALAS_SV_SB", $sformatf(
                "Accellera SV UVM-2020.3.1 Summary: total_obs=%0d | BUG1_hits=%0d BUG2_hits=%0d BUG5_hits=%0d BUG7_hits=%0d",
                total_obs, bug1_hits, bug2_hits, bug5_hits, bug7_hits), UVM_LOW)
        endfunction
    endclass

    // -------------------------------------------------------------------------
    // 6. UVM Environment & Top-Level Test
    // -------------------------------------------------------------------------
    class taalas_sv_uvm_env extends uvm_env;
        `uvm_component_utils(taalas_sv_uvm_env)
        uvm_sequencer #(taalas_sv_uvm_item) sqr;
        taalas_sv_uvm_driver                drv;
        taalas_sv_uvm_monitor               mon;
        taalas_sv_uvm_scoreboard            sb;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            sqr = uvm_sequencer#(taalas_sv_uvm_item)::type_id::create("sqr", this);
            drv = taalas_sv_uvm_driver::type_id::create("drv", this);
            mon = taalas_sv_uvm_monitor::type_id::create("mon", this);
            sb  = taalas_sv_uvm_scoreboard::type_id::create("sb", this);
        endfunction

        function void connect_phase(uvm_phase phase);
            super.connect_phase(phase);
            drv.seq_item_port.connect(sqr.seq_item_export);
            mon.ap.connect(sb.analysis_export);
        endfunction
    endclass

    class taalas_full_uvm_test extends uvm_test;
        `uvm_component_utils(taalas_full_uvm_test)
        taalas_sv_uvm_env env;

        function new(string name = "taalas_full_uvm_test", uvm_component parent = null);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            env = taalas_sv_uvm_env::type_id::create("env", this);
        endfunction

        task run_phase(uvm_phase phase);
            taalas_sv_uvm_sequence seq;
            phase.raise_objection(this, "Running Taalas Full-Hierarchy SV UVM-2020.3.1 Test");
            seq = taalas_sv_uvm_sequence::type_id::create("seq");
            seq.start(env.sqr);
            #100ns;
            phase.drop_objection(this, "Completed Taalas Full-Hierarchy SV UVM-2020.3.1 Test");
        endtask
    endclass
endpackage

// =============================================================================
// 7. Top-Level SystemVerilog UVM Testbench Module (`tb_sv_uvm_taalas_top`)
// =============================================================================
module tb_sv_uvm_taalas_top;
    import uvm_pkg::*;
    import taalas_sv_uvm_test_pkg::*;

    logic clk = 1'b0;
    always #5ns clk = ~clk;

    taalas_sv_uvm_if vif(clk);

    /* verilator lint_off PINCONNECTEMPTY */
    taalas_uvm_all_modules_top u_dut (
        .clk                    (clk),
        .rst_n                  (vif.rst_n),
        .stim_seed_lo_i         (vif.stim_seed_lo),
        .stim_seed_hi_i         (vif.stim_seed_hi),
        .stim_fill_mode_i       (vif.stim_fill_mode),
        .m1_sleep_n_i           (1'b1),
        .m1_sleep_i             (1'b0),
        .m1_iso_en_i            (1'b0),
        .m1_cs_en_i             (vif.m1_cs_en),
        .m1_prech_en_i          (1'b0),
        .m1_sa_en_i             (1'b1),
        .m1_bank_sel_i          (vif.stim_seed_lo[1:0]),
        .m1_addr_i              (vif.stim_seed_lo[5:2]),
        .m1_prog_en_i           (1'b0),
        .m1_prog_bank_i         (2'd0),
        .m1_prog_row_i          (4'd0),
        .m1_bist_start_i        (vif.m1_bist_start),
        .m1_bist_busy_o         (),
        .m1_bist_done_o         (vif.m1_bist_done),
        .m1_bist_crc16_o        (),
        .m1_bist_pass_o         (vif.m1_bist_pass),
        .m1_rvalid_o            (vif.m1_rvalid),
        .m1_active_vias_o       (),
        .m1_rdata_lo_o          (),
        .m2_valid_i             (vif.m2_valid),
        .m2_zero_skip_en_i      (vif.m2_zero_skip_en),
        .m2_force_w3b_i         (3'd0),
        .m2_use_force_w_i       (1'b0),
        .m2_valid_o             (vif.m2_valid_o),
        .m2_acc_ch0_o           (vif.m2_acc_ch0_o),
        .m2_act_sum_o           (),
        .m2_zero_ops_saved_o    (),
        .m3_valid_i             (vif.m3_valid),
        .m3_act_e8m0_i          (vif.m3_act_e8m0),
        .m3_w_e8m0_i            (vif.m3_w_e8m0),
        .m3_force_act_code_i    (vif.m3_force_act),
        .m3_force_w_code_i      (vif.m3_force_w),
        .m3_use_force_code_i    (vif.m3_use_force),
        .m3_valid_o             (vif.m3_valid_o),
        .m3_dot_l0_o            (vif.m3_dot_l0_o),
        .m3_exp_l0_o            (),
        .m3_fp32_l0_o           (vif.m3_fp32_l0_o),
        .m4_valid_i             (vif.m4_valid),
        .m4_first_grp_i         (vif.m4_first_grp),
        .m4_last_grp_i          (vif.m4_last_grp),
        .m4_raw_acc_ch0_i       (24'sd1024),
        .m4_act_sum_i           (16'sd256),
        .m4_w_scale_ch0_i       (16'sd256),
        .m4_act_scale_i         (16'sd256),
        .m4_w_zp_ch0_i          (8'sd0),
        .m4_lora_delta_ch0_i    (16'sd16),
        .m4_lora_en_i           (1'b1),
        .m4_valid_o             (vif.m4_valid_o),
        .m4_deq_ch0_o           (),
        .m4_sat_flag_o          (),
        .m5_ret_sleep_i         (1'b0),
        .m5_bank_cg_en_i        (16'h0000),
        .m5_req_valid_i         (vif.m5_req_valid),
        .m5_req_we_i            (vif.m5_req_we),
        .m5_req_bank_i          (vif.m5_req_bank),
        .m5_req_row_i           (vif.m5_req_row),
        .m5_req_wdata_i         (vif.m5_req_wdata),
        .m5_req_wmask_i         (vif.m5_req_wmask),
        .m5_vec_req_valid_i     (16'h0000),
        .m5_err_inj_en_i        (vif.m5_err_inj_en),
        .m5_err_inj_lo_i        (vif.m5_err_inj_lo),
        .m5_err_inj_hi_i        (8'h00),
        .m5_resp_valid_o        (vif.m5_resp_valid_o),
        .m5_resp_rdata_o        (),
        .m5_phys_bank_o         (),
        .m5_sec_err_o           (vif.m5_sec_err_o),
        .m5_ded_err_o           (vif.m5_ded_err_o),
        .m5_err_syndrome_o      (),
        .m5_sec_cnt_o           (),
        .m5_ded_cnt_o           (vif.m5_ded_cnt_o),
        .m5_conflict_free_o     (),
        .m6_slot_id_i           (vif.m6_slot_id),
        .m6_kv_head_id_i        (vif.m6_kv_head_id),
        .m6_append_en_i         (vif.m6_append_en),
        .m6_read_seq_en_i       (vif.m6_read_seq_en),
        .m6_clear_slot_i        (1'b0),
        .m6_sliding_win_en_i    (vif.m6_sliding_win),
        .m6_sink_tokens_cfg_i   (vif.m6_sink_cfg),
        .m6_k_scale_i           (16'h0100),
        .m6_v_scale_i           (16'h0100),
        .m6_k_zp_i              (4'd0),
        .m6_v_zp_i              (4'd0),
        .m6_kv_valid_o          (vif.m6_kv_valid_o),
        .m6_kv_last_o           (),
        .m6_seq_done_o          (),
        .m6_fsm_state_o         (),
        .m6_wr_ptr_o            (vif.m6_wr_ptr_o),
        .m6_rd_ptr_o            (),
        .m6_curr_seq_len_o      (),
        .m6_eviction_cnt_o      (),
        .m6_k_deq_lo_o          (),
        .m6_v_deq_lo_o          (),
        .m7_valid_i             (vif.m7_valid),
        .m7_lora_en_i           (vif.m7_lora_en),
        .m7_active_rank_i       (8'd16),
        .m7_alpha_q88_i         (16'sd256),
        .m7_skew_delay_i        (vif.m7_skew_delay),
        .m7_ext_weights_en_i    (1'b0),
        .m7_sram_we_i           (1'b0),
        .m7_sram_sel_b_i        (1'b0),
        .m7_sram_row_addr_i     (6'd0),
        .m7_valid_o             (vif.m7_valid_o),
        .m7_delta_ch0_o         (),
        .m7_latent_r0_o         (),
        .m7_stall_cycles_o      (),
        .m8_valid_i             (vif.m8_valid),
        .m8_is_key_i            (1'b0),
        .m8_head_id_i           (6'd0),
        .m8_pair_chunk_idx_i    (3'd0),
        .m8_token_pos_i         (vif.m8_token_pos),
        .m8_ntk_scale_en_i      (vif.m8_ntk_scale_en),
        .m8_bypass_en_i         (1'b0),
        .m8_valid_o             (vif.m8_valid_o),
        .m8_y_re0_o             (),
        .m8_y_im0_o             (),
        .m8_cos0_o              (),
        .m8_sin0_o              (),
        .m8_zero_pos_id_o       (),
        .m8_sat_cnt_o           (),
        .m9_start_seq_i         (vif.m9_start_seq),
        .m9_kv_valid_i          (vif.m9_kv_valid),
        .m9_kv_last_i           (vif.m9_kv_last),
        .m9_scale_log2e_i       (16'd5909),
        .m9_q_elem_i            (vif.m9_q_elem),
        .m9_k_elem_i            (vif.m9_k_elem),
        .m9_v_elem_i            (vif.m9_v_elem),
        .m9_step_valid_o        (),
        .m9_out_valid_o         (vif.m9_out_valid_o),
        .m9_attn_h0_d0_o        (vif.m9_attn_h0_d0_o),
        .m9_max_score_h0_o      (),
        .m9_denom_sum_h0_o      (),
        .m10_start_i            (vif.m10_start),
        .m10_in_valid_i         (vif.m10_in_valid),
        .m10_eps_q16_i          (16'd1),
        .m10_ext_gamma_en_i     (1'b0),
        .m10_x_elem_i           (vif.m10_x_elem),
        .m10_gamma_elem_i       (16'sd16384),
        .m10_use_uniform_x_i    (vif.m10_use_unif),
        .m10_busy_o             (),
        .m10_out_valid_o        (vif.m10_out_valid_o),
        .m10_out_last_o         (),
        .m10_done_o             (),
        .m10_y_elem0_o          (),
        .m10_var_eps_o          (),
        .m10_inv_rms_o          (vif.m10_inv_rms_o),
        .m10_fsm_state_o        (),
        .m11_valid_i            (vif.m11_valid),
        .m11_first_grp_i        (1'b1),
        .m11_last_grp_i         (1'b1),
        .m11_gate_elem_i        (16'sd256),
        .m11_up_elem_i          (16'sd256),
        .m11_w_down_3b_i        (3'd1),
        .m11_use_uniform_i      (1'b0),
        .m11_silu_valid_o       (),
        .m11_silu_c0_o          (),
        .m11_had_valid_o        (),
        .m11_had_c0_o           (),
        .m11_had_int8_c0_o      (),
        .m11_down_valid_o       (vif.m11_down_valid_o),
        .m11_down_done_o        (),
        .m11_down_acc0_o        (),
        .m12_bcast_en_i         (1'b0),
        .m12_c2c_en_i           (1'b0),
        .m12_in_valid_i         (vif.m12_in_valid),
        .m12_in_ready_o         (),
        .m12_in_hdr_i           (vif.m12_in_hdr),
        .m12_in_pay_lo_i        (vif.stim_seed_lo),
        .m12_up_credit_ret_o    (vif.m12_up_cred_o),
        .m12_loc_tx_valid_i     (vif.m12_loc_tx_valid),
        .m12_loc_tx_ready_o     (),
        .m12_loc_rx_valid_o     (),
        .m12_loc_rx_ready_i     (1'b1),
        .m12_out_valid_o        (),
        .m12_out_ready_i        (1'b1),
        .m12_dn_credit_ret_i    (1'b1),
        .m12_c2c_tx_valid_o     (),
        .m12_c2c_tx_ready_i     (1'b1),
        .m12_c2c_rx_valid_i     (1'b0),
        .m12_c2c_rx_ready_o     (),
        .m12_avail_credits_o    (),
        .m12_inflight_flits_o   (),
        .m12_skid_occ_o         (),
        .m12_fifo_occ_o         (),
        .m12_rx_cnt_o           (),
        .m12_tx_cnt_o           (),
        .m12_stall_cnt_o        (),
        .m12_crc_err_o          (vif.m12_crc_err_o),
        .axi_awaddr_i           (vif.axi_awaddr),
        .axi_awvalid_i          (vif.axi_awvalid),
        .axi_awready_o          (),
        .axi_wdata_i            (vif.axi_wdata),
        .axi_wstrb_i            (4'hF),
        .axi_wvalid_i           (vif.axi_wvalid),
        .axi_wready_o           (),
        .axi_bresp_o            (),
        .axi_bvalid_o           (),
        .axi_bready_i           (1'b1),
        .axi_araddr_i           (16'd0),
        .axi_arvalid_i          (1'b0),
        .axi_arready_o          (),
        .axi_rdata_o            (),
        .axi_rresp_o            (),
        .axi_rvalid_o           (),
        .axi_rready_i           (1'b1),
        .m13_tok_in_ready_i     (1'b1),
        .m13_tok_in_valid_o     (),
        .m13_tok_in_id_o        (),
        .m13_tok_out_valid_i    (1'b0),
        .m13_tok_out_ready_o    (),
        .m13_tok_out_id_i       (20'd0),
        .m13_dma_busy_o         (),
        .m13_dma_done_o         (),
        .m14_tile_cg_en_i       (1'b0),
        .m14_rom_sleep_en_i     (1'b0),
        .m14_hc2_mode_i         (1'b0),
        .m14_zero_skip_en_i     (1'b1),
        .m14_lora_en_i          (1'b1),
        .m14_lora_rank_i        (8'd16),
        .m14_lora_alpha_i       (16'sd256),
        .m14_ntk_rope_en_i      (1'b0),
        .m14_bcast_en_i         (1'b0),
        .m14_slot_id_i          (3'd0),
        .m14_token_pos_i        (12'd0),
        .m14_kv_clear_i         (1'b0),
        .m14_dma_we_i           (1'b0),
        .m14_dma_layer_i        (8'd0),
        .m14_dma_row_i          (12'd0),
        .m14_noc_in_valid_i     (vif.m14_noc_in_valid),
        .m14_noc_in_ready_o     (),
        .m14_noc_in_hdr_i       (32'h800000A5),
        .m14_noc_out_ready_i    (1'b1),
        .m14_noc_out_valid_o    (),
        .m14_noc_dn_credit_i    (1'b1),
        .m14_tile_busy_o        (),
        .m14_tile_done_o        (),
        .m14_tile_fsm_o         (),
        .m15_c2c_ext_en_i       (1'b0),
        .m15_c2c_tx_valid_o     (),
        .m15_c2c_tx_ready_i     (1'b1),
        .m15_c2c_rx_valid_i     (1'b0),
        .m15_c2c_rx_ready_o     (),
        .m15_chip_id_o          (),
        .m15_chip_busy_o        (),
        .m15_active_tiles_o     (),
        .m15_cg_tiles_o         (),
        .m15_last_token_o       (),
        .m15_token_pulse_o      (),
        .m15_perf_cycles_o      (),
        .m15_perf_tokens_o      (),
        .m15_perf_rom_o         (),
        .m15_perf_zskip_o       (),
        .sva_total_checks_o     (vif.sva_checks_o),
        .sva_total_violations_o (vif.sva_violations_o)
    );
    /* verilator lint_on PINCONNECTEMPTY */

    initial begin
        vif.rst_n = 1'b0;
        repeat (5) @(posedge clk);
        vif.rst_n = 1'b1;
    end

    initial begin
        uvm_config_db#(virtual taalas_sv_uvm_if)::set(null, "*", "vif", vif);
        run_test("taalas_full_uvm_test");
    end
endmodule
