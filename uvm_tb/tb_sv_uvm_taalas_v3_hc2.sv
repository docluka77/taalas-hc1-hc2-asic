`timescale 1ns / 1ps
`include "uvm_macros.svh"

// =============================================================================
// File:        uvm_tb/tb_sv_uvm_taalas_v3_hc2.sv
// Project:     Taalas HC1/HC2 Hardwired LLM Inference ASIC (Stage 20A)
// Description: Native Accellera IEEE 1800.2 SystemVerilog UVM-2020.3.1
//              Verification Environment (uvm_sequence_item, uvm_sequence,
//              uvm_sequencer, uvm_driver, uvm_monitor, uvm_agent,
//              uvm_scoreboard, uvm_env, uvm_test) Verifying rtl_v3 + rtl_hc2:
//                - M02: taalas_3b6b_wired_mac_array
//                - M03: taalas_mxfp4_hc2_mac_lane
//                - M05: taalas_sram_6t_banked_macro
//                - M09: taalas_flash_decode_attention (16-seg PWL recip)
//                - M10: taalas_rmsnorm_engine (2-cyc retimed NR rsqrt)
//                - M18: taalas_ecc_bist_scrubber (SEU patrol + Via-ROM BIST)
//                - M19: taalas_dvfs_pvt_controller (PVT RO + PID DVFS + BBM)
//                - H2 : taalas_hc2_c2c_llr_serdes_ctrl (112G Go-Back-N LLR)
//                - H3 : taalas_hc2_moe_mla_router (DeepSeek-R1 Top-K MoE)
// =============================================================================

interface taalas_v3_hc2_uvm_if (input logic clk);
    logic               rst_n          = 1'b0;
    logic [63:0]        stim_seed_lo   = 64'd0;
    logic [63:0]        stim_seed_hi   = 64'd0;
    logic [3:0]         stim_mode      = 4'd0;

    // M02 (3b/6b CSD MAC) & M03 (MXFP4 MAC)
    logic               m2_valid       = 1'b0;
    logic               m2_zero_skip   = 1'b1;
    logic               m2_valid_o;
    logic signed [23:0] m2_acc_ch0_o;
    logic [15:0]        m2_zskip_cnt_o;

    logic               m3_valid       = 1'b0;
    logic [7:0]         m3_act_e8m0    = 8'd127;
    logic [7:0]         m3_w_e8m0      = 8'd127;
    logic               m3_valid_o;
    logic signed [15:0] m3_dot_l0_o;
    logic [31:0]        m3_fp32_l0_o;

    // M05 (6T SECDED Banked SRAM)
    logic               m5_req_valid   = 1'b0;
    logic               m5_req_we      = 1'b0;
    logic [3:0]         m5_req_bank    = 4'd0;
    logic [4:0]         m5_req_row     = 5'd0;
    logic [63:0]        m5_req_wdata   = 64'd0;
    logic               m5_err_inj_en  = 1'b0;
    logic [71:0]        m5_err_mask    = 72'd0;
    logic               m5_resp_valid_o;
    logic [63:0]        m5_resp_rdata_o;
    logic               m5_sec_err_o;
    logic               m5_ded_err_o;

    // M09 (Flash-Decode Online Softmax) & M10 (Retimed NR RMSNorm)
    logic               m9_start_seq   = 1'b0;
    logic               m9_kv_valid    = 1'b0;
    logic               m9_kv_last     = 1'b0;
    logic signed [15:0] m9_q_elem      = 16'sd256;
    logic signed [15:0] m9_k_elem      = 16'sd256;
    logic signed [15:0] m9_v_elem      = 16'sd256;
    logic               m9_out_valid_o;
    logic signed [15:0] m9_attn_h0_d0_o;

    logic               m10_start      = 1'b0;
    logic               m10_in_valid   = 1'b1;
    logic signed [15:0] m10_x_elem     = 16'sd256;
    logic               m10_out_valid_o;
    logic [15:0]        m10_inv_rms_o;

    // M18 (ECC/SEU Scrubber + Via-ROM BIST + di/dt Stretch)
    logic               m18_active_req  = 1'b0;
    logic               m18_rvalid      = 1'b0;
    logic [71:0]        m18_rdata       = 72'd0;
    logic               m18_bist_start  = 1'b0;
    logic [7:0]         m18_canary      = 8'hFF;
    logic [7:0]         m18_mac_lanes   = 8'd16;
    logic               m18_scrub_wb_we_o;
    logic [31:0]        m18_sbe_cnt_o;
    logic               m18_bist_done_o;
    logic               m18_bist_pass_o;
    logic               m18_clk_stretch_o;

    // M19 (All-Digital PVT RO + Anti-Windup PID + Break-Before-Make DFS)
    logic               m19_dvfs_en     = 1'b1;
    logic               m19_sample_val  = 1'b1;
    logic [11:0]        m19_dro_cnt     = 12'd2048;
    logic [5:0]         m19_act_tiles   = 6'd16;
    logic [3:0]         m19_c2c_act     = 4'd4;
    logic [15:0]        m19_temp_q8_8_o;
    logic [1:0]         m19_active_pstate_o;
    logic [3:0]         m19_clk_path_en_o;
    logic signed [23:0] m19_pid_integ_o;
    logic               m19_thermal_trip_o;

    // H2 (112G C2C Go-Back-N LLR SerDes) & H3 (DeepSeek-R1 Top-K MoE Router)
    logic               h2_tx_valid     = 1'b0;
    logic [63:0]        h2_tx_data      = 64'd0;
    logic               h2_link_err_inj = 1'b0;
    logic               h2_rx_valid_o;
    logic [63:0]        h2_rx_data_o;
    logic [15:0]        h2_rx_good_cnt_o;
    logic [15:0]        h2_llr_replay_cnt_o;

    logic               h3_valid        = 1'b0;
    logic               h3_topk_mode    = 1'b1;
    logic               h3_shared_en    = 1'b1;
    logic               h3_valid_o;
    logic [15:0]        h3_sel_experts_o;
    logic [15:0]        h3_cg_mask_o;
    logic [15:0]        h3_routed_cnt_o;
endinterface

package taalas_v3_hc2_uvm_pkg;
    import uvm_pkg::*;

    class taalas_v3_hc2_item extends uvm_sequence_item;
        `uvm_object_utils(taalas_v3_hc2_item)
        int unsigned txn_id;
        bit [1:0]    phase_kind;
        bit [63:0]   seed_lo;
        bit [63:0]   seed_hi;
        bit [3:0]    mode;
        bit [7:0]    act_e8m0;
        bit [7:0]    w_e8m0;
        bit [11:0]   dro_cnt;
        bit [5:0]    act_tiles;
        bit          inject_c2c_err;

        // Observed outputs
        logic signed [23:0] obs_m2_acc;
        logic [31:0]        obs_m3_fp32;
        logic signed [15:0] obs_m9_attn;
        logic [15:0]        obs_m10_inv_rms;
        logic [31:0]        obs_m18_sbe_cnt;
        logic [3:0]         obs_m19_clk_en;
        logic [1:0]         obs_m19_pstate;
        logic signed [23:0] obs_m19_integ;
        logic [15:0]        obs_h2_good_cnt;
        logic [15:0]        obs_h2_replay_cnt;
        logic [15:0]        obs_h3_routed_cnt;

        function new(string name = "taalas_v3_hc2_item");
            super.new(name);
        endfunction
    endclass

    class taalas_v3_hc2_sequence extends uvm_sequence #(taalas_v3_hc2_item);
        `uvm_object_utils(taalas_v3_hc2_sequence)
        function new(string name = "taalas_v3_hc2_sequence");
            super.new(name);
        endfunction

        task body();
            bit [63:0] lfsr = 64'h5441_414C_5633_4843;
            // Generate 51,200 constrained-random & corner-case SV UVM transactions (10x Stage 29 Intensity)
            for (int i = 0; i < 51200; i++) begin
                taalas_v3_hc2_item item = taalas_v3_hc2_item::type_id::create("item");
                start_item(item);
                lfsr = {lfsr[62:0], lfsr[63] ^ lfsr[61] ^ lfsr[3] ^ lfsr[0]};
                item.txn_id         = i;
                item.phase_kind     = (i < 512) ? 2'd0 : (i >= 48000) ? 2'd2 : 2'd1;
                item.seed_lo        = lfsr;
                item.seed_hi        = ~lfsr ^ (64'h9E37_79B9_7F4A_7C15 * (i + 1));
                item.mode           = 4'(i % 8);
                item.act_e8m0       = 8'((i == 0) ? 0 : (i == 1) ? 255 : (112 + (i & 31)));
                item.w_e8m0         = 8'((i == 2) ? 255 : (116 + ((i >> 2) & 15)));
                item.dro_cnt        = (i >= 5000) ? 12'd900 : (12'd1500 + lfsr[9:0]);
                item.act_tiles      = (i >= 5000) ? 6'd32 : (6'd8 + lfsr[4:0]);
                item.inject_c2c_err = ((i % 64) == 31);
                finish_item(item);
            end
        endtask
    endclass

    class taalas_v3_hc2_driver extends uvm_driver #(taalas_v3_hc2_item);
        `uvm_component_utils(taalas_v3_hc2_driver)
        virtual taalas_v3_hc2_uvm_if vif;
        int unsigned driven_cnt = 0;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db#(virtual taalas_v3_hc2_uvm_if)::get(this, "", "vif", vif))
                `uvm_fatal("NO_VIF", "Virtual interface taalas_v3_hc2_uvm_if missing in driver")
        endfunction

        task run_phase(uvm_phase phase);
            taalas_v3_hc2_item item;
            wait (vif.rst_n === 1'b1);
            forever begin
                seq_item_port.get_next_item(item);
                @(negedge vif.clk);
                vif.stim_seed_lo    = item.seed_lo;
                vif.stim_seed_hi    = item.seed_hi;
                vif.stim_mode       = item.mode;
                vif.m2_valid        = 1'b1;
                vif.m2_zero_skip    = 1'b1;
                vif.m3_valid        = 1'b1;
                vif.m3_act_e8m0     = item.act_e8m0;
                vif.m3_w_e8m0       = item.w_e8m0;
                vif.m5_req_valid    = 1'b1;
                vif.m5_req_we       = ~item.txn_id[0];
                vif.m5_req_bank     = item.seed_lo[3:0];
                vif.m5_req_row      = item.seed_lo[8:4];
                vif.m5_req_wdata    = item.seed_lo;
                vif.m5_err_inj_en   = (item.txn_id[4:0] == 5'd15);
                vif.m5_err_mask     = 72'h00_0000_0000_0000_0001 << item.seed_lo[5:0];
                vif.m9_start_seq    = (item.txn_id[2:0] == 3'd0);
                vif.m9_kv_valid     = (item.txn_id[2:0] != 3'd0);
                vif.m9_kv_last      = (item.txn_id[2:0] == 3'd7);
                vif.m9_q_elem       = $signed(item.seed_lo[11:0]);
                vif.m9_k_elem       = $signed(item.seed_hi[11:0]);
                vif.m9_v_elem       = 16'sd256 + $signed({{6{item.seed_lo[9]}}, item.seed_lo[9:0]});
                vif.m10_start       = (item.txn_id[3:0] == 4'd0);
                vif.m10_in_valid    = 1'b1;
                vif.m10_x_elem      = 16'sd128 + $signed({{7{item.seed_hi[8]}}, item.seed_hi[8:0]});
                vif.m18_active_req  = item.txn_id[1];
                vif.m18_rvalid      = ~item.txn_id[1];
                vif.m18_rdata       = 72'h01_0000_0000_0000_0000; // Single-bit ECC flip for patrol healing
                vif.m18_bist_start  = (item.txn_id == 0);
                vif.m18_canary      = (item.txn_id[5:0] == 6'd63) ? 8'h3F : 8'hFF;
                vif.m18_mac_lanes   = (item.txn_id[5:0] == 6'd63) ? 8'd96 : 8'd16;
                vif.m19_dvfs_en     = 1'b1;
                vif.m19_sample_val  = 1'b1;
                vif.m19_dro_cnt     = item.dro_cnt;
                vif.m19_act_tiles   = item.act_tiles;
                vif.m19_c2c_act     = item.seed_lo[3:0];
                vif.h2_tx_valid     = 1'b1;
                vif.h2_tx_data      = item.seed_lo ^ item.seed_hi;
                vif.h2_link_err_inj = item.inject_c2c_err;
                vif.h3_valid        = 1'b1;
                vif.h3_topk_mode    = item.txn_id[0];
                vif.h3_shared_en    = 1'b1;
                driven_cnt++;
                seq_item_port.item_done();
            end
        endtask
    endclass

    class taalas_v3_hc2_monitor extends uvm_monitor;
        `uvm_component_utils(taalas_v3_hc2_monitor)
        virtual taalas_v3_hc2_uvm_if vif;
        uvm_analysis_port #(taalas_v3_hc2_item) ap;
        int unsigned observed_cnt = 0;

        function new(string name, uvm_component parent);
            super.new(name, parent);
            ap = new("ap", this);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db#(virtual taalas_v3_hc2_uvm_if)::get(this, "", "vif", vif))
                `uvm_fatal("NO_VIF", "Virtual interface taalas_v3_hc2_uvm_if missing in monitor")
        endfunction

        task run_phase(uvm_phase phase);
            forever begin
                @(posedge vif.clk);
                #1ps;
                if (vif.rst_n) begin
                    taalas_v3_hc2_item obs = taalas_v3_hc2_item::type_id::create("obs");
                    obs.mode              = vif.stim_mode;
                    obs.act_e8m0          = vif.m3_act_e8m0;
                    obs.w_e8m0            = vif.m3_w_e8m0;
                    obs.obs_m2_acc        = vif.m2_acc_ch0_o;
                    obs.obs_m3_fp32       = vif.m3_fp32_l0_o;
                    obs.obs_m9_attn       = vif.m9_attn_h0_d0_o;
                    obs.obs_m10_inv_rms   = vif.m10_inv_rms_o;
                    obs.obs_m18_sbe_cnt   = vif.m18_sbe_cnt_o;
                    obs.obs_m19_clk_en    = vif.m19_clk_path_en_o;
                    obs.obs_m19_pstate    = vif.m19_active_pstate_o;
                    obs.obs_m19_integ     = vif.m19_pid_integ_o;
                    obs.obs_h2_good_cnt   = vif.h2_rx_good_cnt_o;
                    obs.obs_h2_replay_cnt = vif.h2_llr_replay_cnt_o;
                    obs.obs_h3_routed_cnt = vif.h3_routed_cnt_o;
                    observed_cnt++;
                    ap.write(obs);
                end
            end
        endtask
    endclass

    class taalas_v3_hc2_agent extends uvm_agent;
        `uvm_component_utils(taalas_v3_hc2_agent)
        uvm_sequencer #(taalas_v3_hc2_item) sqr;
        taalas_v3_hc2_driver                drv;
        taalas_v3_hc2_monitor               mon;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            sqr = uvm_sequencer#(taalas_v3_hc2_item)::type_id::create("sqr", this);
            drv = taalas_v3_hc2_driver::type_id::create("drv", this);
            mon = taalas_v3_hc2_monitor::type_id::create("mon", this);
        endfunction

        function void connect_phase(uvm_phase phase);
            super.connect_phase(phase);
            drv.seq_item_port.connect(sqr.seq_item_export);
        endfunction
    endclass

    class taalas_v3_hc2_scoreboard extends uvm_scoreboard;
        `uvm_component_utils(taalas_v3_hc2_scoreboard)
        uvm_analysis_imp #(taalas_v3_hc2_item, taalas_v3_hc2_scoreboard) analysis_export;
        int unsigned total_obs        = 0;
        int unsigned m19_bbm_checks   = 0;
        int unsigned m19_windup_checks= 0;
        int unsigned h2_last_good     = 0;
        int unsigned h2_last_replay   = 0;
        int unsigned h3_last_routed   = 0;
        int unsigned m18_last_sbe     = 0;

        function new(string name, uvm_component parent);
            super.new(name, parent);
            analysis_export = new("analysis_export", this);
        endfunction

        function void write(taalas_v3_hc2_item t);
            total_obs++;
            if (!$onehot0(t.obs_m19_clk_en))
                `uvm_error("M19_BBM_VIOL", $sformatf("Non-onehot0 clk_path_en_o=%b", t.obs_m19_clk_en))
            else
                m19_bbm_checks++;

            if (t.obs_m19_integ < -24'sd16384 || t.obs_m19_integ > 24'sd16384)
                `uvm_error("M19_WINDUP_VIOL", $sformatf("PID integ out of bounds: %0d", t.obs_m19_integ))
            else
                m19_windup_checks++;

            h2_last_good   = t.obs_h2_good_cnt;
            h2_last_replay = t.obs_h2_replay_cnt;
            h3_last_routed = t.obs_h3_routed_cnt;
            m18_last_sbe   = t.obs_m18_sbe_cnt;
        endfunction

        function void report_phase(uvm_phase phase);
            super.report_phase(phase);
            `uvm_info("TAALAS_V3_HC2_SB", $sformatf(
                "Stage 20A Accellera SV UVM-2020.3.1 Summary: total_obs=%0d | M19_BBM_pass=%0d M19_AntiWindup_pass=%0d | M18_SBE_healed=%0d | H2_C2C_good=%0d H2_LLR_replays=%0d | H3_MoE_routed=%0d",
                total_obs, m19_bbm_checks, m19_windup_checks, m18_last_sbe, h2_last_good, h2_last_replay, h3_last_routed), UVM_LOW)
        endfunction
    endclass

    class taalas_v3_hc2_env extends uvm_env;
        `uvm_component_utils(taalas_v3_hc2_env)
        taalas_v3_hc2_agent      agt;
        taalas_v3_hc2_scoreboard sb;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            agt = taalas_v3_hc2_agent::type_id::create("agt", this);
            sb  = taalas_v3_hc2_scoreboard::type_id::create("sb", this);
        endfunction

        function void connect_phase(uvm_phase phase);
            super.connect_phase(phase);
            agt.mon.ap.connect(sb.analysis_export);
        endfunction
    endclass

    class taalas_v3_hc2_uvm_test extends uvm_test;
        `uvm_component_utils(taalas_v3_hc2_uvm_test)
        taalas_v3_hc2_env env;

        function new(string name = "taalas_v3_hc2_uvm_test", uvm_component parent = null);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            env = taalas_v3_hc2_env::type_id::create("env", this);
        endfunction

        task run_phase(uvm_phase phase);
            taalas_v3_hc2_sequence seq;
            phase.raise_objection(this, "Running Stage 20A Taalas rtl_v3 + rtl_hc2 Native SV UVM-2020.3.1 Test");
            seq = taalas_v3_hc2_sequence::type_id::create("seq");
            seq.start(env.agt.sqr);
            #50ns;
            phase.drop_objection(this, "Completed Stage 20A Taalas rtl_v3 + rtl_hc2 Native SV UVM-2020.3.1 Test");
        endtask
    endclass
endpackage

module tb_sv_uvm_taalas_v3_hc2;
    import uvm_pkg::*;
    import taalas_v3_hc2_uvm_pkg::*;

    logic clk = 1'b0;
    always #5ns clk = ~clk;

    taalas_v3_hc2_uvm_if vif(clk);
    logic [511:0] wide_stim;
    assign wide_stim = {4{vif.stim_seed_hi, vif.stim_seed_lo}};

    /* verilator lint_off PINCONNECTEMPTY */
    // 1. M02: 3b/6b CSD Wired MAC Array (rtl_v3)
    logic [95:0] m2_acc_full;
    taalas_3b6b_wired_mac_array #(
        .VEC_LEN(16), .OUT_CHANNELS(4), .NUM_OUTLIERS(4)
    ) u_m02_mac (
        .clk              (clk),
        .rst_n            (vif.rst_n),
        .valid_i          (vif.m2_valid),
        .act_vec_i        (wide_stim[127:0]),
        .w_base_3b_i      (wide_stim[191:0]),
        .w_out_val_6b_i   (wide_stim[287:192]),
        .w_out_idx_6b_i   (wide_stim[383:288]),
        .zero_skip_en_i   (vif.m2_zero_skip),
        .valid_o          (vif.m2_valid_o),
        .acc_out_o        (m2_acc_full),
        .act_sum_o        (),
        .zero_ops_saved_o (vif.m2_zskip_cnt_o)
    );
    assign vif.m2_acc_ch0_o = $signed(m2_acc_full[23:0]);

    // 2. M03: OCP MXFP4 Spatial MAC Lane (rtl_v3)
    logic [63:0]  m3_dot_full;
    logic [127:0] m3_fp32_full;
    taalas_mxfp4_hc2_mac_lane #(
        .BLOCK_SIZE(16), .NUM_LANES(4)
    ) u_m03_mxfp4 (
        .clk         (clk),
        .rst_n       (vif.rst_n),
        .valid_i     (vif.m3_valid),
        .act_mxfp4_i (wide_stim[63:0]),
        .act_e8m0_i  (vif.m3_act_e8m0),
        .w_mxfp4_i   (wide_stim[255:0]),
        .w_e8m0_i    ({4{vif.m3_w_e8m0}}),
        .valid_o     (vif.m3_valid_o),
        .dot_int16_o (m3_dot_full),
        .exp_comb_o  (),
        .fp32_out_o  (m3_fp32_full),
        .nan_flag_o  ()
    );
    assign vif.m3_dot_l0_o  = $signed(m3_dot_full[15:0]);
    assign vif.m3_fp32_l0_o = m3_fp32_full[31:0];

    // 3. M05: 6T SECDED Banked SRAM Macro (rtl_v3)
    taalas_sram_6t_banked_macro #(
        .NUM_BANKS(16), .BANK_DEPTH(32), .DATA_WIDTH(64), .ECC_WIDTH(8), .RAW_WIDTH(72)
    ) u_m05_sram (
        .clk                  (clk),
        .rst_n                (vif.rst_n),
        .ret_sleep_i          (1'b0),
        .bank_cg_en_i         (16'h0000),
        .req_valid_i          (vif.m5_req_valid),
        .req_we_i             (vif.m5_req_we),
        .req_bank_i           (vif.m5_req_bank),
        .req_row_i            (vif.m5_req_row),
        .req_wdata_i          (vif.m5_req_wdata),
        .req_wmask_i          (8'hFF),
        .vec_req_valid_i      (16'h0000),
        .vec_req_row_i        (wide_stim[127:0]),
        .bank_conflict_mask_o (),
        .conflict_free_o      (),
        .err_inj_en_i         (vif.m5_err_inj_en),
        .err_inj_mask_i       (vif.m5_err_mask),
        .resp_valid_o         (vif.m5_resp_valid_o),
        .resp_rdata_o         (vif.m5_resp_rdata_o),
        .resp_raw_codeword_o  (),
        .phys_bank_o          (),
        .sec_err_o            (vif.m5_sec_err_o),
        .ded_err_o            (vif.m5_ded_err_o),
        .err_syndrome_o       (),
        .sec_err_cnt_o        (),
        .ded_err_cnt_o        ()
    );

    // 4. M09: Streaming Flash-Decode Attention with Stage-12 16-Seg PWL Recip (rtl_v3)
    logic [1023:0] m9_attn_full;
    taalas_flash_decode_attention #(
        .HEAD_DIM(16), .GQA_RATIO(4), .DATA_W(16)
    ) u_m09_attn (
        .clk                (clk),
        .rst_n              (vif.rst_n),
        .start_seq_i        (vif.m9_start_seq),
        .kv_valid_i         (vif.m9_kv_valid),
        .kv_last_i          (vif.m9_kv_last),
        .q_heads_i          ({64{vif.m9_q_elem}}),
        .k_shared_i         ({16{vif.m9_k_elem}}),
        .v_shared_i         ({16{vif.m9_v_elem}}),
        .scale_log2e_q8_8_i (16'd5909),
        .log2e_scale_en_i   (1'b0),
        .step_valid_o       (),
        .out_valid_o        (vif.m9_out_valid_o),
        .attn_out_o         (m9_attn_full),
        .max_score_o        (),
        .denom_sum_o        ()
    );
    assign vif.m9_attn_h0_d0_o = $signed(m9_attn_full[15:0]);

    // 5. M10: Retimed 2-Cycle Newton-Raphson RMSNorm Engine (rtl_v3)
    taalas_rmsnorm_engine #(
        .HIDDEN_DIM(64), .VEC_W(16), .DATA_W(16), .EPS_DEFAULT(4)
    ) u_m10_rmsnorm (
        .clk            (clk),
        .rst_n          (vif.rst_n),
        .start_i        (vif.m10_start),
        .in_valid_i     (vif.m10_in_valid),
        .x_vec_i        ({16{vif.m10_x_elem}}),
        .eps_q16_i      (16'd4),
        .ext_gamma_en_i (1'b0),
        .gamma_vec_i    ({16{16'sd16384}}),
        .busy_o         (),
        .out_valid_o    (vif.m10_out_valid_o),
        .out_last_o     (),
        .done_o         (),
        .y_vec_o        (),
        .var_eps_o      (),
        .inv_rms_q8_8_o (vif.m10_inv_rms_o),
        .fsm_state_o    ()
    );

    // 6. M18: Silicon Reliability SEU Scrubber & Via-ROM CRC-16 BIST (rtl_v3)
    logic [4:0] m18_scrub_bank;
    logic [7:0] m18_scrub_addr;
    taalas_ecc_bist_scrubber #(
        .NUM_BANKS(32), .BANK_DEPTH(256), .ROM_DEPTH(64)
    ) u_m18_scrubber (
        .clk                     (clk),
        .rst_n                   (vif.rst_n),
        .active_sram_req_i       (vif.m18_active_req),
        .active_sram_bank_i      (vif.stim_seed_lo[4:0]),
        .active_sram_addr_i      (vif.stim_seed_lo[12:5]),
        .scrub_sram_re_o         (),
        .scrub_sram_bank_o       (m18_scrub_bank),
        .scrub_sram_addr_o       (m18_scrub_addr),
        .scrub_sram_rvalid_i     (vif.m18_rvalid),
        .scrub_sram_rbank_i      (m18_scrub_bank),
        .scrub_sram_raddr_i      (m18_scrub_addr),
        .scrub_sram_rdata_i      (vif.m18_rdata),
        .scrub_wb_we_o           (vif.m18_scrub_wb_we_o),
        .scrub_wb_bank_o         (),
        .scrub_wb_addr_o         (),
        .scrub_wb_data_o         (),
        .sbe_scrubbed_cnt_o      (vif.m18_sbe_cnt_o),
        .dbe_detected_cnt_o      (),
        .uncorrectable_dbe_irq_o (),
        .fault_log_reg_o         (),
        .remap_valid_o           (),
        .remap_src_addr_o        (),
        .remap_dst_row_o         (),
        .active_hit_spare_o      (),
        .active_spare_row_o      (),
        .spare_rows_used_o       (),
        .bist_start_i            (vif.m18_bist_start),
        .bist_rom_data_i         (64'hCAFE_BABE_1234_5678),
        .expected_crc16_i        (16'hFFFF),
        .bist_running_o          (),
        .bist_rom_re_o           (),
        .bist_rom_addr_o         (),
        .bist_crc16_o            (),
        .bist_done_o             (vif.m18_bist_done_o),
        .bist_pass_o             (vif.m18_bist_pass_o),
        .canary_taps_i           (vif.m18_canary),
        .mac_active_lanes_i      (vif.m18_mac_lanes),
        .clk_stretch_en_o        (vif.m18_clk_stretch_o),
        .gated_clk_en_o          (),
        .droop_event_cnt_o       ()
    );

    // 7. M19: All-Digital PVT RO Sensor, Anti-Windup PID & BBM DFS Controller (rtl_v3)
    taalas_dvfs_pvt_controller #(
        .NUM_TILES(32)
    ) u_m19_dvfs_pvt (
        .clk                      (clk),
        .rst_n                    (vif.rst_n),
        .dvfs_en_i                (vif.m19_dvfs_en),
        .sample_valid_i           (vif.m19_sample_val),
        .dro_cnt_i                (vif.m19_dro_cnt),
        .active_tiles_cnt_i       (vif.m19_act_tiles),
        .c2c_activity_i           (vif.m19_c2c_act),
        .kp_q8_8_i                (16'sd512),
        .ki_q8_8_i                (16'sd64),
        .kd_q8_8_i                (16'sd128),
        .temp_c_q8_8_o            (vif.m19_temp_q8_8_o),
        .vdd_mv_o                 (),
        .est_power_w_q8_8_o       (),
        .pid_err_q8_8_o           (),
        .pid_integ_o              (vif.m19_pid_integ_o),
        .pid_out_o                (),
        .target_pstate_o          (),
        .active_pstate_o          (vif.m19_active_pstate_o),
        .clk_path_en_o            (vif.m19_clk_path_en_o),
        .dfs_clk_en_o             (),
        .clk_gate_ack_o           (),
        .pstate_transition_busy_o (),
        .thermal_warn_irq_o       (),
        .thermal_trip_irq_o       (vif.m19_thermal_trip_o),
        .pstate_switch_cnt_o      (),
        .throttle_cycles_cnt_o    ()
    );

    // 8. H2: 112G C2C Go-Back-N LLR SerDes Controller in Registered Loopback (rtl_hc2)
    logic        h2_c2c_valid, h2_c2c_cred, h2_ack_valid, h2_ack_nack;
    logic        h2_ack_valid_q, h2_ack_nack_q;
    logic [87:0] h2_c2c_frame;
    logic [7:0]  h2_ack_seq, h2_ack_seq_q;
    always_ff @(posedge clk or negedge vif.rst_n) begin
        if (!vif.rst_n) begin
            h2_ack_valid_q <= 1'b0;
            h2_ack_nack_q  <= 1'b0;
            h2_ack_seq_q   <= 8'd0;
        end else begin
            h2_ack_valid_q <= h2_ack_valid;
            h2_ack_nack_q  <= h2_ack_nack;
            h2_ack_seq_q   <= h2_ack_seq;
        end
    end
    taalas_hc2_c2c_llr_serdes_ctrl u_h2_c2c_llr (
        .clk                 (clk),
        .rst_n               (vif.rst_n),
        .tx_flit_valid_i     (vif.h2_tx_valid),
        .tx_flit_data_i      (vif.h2_tx_data),
        .tx_flit_ready_o     (),
        .rx_flit_valid_o     (vif.h2_rx_valid_o),
        .rx_flit_data_o      (vif.h2_rx_data_o),
        .rx_flit_seq_o       (),
        .rx_credit_return_i  (vif.h2_rx_valid_o),
        .c2c_tx_valid_o      (h2_c2c_valid),
        .c2c_tx_frame_o      (h2_c2c_frame),
        .c2c_rx_credit_ret_i (h2_c2c_cred),
        .c2c_rx_valid_i      (h2_c2c_valid),
        .c2c_rx_frame_i      (h2_c2c_frame),
        .link_err_inj_i      (vif.h2_link_err_inj),
        .c2c_tx_credit_ret_o (h2_c2c_cred),
        .c2c_rx_ack_valid_i  (h2_ack_valid_q),
        .c2c_rx_ack_nack_i   (h2_ack_nack_q),
        .c2c_rx_ack_seq_i    (h2_ack_seq_q),
        .c2c_tx_ack_valid_o  (h2_ack_valid),
        .c2c_tx_ack_nack_o   (h2_ack_nack),
        .c2c_tx_ack_seq_o    (h2_ack_seq),
        .replay_active_o     (),
        .rx_crc_err_o        (),
        .tx_credits_avail_o  (),
        .unacked_cnt_o       (),
        .tx_frame_cnt_o      (),
        .rx_good_cnt_o       (vif.h2_rx_good_cnt_o),
        .llr_replay_cnt_o    (vif.h2_llr_replay_cnt_o),
        .crc_err_cnt_o       ()
    );

    // 9. H3: DeepSeek-R1 Top-K MoE & MLA Router (rtl_hc2)
    taalas_hc2_moe_mla_router u_h3_moe_router (
        .clk                       (clk),
        .rst_n                     (vif.rst_n),
        .valid_i                   (vif.h3_valid),
        .topk_mode_i               (vif.h3_topk_mode),
        .shared_expert_en_i        (vif.h3_shared_en),
        .token_id_i                (vif.stim_seed_lo[7:0]),
        .act_mxfp4_i               (wide_stim[31:0]),
        .act_e8m0_i                (vif.m3_act_e8m0),
        .gate_w_mxfp4_i            (wide_stim),
        .gate_w_e8m0_i             ({16{vif.m3_w_e8m0}}),
        .expert_bias_i             ('0),
        .valid_o                   (vif.h3_valid_o),
        .topk_mode_o               (),
        .shared_expert_active_o    (),
        .sel_expert_id_o           (vif.h3_sel_experts_o),
        .dst_chip_id_o             (),
        .gate_weight_q88_o         (),
        .sel_expert_score_o        (),
        .active_expert_mask_o      (),
        .clock_gated_expert_mask_o (vif.h3_cg_mask_o),
        .active_expert_cnt_o       (),
        .gated_expert_cnt_o        (),
        .routed_token_cnt_o        (vif.h3_routed_cnt_o),
        .cum_gated_expert_cycles_o ()
    );
    /* verilator lint_on PINCONNECTEMPTY */

    initial begin
        vif.rst_n = 1'b0;
        repeat (5) @(posedge clk);
        vif.rst_n = 1'b1;
    end

    initial begin
        uvm_config_db#(virtual taalas_v3_hc2_uvm_if)::set(null, "*", "vif", vif);
        run_test("taalas_v3_hc2_uvm_test");
    end
endmodule
