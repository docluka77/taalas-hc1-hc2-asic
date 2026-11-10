`timescale 1ns / 1ps

// =============================================================================
// Module:      taalas_dvfs_pvt_controller (Module M19 - Stage 20B)
// Project:     Taalas HC1/HC2 Hardwired LLM Inference ASIC
// Description: All-Digital 32-Tile PVT Ring-Oscillator Sensor, Discrete-Time
//              Anti-Windup PID Thermal Governor & Break-Before-Make Glitch-Free
//              DFS Clock-Mux Controller IP managing the 200-250 W air-cooled
//              reticle thermal envelope (T_target = 75.0 C, T_crit = 85.0 C,
//              T_trip = 95.0 C).
// =============================================================================

module taalas_dvfs_pvt_controller #(
    parameter int          NUM_TILES        = 32,
    parameter logic [15:0] TEMP_TARGET_Q8_8 = 16'h4B00, // 75.0 C in Q8.8
    parameter logic [15:0] TEMP_CRIT_Q8_8   = 16'h5500, // 85.0 C in Q8.8
    parameter logic [15:0] TEMP_TRIP_Q8_8   = 16'h5F00, // 95.0 C in Q8.8
    parameter logic [11:0] DRO_NOMINAL_CNT  = 12'd2048, // Nominal RO count @ 25 C
    parameter int signed   INTEG_MIN        = -16384,   // Anti-windup lower clamp
    parameter int signed   INTEG_MAX        =  16384    // Anti-windup upper clamp
) (
    input  logic               clk,
    input  logic               rst_n,

    // Control & 32-Tile PVT / Activity Telemetry Inputs
    input  logic               dvfs_en_i,
    input  logic               sample_valid_i,
    input  logic [11:0]        dro_cnt_i,
    input  logic [5:0]         active_tiles_cnt_i,
    input  logic [3:0]         c2c_activity_i,

    // Programmable Discrete-Time PID Gains (Q8.8 Signed)
    input  logic signed [15:0] kp_q8_8_i,
    input  logic signed [15:0] ki_q8_8_i,
    input  logic signed [15:0] kd_q8_8_i,

    // PVT Sensor & Power Estimation Outputs
    output logic [15:0]        temp_c_q8_8_o,
    output logic [11:0]        vdd_mv_o,
    output logic [15:0]        est_power_w_q8_8_o,

    // PID Controller State & Output Telemetry
    output logic signed [15:0] pid_err_q8_8_o,
    output logic signed [23:0] pid_integ_o,
    output logic signed [15:0] pid_out_o,

    // P-State & Glitch-Free DFS Clock-Mux Outputs
    output logic [1:0]         target_pstate_o,
    output logic [1:0]         active_pstate_o,
    output logic [3:0]         clk_path_en_o,
    output logic               dfs_clk_en_o,
    output logic               clk_gate_ack_o,
    output logic               pstate_transition_busy_o,

    // Thermal Protection Interrupts & Diagnostic Counters
    output logic               thermal_warn_irq_o,
    output logic               thermal_trip_irq_o,
    output logic [15:0]        pstate_switch_cnt_o,
    output logic [15:0]        throttle_cycles_cnt_o
);

    // -------------------------------------------------------------------------
    // 1. Discrete P-State Definitions & Operating Table
    // -------------------------------------------------------------------------
    localparam logic [1:0] P0_TURBO_1400MHZ   = 2'd0; // div-by-1.00, 820 mV
    localparam logic [1:0] P1_NOMINAL_1250MHZ = 2'd1; // div-by-1.12, 770 mV
    localparam logic [1:0] P2_ECO_1000MHZ     = 2'd2; // div-by-1.40, 720 mV
    localparam logic [1:0] P3_THROTTLE_700MHZ = 2'd3; // div-by-2.00, 670 mV

    localparam logic signed [15:0] KP_DEFAULT_Q8_8 = 16'sd512; // 2.00
    localparam logic signed [15:0] KI_DEFAULT_Q8_8 = 16'sd64;  // 0.25
    localparam logic signed [15:0] KD_DEFAULT_Q8_8 = 16'sd128; // 0.50

    // -------------------------------------------------------------------------
    // 2. 32-Tile Digital Ring-Oscillator (DRO) PVT Temperature & Power Model
    // -------------------------------------------------------------------------
    logic [11:0] dro_slowdown, dro_speedup;
    logic [15:0] base_temp_q8_8;
    logic [15:0] dro_temp_add_q8_8, dro_temp_sub_q8_8;
    logic [15:0] dyn_heat_q8_8;
    logic [16:0] raw_temp_calc;
    logic [15:0] next_temp_q8_8;
    logic [15:0] temp_c_q8_8_q;

    assign dro_slowdown      = (dro_cnt_i < DRO_NOMINAL_CNT) ? (DRO_NOMINAL_CNT - dro_cnt_i) : 12'd0;
    assign dro_speedup       = (dro_cnt_i > DRO_NOMINAL_CNT) ? (dro_cnt_i - DRO_NOMINAL_CNT) : 12'd0;
    assign base_temp_q8_8    = 16'h1900; // 25.0 C ambient baseline
    assign dro_temp_add_q8_8 = {1'b0, dro_slowdown, 3'b000}; // +1.0 C per 32 RO ticks slowdown
    assign dro_temp_sub_q8_8 = {2'b00, dro_speedup, 2'b00};  // -0.5 C per 32 RO ticks speedup
    assign dyn_heat_q8_8     = ({10'd0, active_tiles_cnt_i} * 16'd160) +
                               ({12'd0, c2c_activity_i} * 16'd64);

    always_comb begin
        raw_temp_calc = {1'b0, base_temp_q8_8} + {1'b0, dro_temp_add_q8_8} + {1'b0, dyn_heat_q8_8};
        if (raw_temp_calc > {1'b0, dro_temp_sub_q8_8} + 17'h01400)
            raw_temp_calc = raw_temp_calc - {1'b0, dro_temp_sub_q8_8};
        else
            raw_temp_calc = 17'h01400; // Floor at 20.0 C

        if (raw_temp_calc > 17'h07800)
            next_temp_q8_8 = 16'h7800; // Ceiling at 120.0 C
        else
            next_temp_q8_8 = raw_temp_calc[15:0];
    end

    // Power & Voltage Margin Estimator across 32-Tile Reticle (200-250 W envelope)
    logic [1:0]  active_pstate_q;
    logic [11:0] vdd_mv_comb;
    logic [15:0] tile_pwr_coeff_q8_8;
    logic [15:0] static_leak_q8_8;
    logic [15:0] est_power_q;

    always_comb begin
        unique case (active_pstate_q)
            P0_TURBO_1400MHZ:   begin vdd_mv_comb = 12'd820; tile_pwr_coeff_q8_8 = 16'h06E0; end // ~6.875 W/tile
            P1_NOMINAL_1250MHZ: begin vdd_mv_comb = 12'd770; tile_pwr_coeff_q8_8 = 16'h05C0; end // ~5.750 W/tile
            P2_ECO_1000MHZ:     begin vdd_mv_comb = 12'd720; tile_pwr_coeff_q8_8 = 16'h0440; end // ~4.250 W/tile
            default:            begin vdd_mv_comb = 12'd670; tile_pwr_coeff_q8_8 = 16'h02A0; end // ~2.625 W/tile
        endcase
        static_leak_q8_8 = 16'h0C00 + {3'b000, temp_c_q8_8_q[15:3]}; // ~12 W + T-dependent leakage
    end

    // -------------------------------------------------------------------------
    // 3. Discrete-Time PID Thermal Governor with Anti-Windup Clamping
    //    e[k] = T_meas[k] - T_target
    //    I[k] = clamp(I[k-1] + (Ki * e[k]) >>> 8, INTEG_MIN, INTEG_MAX)
    //    u[k] = (Kp * e[k]) >>> 8 + I[k] + (Kd * (e[k] - e[k-1])) >>> 8
    // -------------------------------------------------------------------------
    logic signed [15:0] eff_kp_q8_8, eff_ki_q8_8, eff_kd_q8_8;
    logic signed [15:0] pid_err_comb, pid_err_prev_q;
    logic signed [15:0] pid_err_diff_comb;
    logic signed [31:0] p_term_wide, i_step_wide, d_term_wide;
    logic signed [23:0] p_term_s24, d_term_s24;
    logic signed [23:0] pid_integ_q, integ_candidate_s24, pid_integ_next;
    logic signed [23:0] pid_sum_s24;
    logic signed [15:0] pid_out_comb, pid_out_q;
    logic [1:0]         pid_target_pstate_comb, target_pstate_q;

    assign eff_kp_q8_8       = (kp_q8_8_i != 16'sd0) ? kp_q8_8_i : KP_DEFAULT_Q8_8;
    assign eff_ki_q8_8       = (ki_q8_8_i != 16'sd0) ? ki_q8_8_i : KI_DEFAULT_Q8_8;
    assign eff_kd_q8_8       = (kd_q8_8_i != 16'sd0) ? kd_q8_8_i : KD_DEFAULT_Q8_8;

    assign pid_err_comb      = $signed(temp_c_q8_8_q) - $signed(TEMP_TARGET_Q8_8);
    assign pid_err_diff_comb = pid_err_comb - pid_err_prev_q;

    assign p_term_wide       = $signed(eff_kp_q8_8) * $signed(pid_err_comb);
    assign i_step_wide       = $signed(eff_ki_q8_8) * $signed(pid_err_comb);
    assign d_term_wide       = $signed(eff_kd_q8_8) * $signed(pid_err_diff_comb);

    assign p_term_s24        = p_term_wide[31:8];
    assign d_term_s24        = d_term_wide[31:8];
    assign integ_candidate_s24 = pid_integ_q + i_step_wide[31:8];
    wire _unused_pid_frac = &{1'b0, p_term_wide[7:0], i_step_wide[7:0], d_term_wide[7:0], 32'(NUM_TILES)};

    always_comb begin
        if (integ_candidate_s24 > 24'($signed(INTEG_MAX)))
            pid_integ_next = 24'($signed(INTEG_MAX));
        else if (integ_candidate_s24 < 24'($signed(INTEG_MIN)))
            pid_integ_next = 24'($signed(INTEG_MIN));
        else
            pid_integ_next = integ_candidate_s24;

        pid_sum_s24 = p_term_s24 + pid_integ_next + d_term_s24;
        if (pid_sum_s24 > 24'sd32767)
            pid_out_comb = 16'sd32767;
        else if (pid_sum_s24 < -24'sd32768)
            pid_out_comb = -16'sd32768;
        else
            pid_out_comb = pid_sum_s24[15:0];

        if (!dvfs_en_i)
            pid_target_pstate_comb = P1_NOMINAL_1250MHZ;
        else if (temp_c_q8_8_q >= TEMP_TRIP_Q8_8 || temp_c_q8_8_q >= TEMP_CRIT_Q8_8 || pid_out_comb >= 16'sd3072)
            pid_target_pstate_comb = P3_THROTTLE_700MHZ;
        else if (pid_out_comb >= 16'sd1024)
            pid_target_pstate_comb = P2_ECO_1000MHZ;
        else if (pid_out_comb >= 16'sd0)
            pid_target_pstate_comb = P1_NOMINAL_1250MHZ;
        else
            pid_target_pstate_comb = P0_TURBO_1400MHZ;
    end

    // -------------------------------------------------------------------------
    // 4. 2-Stage Cross-Coupled Break-Before-Make Glitch-Free Clock-Mux FSM
    // -------------------------------------------------------------------------
    typedef enum logic [1:0] {
        BBM_RUN   = 2'd0,
        BBM_BREAK = 2'd1,
        BBM_MAKE  = 2'd2
    } bbm_state_e;

    bbm_state_e  bbm_state_q;
    logic [3:0]  clk_path_en_q;
    logic [3:0]  div9_cnt_q;
    logic [2:0]  div7_cnt_q;
    logic        div2_toggle_q;
    logic [3:0]  pstate_div_waveforms;
    logic        clk_gate_ack_q, pstate_busy_q;
    logic [15:0] pstate_switch_cnt_q, throttle_cycles_cnt_q;

    assign pstate_div_waveforms[0] = 1'b1;                           // P0: div-by-1.00 (1400 MHz)
    assign pstate_div_waveforms[1] = (div9_cnt_q != 4'd8);           // P1: div-by-1.12 (8/9 = 1244 MHz)
    assign pstate_div_waveforms[2] = (div7_cnt_q < 3'd5);            // P2: div-by-1.40 (5/7 = 1000 MHz)
    assign pstate_div_waveforms[3] = div2_toggle_q;                  // P3: div-by-2.00 (1/2 =  700 MHz)

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            temp_c_q8_8_q         <= 16'h2D00; // 45.0 C initial junction temp
            est_power_q           <= 16'hC800; // 200.0 W initial estimate
            pid_err_prev_q        <= 16'sd0;
            pid_integ_q           <= 24'sd0;
            pid_out_q             <= 16'sd0;
            target_pstate_q       <= P1_NOMINAL_1250MHZ;
            active_pstate_q       <= P1_NOMINAL_1250MHZ;
            clk_path_en_q         <= 4'b0010;  // Only P1 enabled at reset
            bbm_state_q           <= BBM_RUN;
            clk_gate_ack_q        <= 1'b0;
            pstate_busy_q         <= 1'b0;
            div9_cnt_q            <= 4'd0;
            div7_cnt_q            <= 3'd0;
            div2_toggle_q         <= 1'b1;
            pstate_switch_cnt_q   <= 16'd0;
            throttle_cycles_cnt_q <= 16'd0;
        end else begin
            // Fractional / integer DFS phase accumulators
            div9_cnt_q    <= (div9_cnt_q == 4'd8) ? 4'd0 : (div9_cnt_q + 4'd1);
            div7_cnt_q    <= (div7_cnt_q == 3'd6) ? 3'd0 : (div7_cnt_q + 3'd1);
            div2_toggle_q <= ~div2_toggle_q;

            // Update PVT temperature, power & PID governor on sample_valid_i or thermal overload
            if (sample_valid_i) begin
                temp_c_q8_8_q  <= next_temp_q8_8;
                pid_err_prev_q <= pid_err_comb;
                pid_integ_q    <= pid_integ_next;
                pid_out_q      <= pid_out_comb;
            end
            est_power_q     <= static_leak_q8_8 +
                               ({10'd0, active_tiles_cnt_i} * tile_pwr_coeff_q8_8) +
                               ({12'd0, c2c_activity_i} * 16'h0133);
            target_pstate_q <= pid_target_pstate_comb;

            if (active_pstate_q >= P2_ECO_1000MHZ)
                throttle_cycles_cnt_q <= throttle_cycles_cnt_q + 16'd1;

            // Break-Before-Make Glitch-Free Clock-Mux Handshake FSM
            if (temp_c_q8_8_q >= TEMP_TRIP_Q8_8) begin
                // Emergency Thermal Trip (>= 95.0 C): immediate break-before-make to P3
                active_pstate_q <= P3_THROTTLE_700MHZ;
                if (clk_path_en_q != 4'b0000 && clk_path_en_q != 4'b1000) begin
                    clk_path_en_q  <= 4'b0000;
                    clk_gate_ack_q <= 1'b1;
                    pstate_busy_q  <= 1'b1;
                    bbm_state_q    <= BBM_BREAK;
                end else begin
                    clk_path_en_q  <= 4'b1000;
                    clk_gate_ack_q <= 1'b0;
                    pstate_busy_q  <= 1'b0;
                    bbm_state_q    <= BBM_RUN;
                end
            end else begin
                unique case (bbm_state_q)
                    BBM_RUN: begin
                        if (pid_target_pstate_comb != active_pstate_q) begin
                            clk_path_en_q   <= 4'b0000; // Break all paths first!
                            active_pstate_q <= pid_target_pstate_comb;
                            clk_gate_ack_q  <= 1'b1;
                            pstate_busy_q   <= 1'b1;
                            bbm_state_q     <= BBM_BREAK;
                        end else begin
                            clk_path_en_q   <= (4'b0001 << active_pstate_q);
                            clk_gate_ack_q  <= 1'b0;
                            pstate_busy_q   <= 1'b0;
                        end
                    end
                    BBM_BREAK: begin
                        // Make new clock path only after 1 full cycle of all-zero break
                        clk_path_en_q       <= (4'b0001 << active_pstate_q);
                        clk_gate_ack_q      <= 1'b0;
                        pstate_busy_q       <= 1'b0;
                        pstate_switch_cnt_q <= pstate_switch_cnt_q + 16'd1;
                        bbm_state_q         <= BBM_RUN;
                    end
                    default: begin
                        clk_path_en_q  <= 4'b0000;
                        bbm_state_q    <= BBM_BREAK;
                    end
                endcase
            end
        end
    end

    // -------------------------------------------------------------------------
    // 5. Continuous Output Assignments
    // -------------------------------------------------------------------------
    assign temp_c_q8_8_o            = temp_c_q8_8_q;
    assign vdd_mv_o                 = vdd_mv_comb;
    assign est_power_w_q8_8_o       = est_power_q;
    assign pid_err_q8_8_o           = pid_err_comb;
    assign pid_integ_o              = pid_integ_q;
    assign pid_out_o                = pid_out_q;
    assign target_pstate_o          = target_pstate_q;
    assign active_pstate_o          = active_pstate_q;
    assign clk_path_en_o            = clk_path_en_q;
    assign dfs_clk_en_o             = |(clk_path_en_q & pstate_div_waveforms);
    assign clk_gate_ack_o           = clk_gate_ack_q;
    assign pstate_transition_busy_o = pstate_busy_q;
    assign thermal_warn_irq_o       = (temp_c_q8_8_q >= TEMP_CRIT_Q8_8);
    assign thermal_trip_irq_o       = (temp_c_q8_8_q >= TEMP_TRIP_Q8_8);
    assign pstate_switch_cnt_o      = pstate_switch_cnt_q;
    assign throttle_cycles_cnt_o    = throttle_cycles_cnt_q;

    // -------------------------------------------------------------------------
    // 6. Formal Verification Properties (Yosys 16-Cycle Bounded Model Check)
    // -------------------------------------------------------------------------
`ifdef FORMAL
    logic f_past_valid = 1'b0;
    always @(posedge clk) f_past_valid <= 1'b1;

    always @(*) begin
        if (!f_past_valid) assume (!rst_n);
        else               assume (rst_n);
    end

    always @(posedge clk) begin
        if (rst_n) begin
            // 1. PROP_M19_BREAK_BEFORE_MAKE_NO_GLITCH:
            //    Never enables more than one P-state clock-enable path simultaneously
            //    ($onehot0(clk_path_en_o)) and enforces an all-zero break cycle between switches.
            PROP_M19_BREAK_BEFORE_MAKE_NO_GLITCH: assert (
                $onehot0(clk_path_en_o) &&
                (!f_past_valid || !$past(rst_n) ||
                 clk_path_en_o == 4'b0000 ||
                 $past(clk_path_en_o) == 4'b0000 ||
                 clk_path_en_o == $past(clk_path_en_o))
            );

            // 2. PROP_M19_ANTI_WINDUP_BOUND:
            //    PID integral accumulator pid_integ_q never exceeds [INTEG_MIN, INTEG_MAX].
            PROP_M19_ANTI_WINDUP_BOUND: assert (
                (pid_integ_q >= 24'($signed(INTEG_MIN))) &&
                (pid_integ_q <= 24'($signed(INTEG_MAX)))
            );

            // 3. PROP_M19_THERMAL_TRIP_SAFETY:
            //    Whenever temp_c_q8_8_o >= TEMP_TRIP_Q8_8, thermal_trip_irq_o == 1'b1
            //    and active_pstate_o == P3_THROTTLE_700MHZ within 2 cycles.
            if (temp_c_q8_8_o >= TEMP_TRIP_Q8_8) begin
                PROP_M19_THERMAL_TRIP_SAFETY_IRQ: assert (thermal_trip_irq_o == 1'b1);
            end
            if (f_past_valid && $past(rst_n) && ($past(temp_c_q8_8_o) >= TEMP_TRIP_Q8_8)) begin
                PROP_M19_THERMAL_TRIP_SAFETY: assert (active_pstate_o == P3_THROTTLE_700MHZ);
            end
        end
    end
`endif

endmodule
