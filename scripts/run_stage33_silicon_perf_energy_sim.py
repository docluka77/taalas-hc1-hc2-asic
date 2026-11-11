#!/usr/bin/env python3
"""
Stage 33 Driver: Compile and Execute Verilator 5.054 Cycle-Accurate Silicon
Performance & Energy Benchmark (Workloads A, B, and C across HC1 & HC2 RTL).
"""
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def main():
    verilator_bin = os.environ.get("VERILATOR_BIN", shutil.which("verilator") or "verilator")
    rtl_v3_files = sorted(str(p) for p in (ROOT / "rtl_v3").glob("*.sv"))
    rtl_hc2_files = sorted(str(p) for p in (ROOT / "rtl_hc2").glob("*.sv"))
    wrapper_sv = str(ROOT / "uvm_tb" / "tb_stage33_silicon_perf_wrapper.sv")
    cpp_tb = str(ROOT / "uvm_tb" / "tb_stage33_silicon_perf_energy_sim.cpp")
    obj_dir = str(ROOT / "uvm_tb" / "obj_dir_stage33_perf")

    cmd = [
        verilator_bin,
        "--cc",
        "--exe",
        "--build",
        "-j",
        "32",
        "-Wno-fatal",
        "--top-module",
        "tb_stage33_silicon_perf_wrapper",
        "--Mdir",
        obj_dir,
        *rtl_v3_files,
        *rtl_hc2_files,
        wrapper_sv,
        cpp_tb,
    ]
    print("[STAGE-33] Compiling Verilator 5.054 Silicon Performance & Energy Simulator...")
    subprocess.run(cmd, cwd=str(ROOT), check=True)

    sim_bin = Path(obj_dir) / "Vtb_stage33_silicon_perf_wrapper"
    print("[STAGE-33] Executing Cycle-Accurate Hardware Simulation (Workloads A, B, C)...")
    subprocess.run([str(sim_bin)], cwd=str(ROOT), check=True)

    res_path = ROOT / "results" / "stage33_silicon_perf_energy_simulation.json"
    data = json.loads(res_path.read_text(encoding="utf-8"))
    assert data["status"] == "PASS", "Stage 33 simulation status is not PASS!"
    print(f"[STAGE-33] PASS -> {res_path}")


if __name__ == "__main__":
    main()
