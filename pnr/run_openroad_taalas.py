#!/usr/bin/env python3
"""
Stage 13: OpenROAD Physical Implementation — Floorplanning, Placement, CTS,
Routing, DEF/Layout Generation, Wirelength, Congestion, & PDNSim IR-Drop Analysis
for Taalas HC1/HC2 Core IP Macros vs. Conventional Booth MAC + Weight Buffer Baseline.
"""

import os
import re
import math
import time
import json
import shutil
import subprocess

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
RTL_DIR = os.path.join(ROOT, "rtl")
SYNTH_DIR = os.path.join(ROOT, "synth")
PNR_DIR = os.path.join(ROOT, "pnr")
LOGS_DIR = os.path.join(PNR_DIR, "logs")
RESULTS_DIR = os.path.join(ROOT, "results")

ASAP7_LIB_PATH = os.path.join(SYNTH_DIR, "lib", "asap7_rvt_ff.lib")
SKY130_LIB_PATH = os.path.join(SYNTH_DIR, "lib", "sky130_fd_sc_hd__tt_025C_1v80.lib")
ABC_SPEED_SCRIPT = "/home/chenpei1/MLBuf_MLCAD/OpenROAD-flow-scripts/flow/scripts/abc_speed.script"
GBI_TEST_DIR = "/home/chenpei1/benchmark/gbi/test"

OPENROAD_CANDIDATES = [
    "/home/chenpei1/ISPD26-Contest/OpenROAD/build/bin/openroad",
    "/nfs/share/home/chenpei/hyr/dac2027/runs/architecture_p31_cluster_intervals_v1/tools/api_prebuilt/usr/bin/openroad",
]
OPENROAD_BIN = next((p for p in OPENROAD_CANDIDATES if os.path.exists(p)), OPENROAD_CANDIDATES[0])

os.makedirs(PNR_DIR, exist_ok=True)
os.makedirs(LOGS_DIR, exist_ok=True)
os.makedirs(RESULTS_DIR, exist_ok=True)


def parse_def_spef_drc(work_dir, design_name, platform="asap7"):
    def_candidates = [
        os.path.join(work_dir, "results", f"{design_name}_{platform}_route-tcl.def"),
        os.path.join(work_dir, "results", f"{design_name}_{platform}_route.def"),
    ]
    spef_candidates = [
        os.path.join(work_dir, "results", f"{design_name}_{platform}-tcl.spef"),
        os.path.join(work_dir, "results", f"{design_name}_{platform}.spef"),
    ]
    drc_candidates = [
        os.path.join(work_dir, "results", f"{design_name}_{platform}_route_drc-tcl.rpt"),
        os.path.join(work_dir, "results", f"{design_name}_{platform}_route_drc.rpt"),
    ]
    def_path = next((p for p in def_candidates if os.path.exists(p)), def_candidates[0])
    spef_path = next((p for p in spef_candidates if os.path.exists(p)), spef_candidates[0])
    drc_path = next((p for p in drc_candidates if os.path.exists(p)), drc_candidates[0])

    drc_violations_in_rpt = 0
    if os.path.exists(drc_path):
        with open(drc_path, "r", errors="ignore") as df:
            drc_violations_in_rpt = sum(1 for ln in df if "violation type:" in ln.lower())

    dbu_per_um = 1000.0
    def_stats = {
        "def_path": def_path,
        "def_file_exists": os.path.exists(def_path),
        "spef_file_exists": os.path.exists(spef_path),
        "drc_report_exists": os.path.exists(drc_path),
        "drc_violations_in_rpt": drc_violations_in_rpt,
        "def_size_bytes": os.path.getsize(def_path) if os.path.exists(def_path) else 0,
        "spef_size_bytes": os.path.getsize(spef_path) if os.path.exists(spef_path) else 0,
        "metal_wirelength_um": {},
        "via_counts": {},
        "clock_buffer_instances": 0,
        "tap_and_decap_instances": 0,
        "filler_instances": 0,
        "total_physical_components": 0,
        "routed_nets_count": 0,
        "io_pins_count": 0,
    }
    if not os.path.exists(def_path):
        return def_stats

    metal_wl_dbu = {}
    via_cnt = {}
    in_specialnets = False
    with open(def_path, "r", errors="ignore") as f:
        for line in f:
            if line.startswith("UNITS DISTANCE MICRONS"):
                m_u = re.search(r"UNITS DISTANCE MICRONS\s+(\d+)", line)
                if m_u:
                    dbu_per_um = float(m_u.group(1))
            elif line.startswith("SPECIALNETS "):
                in_specialnets = True
            elif line.startswith("END SPECIALNETS"):
                in_specialnets = False
            elif line.startswith("PINS "):
                m_p = re.search(r"PINS\s+(\d+)", line)
                if m_p:
                    def_stats["io_pins_count"] = int(m_p.group(1))
            elif line.startswith("COMPONENTS "):
                m = re.search(r"COMPONENTS\s+(\d+)", line)
                if m:
                    def_stats["total_physical_components"] = int(m.group(1))
            elif line.startswith("NETS "):
                m = re.search(r"NETS\s+(\d+)", line)
                if m:
                    def_stats["routed_nets_count"] = int(m.group(1))
            elif "clkbuf_" in line or "clkinv_" in line or "BUFx" in line or "INVx" in line:
                def_stats["clock_buffer_instances"] += 1
            elif "tapvpwrvgnd" in line or "TAPCELL_" in line or "DECAP" in line:
                def_stats["tap_and_decap_instances"] += 1
            elif "FILLER" in line or "sky130_fd_sc_hd__fill_" in line:
                def_stats["filler_instances"] += 1
            elif ("NEW " in line or "ROUTED " in line) and not in_specialnets:
                m_layer = re.search(
                    r"(?:ROUTED|NEW)\s+(li1|met[1-5]|M[1-7])\s+\(\s*(-?\d+)\s+(-?\d+)\s*\)\s+\(\s*(-?\d+|\*)\s+(-?\d+|\*)\s*\)",
                    line,
                )
                if m_layer:
                    lyr = m_layer.group(1)
                    x1, y1 = int(m_layer.group(2)), int(m_layer.group(3))
                    x2 = x1 if m_layer.group(4) == "*" else int(m_layer.group(4))
                    y2 = y1 if m_layer.group(5) == "*" else int(m_layer.group(5))
                    metal_wl_dbu[lyr] = metal_wl_dbu.get(lyr, 0) + abs(x2 - x1) + abs(y2 - y1)
                for v in re.findall(
                    r"\b(VIA[1-6][2-7][A-Za-z0-9_]*|M[1-4]M[2-5]_PR|L1M1_PR|via[1-6]?_[0-9]+|V[1-6]_[0-9A-Za-z_]+)\b",
                    line,
                ):
                    via_cnt[v] = via_cnt.get(v, 0) + 1

    def_stats["metal_wirelength_um"] = {k: round(v / dbu_per_um, 2) for k, v in sorted(metal_wl_dbu.items())}
    def_stats["total_routed_wirelength_um"] = round(sum(metal_wl_dbu.values()) / dbu_per_um, 2)
    def_stats["via_counts"] = via_cnt
    def_stats["total_vias"] = sum(via_cnt.values())
    return def_stats


def compute_die_and_core_area(synth_area_um2, num_io_pins, platform="asap7", target_util=0.32):
    if platform == "asap7":
        # Site height = 0.27 um, 4 rows = 1.08 um, core margin = 2.16 um (8 rows)
        core_side_from_area = math.sqrt(max(synth_area_um2, 100.0) / target_util)
        core_side_from_pins = max(24.0, num_io_pins * 0.145)
        raw_die_side = max(core_side_from_area, core_side_from_pins) + 4.32
        die_side = round(math.ceil(raw_die_side / 2.16) * 2.16, 2)
        margin = 2.16
        core_hi = round(die_side - margin, 2)
        die_str = f"0 0 {die_side:.2f} {die_side:.2f}"
        core_str = f"{margin:.2f} {margin:.2f} {core_hi:.2f} {core_hi:.2f}"
        die_area_um2 = round(die_side * die_side, 2)
        core_area_um2 = round((core_hi - margin) ** 2, 2)
    else:
        # Sky130HD: core margin = 20 um, round die_side to multiple of 20 um
        core_side_from_area = math.sqrt(max(synth_area_um2, 2500.0) / target_util)
        core_side_from_pins = max(140.0, num_io_pins * 1.15)
        raw_die_side = max(core_side_from_area, core_side_from_pins) + 40.0
        die_side = int(math.ceil(raw_die_side / 20.0) * 20)
        margin = 20
        core_hi = die_side - margin
        die_str = f"0 0 {die_side} {die_side}"
        core_str = f"{margin} {margin} {core_hi} {core_hi}"
        die_area_um2 = float(die_side * die_side)
        core_area_um2 = float((core_hi - margin) ** 2)
    return die_str, core_str, die_side, die_area_um2, core_area_um2


def run_openroad_pnr_module(cfg):
    t0 = time.time()
    design_name = cfg["design"]
    rtl_file = cfg["rtl"]
    chparam_str = cfg.get("chparam", "")
    platform = cfg["platform"]
    clk_period = cfg["clk_period"]
    sub_dir = f"{design_name}_{platform}"
    target_util = cfg.get("target_util", 0.32)
    scale_to_full_macro = cfg.get("scale_to_full_macro", 1.0)
    full_macro_desc = cfg.get("full_macro_desc", design_name)

    unit_str = "ps" if platform == "asap7" else "ns"
    print(f"\n[Stage 13] Running Yosys + OpenROAD Full P&R ({platform.upper()}) for '{design_name}' (target clk={clk_period} {unit_str})...")

    work_dir = os.path.join(PNR_DIR, sub_dir)
    os.makedirs(os.path.join(work_dir, "results"), exist_ok=True)

    for link_name in [platform, "helpers.tcl", "flow_helpers.tcl"]:
        dst = os.path.join(work_dir, link_name)
        if not os.path.exists(dst):
            os.symlink(os.path.join(GBI_TEST_DIR, link_name), dst)

    netlist_v = os.path.join(work_dir, f"{design_name}_netlist.v")
    mem_map_cmd = "" if "sram_6t" in design_name else "memory_map; opt -fast; "

    if platform == "asap7":
        dont_use_flags = "-dont_use *x1p*_ASAP7* -dont_use *xp*_ASAP7* -dont_use SDF* -dont_use ICG*"
        yosys_cmd = (
            f"read_verilog -sv -DYOSYS -defer {rtl_file}; "
            f"hierarchy -check -top {design_name} {chparam_str}; "
            f"chformal -remove; proc; opt -fast; fsm; opt -fast; memory -nomap; opt_clean; {mem_map_cmd}"
            f"synth -top {design_name} -flatten -noabc; "
            f"dfflibmap -liberty {ASAP7_LIB_PATH} {dont_use_flags}; opt; "
            f"abc -liberty {ASAP7_LIB_PATH} {dont_use_flags} -D {int(clk_period * 0.45)} -script {ABC_SPEED_SCRIPT}; "
            f"setundef -zero; splitnets; opt_clean -purge; "
            f"hilomap -singleton -hicell TIEHIx1_ASAP7_75t_R H -locell TIELOx1_ASAP7_75t_R L; "
            f"insbuf -buf BUFx2_ASAP7_75t_R A Y; opt_clean -purge; "
            f"stat -liberty {ASAP7_LIB_PATH}; "
            f"write_verilog -noattr -noexpr -nohex -nodec {netlist_v}"
        )
    else:
        yosys_cmd = (
            f"read_verilog -sv -DYOSYS -defer {rtl_file}; "
            f"hierarchy -check -top {design_name} {chparam_str}; "
            f"chformal -remove; proc; opt -fast; fsm; opt -fast; memory -nomap; opt_clean; {mem_map_cmd}"
            f"synth -top {design_name} -flatten; "
            f"dfflibmap -liberty {SKY130_LIB_PATH}; "
            f"abc -liberty {SKY130_LIB_PATH} -D {int(clk_period * 750)} -script {ABC_SPEED_SCRIPT}; "
            f"setundef -zero; splitnets; opt_clean -purge; "
            f"hilomap -hicell sky130_fd_sc_hd__conb_1 HI -locell sky130_fd_sc_hd__conb_1 LO; "
            f"insbuf -buf sky130_fd_sc_hd__buf_2 A X; opt_clean -purge; "
            f"stat -liberty {SKY130_LIB_PATH}; "
            f"write_verilog -noattr -noexpr -nohex -nodec {netlist_v}"
        )

    y_res = subprocess.run(["/usr/local/bin/yosys", "-p", yosys_cmd], check=True, capture_output=True, text=True)
    y_out = y_res.stdout

    synth_cells = 0
    synth_area = 0.0
    m_c = re.findall(r"Number of cells:\s+(\d+)", y_out)
    if m_c:
        synth_cells = int(m_c[-1])
    m_a = re.findall(r"Chip area for module.*?:\s+([0-9.]+)", y_out)
    if m_a:
        synth_area = float(m_a[-1])

    # Count IO pins from synthesized netlist
    num_io_pins = 0
    with open(netlist_v, "r", errors="ignore") as nf:
        for ln in nf:
            ln_s = ln.strip()
            if ln_s.startswith("input ") or ln_s.startswith("output "):
                m_rng = re.search(r"\[\s*(\d+)\s*:\s*(\d+)\s*\]", ln_s)
                if m_rng:
                    num_io_pins += abs(int(m_rng.group(1)) - int(m_rng.group(2))) + 1
                else:
                    num_io_pins += 1

    die_area, core_area, die_side, die_area_um2, core_area_um2 = compute_die_and_core_area(
        synth_area, num_io_pins, platform=platform, target_util=target_util
    )

    with open(os.path.join(GBI_TEST_DIR, "flow.tcl"), "r") as f:
        flow_txt = f.read()
    flow_txt = flow_txt.replace("set_thread_count [cpu_count]", "set_thread_count 16")
    flow_txt = flow_txt.replace("global_placement -routability_driven", "global_placement")
    flow_txt = flow_txt.replace("repair_timing -skip_gate_cloning", "repair_timing -hold -skip_gate_cloning")
    vdd_v = 0.77 if platform == "asap7" else 1.80
    flow_txt += (
        f"\n# Power Grid IR Drop Analysis (PDNSim)\n"
        f"set_pdnsim_net_voltage -net VDD -voltage {vdd_v}\n"
        f"analyze_power_grid -net VDD\n"
        f"set_pdnsim_net_voltage -net VSS -voltage 0.0\n"
        f"analyze_power_grid -net VSS\n"
    )

    custom_flow_path = os.path.join(work_dir, "custom_flow.tcl")
    with open(custom_flow_path, "w") as f:
        f.write(flow_txt)

    sdc_path = os.path.join(work_dir, f"{design_name}.sdc")
    with open(sdc_path, "w") as f:
        f.write(
            f"create_clock [get_ports clk] -name core_clock -period {clk_period}\n"
            f"set_all_input_output_delays 0.05\n"
        )

    tcl_content = f"""source "helpers.tcl"
source "flow_helpers.tcl"
source "{platform}/{platform}.vars"
set design "{design_name}"
set top_module "{design_name}"
set synth_verilog "{design_name}_netlist.v"
set sdc_file "{design_name}.sdc"
set die_area {{{die_area}}}
set core_area {{{core_area}}}
include -echo "custom_flow.tcl"
exit
"""
    run_tcl_path = os.path.join(work_dir, "run_pnr.tcl")
    with open(run_tcl_path, "w") as f:
        f.write(tcl_content)
    shutil.copyfile(run_tcl_path, os.path.join(PNR_DIR, f"{design_name}_{platform}.tcl"))

    log_path = os.path.join(work_dir, f"or_{design_name}_{platform}.log")
    top_log_path = os.path.join(LOGS_DIR, f"or_{design_name}_{platform}.log")
    top_def_check = os.path.join(PNR_DIR, f"{design_name}_{platform}_route.def")

    if not (os.path.exists(top_def_check) and os.path.exists(top_log_path) and os.path.getsize(top_def_check) > 1000):
        env = os.environ.copy()
        env["OMP_NUM_THREADS"] = "16"
        with open(log_path, "w") as lf:
            subprocess.run(
                [OPENROAD_BIN, "-threads", "16", "-exit", "run_pnr.tcl"],
                cwd=work_dir,
                env=env,
                stdout=lf,
                stderr=subprocess.STDOUT,
                check=True,
            )
        shutil.copyfile(log_path, top_log_path)

    with open(top_log_path, "r", errors="ignore") as lf:
        or_log = lf.read()

    def extract_float(pattern, default=0.0):
        m = re.findall(pattern, or_log)
        return float(m[-1]) if m else default

    if synth_cells == 0:
        m_mov = re.findall(r"Movable instances:\s+(\d+)", or_log)
        if m_mov:
            synth_cells = int(m_mov[0])
    if synth_area == 0.0:
        m_sa = re.findall(r"Standard cells area:\s+([0-9.]+)\s+um\^2", or_log)
        if m_sa:
            synth_area = float(m_sa[0])

    wns_min = extract_float(r"worst slack min\s+([-0-9.]+)")
    wns_max = extract_float(r"worst slack max\s+([-0-9.]+)")
    tns_max = extract_float(r"tns max\s+([-0-9.]+)")
    clk_skew = extract_float(r"([-0-9.]+)\s+setup skew")
    crit_path = round(clk_period - wns_max, 3)

    hpwl_orig = extract_float(r"original HPWL\s+([0-9.]+)\s*u")
    hpwl_legal = extract_float(r"legalized HPWL\s+([0-9.]+)\s*u")
    grt_wl = extract_float(r"\[INFO GRT-0018\] Total wirelength:\s+([0-9.]+)\s*um")

    m_area = re.findall(r"Design area\s+([0-9.]+)\s+um?\^2\s+([0-9.]+)%\s+utilization", or_log)
    design_area_u2 = float(m_area[-1][0]) if m_area else synth_area
    util_pct = float(m_area[-1][1]) if m_area else round(synth_area / max(core_area_um2, 1.0) * 100.0, 1)

    # Parse Global Routing Congestion Report (GRT-0096)
    congestion_layers = {}
    total_overflow = 0
    total_usage_pct = 0.0
    m_cong_block = re.search(
        r"\[INFO GRT-0096\] Final congestion report:\s*\n.*?\n-+\n(.*?)\n-+\nTotal\s+(\d+)\s+(\d+)\s+([0-9.]+)%\s+(\d+)\s*/\s*(\d+)\s*/\s*(\d+)",
        or_log,
        re.S,
    )
    if m_cong_block:
        layer_lines = m_cong_block.group(1).strip().splitlines()
        for l_ln in layer_lines:
            m_l = re.match(
                r"(\S+)\s+(\d+)\s+(\d+)\s+([0-9.]+)%\s+(\d+)\s*/\s*(\d+)\s*/\s*(\d+)",
                l_ln.strip(),
            )
            if m_l:
                congestion_layers[m_l.group(1)] = {
                    "resource": int(m_l.group(2)),
                    "demand": int(m_l.group(3)),
                    "usage_pct": float(m_l.group(4)),
                    "max_h_overflow": int(m_l.group(5)),
                    "max_v_overflow": int(m_l.group(6)),
                    "total_overflow": int(m_l.group(7)),
                }
        total_usage_pct = float(m_cong_block.group(4))
        total_overflow = int(m_cong_block.group(7))

    def extract_power_row(label):
        m = re.findall(rf"{label}\s+([0-9.eE+-]+)\s+([0-9.eE+-]+)\s+([0-9.eE+-]+)\s+([0-9.eE+-]+)", or_log)
        if m:
            row = m[-1]
            return {
                "internal_mw": round(float(row[0]) * 1000.0, 4),
                "switching_mw": round(float(row[1]) * 1000.0, 4),
                "leakage_mw": round(float(row[2]) * 1000.0, 6),
                "total_mw": round(float(row[3]) * 1000.0, 4),
            }
        return {}

    power_breakdown = {
        "sequential": extract_power_row("Sequential"),
        "combinational": extract_power_row("Combinational"),
        "clock": extract_power_row("Clock"),
        "total": extract_power_row("Total"),
    }

    drc_matches = re.findall(r"Number of violations\s*=\s*(\d+)", or_log)
    final_drc = int(drc_matches[-1]) if drc_matches else 0
    ant_net_m = re.findall(r"Violated nets:\s*(\d+)", or_log)
    final_antenna_nets = int(ant_net_m[-1]) if ant_net_m else 0

    ir_matches = re.findall(
        r"Net\s*:\s*(VDD|VSS).*?Supply voltage\s*:\s*([0-9.eE+-]+)\s*V.*?Worstcase voltage\s*:\s*([0-9.eE+-]+)\s*V.*?Average IR drop\s*:\s*([0-9.eE+-]+)\s*V.*?Worstcase IR drop\s*:\s*([0-9.eE+-]+)\s*V.*?Percentage drop\s*:\s*([0-9.]+)\s*%",
        or_log,
        re.S,
    )
    ir_drop_report = {}
    for net_name, sup_v, wc_v, avg_ir, wc_ir, pct_ir in ir_matches:
        ir_drop_report[net_name] = {
            "supply_voltage_v": float(sup_v),
            "worstcase_voltage_v": float(wc_v),
            "avg_ir_drop_mv": round(float(avg_ir) * 1000.0, 4),
            "worstcase_ir_drop_mv": round(float(wc_ir) * 1000.0, 4),
            "pct_drop": float(pct_ir),
        }

    def_spef_info = parse_def_spef_drc(work_dir, design_name, platform=platform)
    if def_spef_info.get("def_file_exists") and os.path.exists(def_spef_info["def_path"]):
        top_def = os.path.join(PNR_DIR, f"{design_name}_{platform}_route.def")
        shutil.copyfile(def_spef_info["def_path"], top_def)
        def_spef_info["top_def_path"] = top_def

    elapsed = round(time.time() - t0, 2)
    fmax_mhz = round((1000000.0 if platform == "asap7" else 1000.0) / max(crit_path, 1e-3), 2)
    routed_wl_um = def_spef_info.get("total_routed_wirelength_um", 0.0) or grt_wl

    result = {
        "design": design_name,
        "full_macro_description": full_macro_desc,
        "platform": platform,
        "chparam": chparam_str,
        "scale_to_full_macro": scale_to_full_macro,
        "target_clock_period": clk_period,
        "time_unit": unit_str,
        "io_pins_count": num_io_pins,
        "die_dimensions_um": f"{die_side} x {die_side}",
        "die_area_um2": die_area_um2,
        "core_area_um2": core_area_um2,
        "yosys_mapped_cells": synth_cells,
        "yosys_cell_area_um2": round(synth_area, 2),
        "openroad_design_area_um2": design_area_u2,
        "tsmc_n6_scaled_design_area_um2": round(design_area_u2 * (0.86 if platform == "asap7" else 1.0), 2),
        "full_macro_routed_design_area_um2": round(design_area_u2 * scale_to_full_macro, 2),
        "full_macro_routed_wirelength_um": round(routed_wl_um * scale_to_full_macro, 2),
        "core_utilization_pct": util_pct,
        "hpwl_original_um": hpwl_orig,
        "hpwl_legalized_um": hpwl_legal,
        "global_route_wirelength_um": grt_wl,
        "detailed_route_wirelength_um": routed_wl_um,
        "post_route_critical_path": round(crit_path, 3),
        "post_route_fmax_mhz": fmax_mhz,
        "wns_setup": round(wns_max, 3),
        "wns_hold": round(wns_min, 3),
        "tns_setup": round(tns_max, 3),
        "clock_skew": round(abs(clk_skew), 3),
        "routing_congestion_usage_pct": total_usage_pct,
        "routing_congestion_overflow": total_overflow,
        "routing_congestion_by_layer": congestion_layers,
        "final_drc_violations": final_drc,
        "final_antenna_violations": final_antenna_nets,
        "power_breakdown_mw": power_breakdown,
        "pdnsim_ir_drop": ir_drop_report,
        "physical_layout_stats": def_spef_info,
        "pnr_runtime_sec": elapsed,
    }
    vdd_ir_mv = ir_drop_report.get("VDD", {}).get("worstcase_ir_drop_mv", 0.0)
    vdd_ir_pct = ir_drop_report.get("VDD", {}).get("pct_drop", 0.0)
    print(
        f"  -> [{design_name} @ {platform}] Cells={synth_cells} | DesignArea={design_area_u2} um^2 ({util_pct}% util) "
        f"| WL={routed_wl_um} um | Overflow={total_overflow} | DRC={final_drc} "
        f"| WNS={wns_max}{unit_str} | Skew={abs(clk_skew):.2f}{unit_str} | Fmax={fmax_mhz}MHz "
        f"| Power={power_breakdown.get('total',{}).get('total_mw',0)}mW | VDD_IR={vdd_ir_mv}mV ({vdd_ir_pct}%) [{elapsed}s]"
    )
    return result


def main():
    t0_all = time.time()
    asap7_configs = [
        {
            "design": "taalas_3b6b_wired_mac_array",
            "full_macro_desc": "Taalas HC1 Multiplierless 3b/6b CSD Wired MAC Array (32-MAC Sub-Array Slice -> 32x Scaled 1024-MAC Array)",
            "rtl": os.path.join(RTL_DIR, "taalas_3b6b_wired_mac_array.sv"),
            "chparam": "-chparam VEC_LEN 8 -chparam OUT_CHANNELS 4 -chparam NUM_OUTLIERS 2",
            "platform": "asap7",
            "clk_period": 800.0,
            "target_util": 0.34,
            "scale_to_full_macro": 32.0,
        },
        {
            "design": "baseline_fp16_int8_mac_array",
            "full_macro_desc": "Conventional Booth INT8xINT8 + FP16 Scale MAC Array + Active Weight Registers (32-MAC Slice -> 32x Scaled 1024-MAC Array)",
            "rtl": os.path.join(SYNTH_DIR, "baseline_fp16_int8_mac_array.sv"),
            "chparam": "-chparam VEC_LEN 8 -chparam OUT_CHANNELS 4",
            "platform": "asap7",
            "clk_period": 800.0,
            "target_util": 0.34,
            "scale_to_full_macro": 32.0,
        },
        {
            "design": "taalas_sram_6t_banked_macro",
            "full_macro_desc": "16-Bank GF(2^4) Swizzled SECDED (72,64) 6T SRAM Controller + ECC Core",
            "rtl": os.path.join(RTL_DIR, "taalas_sram_6t_banked_macro.sv"),
            "chparam": "-chparam NUM_BANKS 8 -chparam BANK_DEPTH 4 -chparam DATA_WIDTH 64 -chparam ECC_WIDTH 8 -chparam RAW_WIDTH 72",
            "platform": "asap7",
            "clk_period": 800.0,
            "target_util": 0.34,
            "scale_to_full_macro": 2.0,
        },
        {
            "design": "taalas_mxfp4_hc2_mac_lane",
            "full_macro_desc": "Taalas HC2 OCP MXFP4 E2M1 Multiplierless Compute Lane + Shared E8M0 Scale Unit",
            "rtl": os.path.join(RTL_DIR, "taalas_mxfp4_hc2_mac_lane.sv"),
            "chparam": "-chparam BLOCK_SIZE 8 -chparam NUM_LANES 4",
            "platform": "asap7",
            "clk_period": 800.0,
            "target_util": 0.34,
            "scale_to_full_macro": 8.0,
        },
        {
            "design": "taalas_token_pipe_noc_router",
            "full_macro_desc": "Credit-Based Wormhole Spatial Token-Pipe NoC Router (128-bit Flit, 2-Deep Skid Buffer + 8-Entry FIFO)",
            "rtl": os.path.join(RTL_DIR, "taalas_token_pipe_noc_router.sv"),
            "chparam": "-chparam FLIT_WIDTH 128 -chparam FIFO_DEPTH 8 -chparam MAX_CREDITS 8 -chparam TILE_ID 0",
            "platform": "asap7",
            "clk_period": 800.0,
            "target_util": 0.32,
            "scale_to_full_macro": 1.0,
        },
    ]

    sky130_configs = [
        {
            "design": "taalas_3b6b_wired_mac_array",
            "full_macro_desc": "Taalas HC1 Multiplierless 3b/6b CSD Wired MAC Array (Sky130HD 130nm Cross-PDK Validation)",
            "rtl": os.path.join(RTL_DIR, "taalas_3b6b_wired_mac_array.sv"),
            "chparam": "-chparam VEC_LEN 8 -chparam OUT_CHANNELS 4 -chparam NUM_OUTLIERS 2",
            "platform": "sky130hd",
            "clk_period": 12.0,
            "target_util": 0.34,
            "scale_to_full_macro": 32.0,
        },
        {
            "design": "baseline_fp16_int8_mac_array",
            "full_macro_desc": "Conventional Booth INT8xINT8 + FP16 Scale MAC Array (Sky130HD 130nm Cross-PDK Validation)",
            "rtl": os.path.join(SYNTH_DIR, "baseline_fp16_int8_mac_array.sv"),
            "chparam": "-chparam VEC_LEN 8 -chparam OUT_CHANNELS 4",
            "platform": "sky130hd",
            "clk_period": 12.0,
            "target_util": 0.34,
            "scale_to_full_macro": 32.0,
        },
        {
            "design": "taalas_token_pipe_noc_router",
            "full_macro_desc": "Credit-Based Wormhole Spatial Token-Pipe NoC Router (Sky130HD 130nm Cross-PDK Validation)",
            "rtl": os.path.join(RTL_DIR, "taalas_token_pipe_noc_router.sv"),
            "chparam": "-chparam FLIT_WIDTH 128 -chparam FIFO_DEPTH 8 -chparam MAX_CREDITS 8 -chparam TILE_ID 0",
            "platform": "sky130hd",
            "clk_period": 12.0,
            "target_util": 0.32,
            "scale_to_full_macro": 1.0,
        },
    ]

    import concurrent.futures
    all_configs = asap7_configs + sky130_configs
    with concurrent.futures.ProcessPoolExecutor(max_workers=6) as ex:
        all_results = list(ex.map(run_openroad_pnr_module, all_configs))
    asap7_results = [r for r in all_results if r["platform"] == "asap7"]
    sky130_results = [r for r in all_results if r["platform"] == "sky130hd"]

    taalas_asap7 = next(r for r in asap7_results if r["design"] == "taalas_3b6b_wired_mac_array")
    base_asap7 = next(r for r in asap7_results if r["design"] == "baseline_fp16_int8_mac_array")
    taalas_sky130 = next(r for r in sky130_results if r["design"] == "taalas_3b6b_wired_mac_array")
    base_sky130 = next(r for r in sky130_results if r["design"] == "baseline_fp16_int8_mac_array")

    head_to_head_comparison = {
        "asap7_7nm_finfet": {
            "taalas_routed_design_area_um2": taalas_asap7["openroad_design_area_um2"],
            "baseline_routed_design_area_um2": base_asap7["openroad_design_area_um2"],
            "routed_area_reduction_ratio": round(
                base_asap7["openroad_design_area_um2"] / max(taalas_asap7["openroad_design_area_um2"], 1.0), 3
            ),
            "routed_area_savings_pct": round(
                (1.0 - taalas_asap7["openroad_design_area_um2"] / max(base_asap7["openroad_design_area_um2"], 1.0))
                * 100.0,
                2,
            ),
            "taalas_routed_wirelength_um": taalas_asap7["detailed_route_wirelength_um"],
            "baseline_routed_wirelength_um": base_asap7["detailed_route_wirelength_um"],
            "wirelength_reduction_ratio": round(
                base_asap7["detailed_route_wirelength_um"] / max(taalas_asap7["detailed_route_wirelength_um"], 1.0), 3
            ),
            "wirelength_savings_pct": round(
                (
                    1.0
                    - taalas_asap7["detailed_route_wirelength_um"]
                    / max(base_asap7["detailed_route_wirelength_um"], 1.0)
                )
                * 100.0,
                2,
            ),
            "taalas_post_route_power_mw": taalas_asap7["power_breakdown_mw"]["total"].get("total_mw", 0.0),
            "baseline_post_route_power_mw": base_asap7["power_breakdown_mw"]["total"].get("total_mw", 0.0),
            "post_route_power_reduction_ratio": round(
                base_asap7["power_breakdown_mw"]["total"].get("total_mw", 1.0)
                / max(taalas_asap7["power_breakdown_mw"]["total"].get("total_mw", 0.001), 0.001),
                3,
            ),
            "taalas_wns_ps": taalas_asap7["wns_setup"],
            "baseline_wns_ps": base_asap7["wns_setup"],
            "taalas_fmax_mhz": taalas_asap7["post_route_fmax_mhz"],
            "baseline_fmax_mhz": base_asap7["post_route_fmax_mhz"],
            "taalas_overflow": taalas_asap7["routing_congestion_overflow"],
            "baseline_overflow": base_asap7["routing_congestion_overflow"],
            "taalas_drc_violations": taalas_asap7["final_drc_violations"],
            "baseline_drc_violations": base_asap7["final_drc_violations"],
        },
        "sky130hd_130nm": {
            "taalas_routed_design_area_um2": taalas_sky130["openroad_design_area_um2"],
            "baseline_routed_design_area_um2": base_sky130["openroad_design_area_um2"],
            "routed_area_reduction_ratio": round(
                base_sky130["openroad_design_area_um2"] / max(taalas_sky130["openroad_design_area_um2"], 1.0), 3
            ),
            "taalas_routed_wirelength_um": taalas_sky130["detailed_route_wirelength_um"],
            "baseline_routed_wirelength_um": base_sky130["detailed_route_wirelength_um"],
            "wirelength_reduction_ratio": round(
                base_sky130["detailed_route_wirelength_um"] / max(taalas_sky130["detailed_route_wirelength_um"], 1.0), 3
            ),
        },
    }

    summary = {
        "stage": "Stage 13: OpenROAD Physical Implementation (Floorplan, Placement, CTS, Detailed Routing, SPEF RCX, STA, & PDNSim IR Drop)",
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "openroad_binary": OPENROAD_BIN,
        "total_runtime_sec": round(time.time() - t0_all, 2),
        "asap7_7nm_pnr_runs": asap7_results,
        "sky130hd_130nm_pnr_runs": sky130_results,
        "taalas_vs_baseline_post_pnr_comparison": head_to_head_comparison,
    }

    out_json = os.path.join(RESULTS_DIR, "stage13_openroad_physical.json")
    with open(out_json, "w") as jf:
        json.dump(summary, jf, indent=2)
    print(f"\n[Stage 13] Saved OpenROAD physical implementation summary to {out_json}")


if __name__ == "__main__":
    main()
