#!/usr/bin/env python3
import os
import sys
import json

ROOT = "/nfs/share/home/chenpei/hyr/taalas_hc1_marathon"
sys.path.insert(0, os.path.join(ROOT, "pnr"))
from run_openroad_taalas import run_openroad_pnr_module

cfg = {
    "design": "taalas_dvfs_pvt_controller",
    "rtl": os.path.join(ROOT, "rtl_v3", "taalas_dvfs_pvt_controller.sv"),
    "platform": "asap7",
    "clk_period": 1000,
    "target_util": 0.32,
    "scale_to_full_macro": 1.0,
    "full_macro_desc": "M19 All-Digital 32-Tile PVT RO Sensor, Anti-Windup PID Thermal Governor & Break-Before-Make DFS Clock-Mux Controller",
}
res = run_openroad_pnr_module(cfg)
out_json = os.path.join(ROOT, "results", "stage20_m19_pnr_summary.json")
with open(out_json, "w") as f:
    json.dump(res, f, indent=2)
print("PNR_DONE:", res["design"], "cells=", res["yosys_mapped_cells"], "area=", res["openroad_design_area_um2"], "drc=", res["final_drc_violations"], "fmax=", res["post_route_fmax_mhz"])
