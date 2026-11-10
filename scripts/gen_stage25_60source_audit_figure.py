#!/usr/bin/env python3
"""
Stage 25: Generate 3-Panel Publication Vector Figure for the 60-Source Audit & Remediation
Outputs: paper/figures/fig_stage25_60source_audit.{pdf,png,svg}
  Panel (a): 60-Source Literature & Specification Coverage Across 6 Hardware Domains & 23 RTL Modules
  Panel (b): Pre-Remediation vs. Post-Remediation Compliance Across AUDIT-FINDING-001..006
  Panel (c): End-to-End Multi-Pillar Silicon Verification Closure Pyramid (Stages 1-25)
"""

import os
import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import FancyBboxPatch

plt.rcParams.update({
    "font.family": "DejaVu Sans",
    "font.size": 8.5,
    "axes.titlesize": 9.5,
    "axes.titleweight": "bold",
    "axes.labelsize": 8.5,
    "xtick.labelsize": 7.5,
    "ytick.labelsize": 7.5,
    "legend.fontsize": 7.5,
    "pdf.fonttype": 42,
    "ps.fonttype": 42,
})

def main():
    out_dir = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "paper", "figures")
    os.makedirs(out_dir, exist_ok=True)

    fig, axes = plt.subplots(1, 3, figsize=(15.5, 4.6), gridspec_kw={"width_ratios": [1.05, 1.15, 1.05]})
    fig.subplots_adjust(left=0.05, right=0.985, top=0.86, bottom=0.16, wspace=0.28)

    # -------------------------------------------------------------------------
    # Panel (a): 60-Source Literature & Specification Coverage Breakdown
    # -------------------------------------------------------------------------
    ax0 = axes[0]
    cats = [
        "Cat 1: Taalas & AMD\nDisclosures [S01-S15]",
        "Cat 2: 2-Mask Via-ROM\n& CSD MAC [S16-S25]",
        "Cat 3: 3b/6b Outlier,\nMXFP4 & LoRA [S26-S35]",
        "Cat 4: Llama-3.1 & DeepSeek\nMLA/MoE [S36-S46]",
        "Cat 5: 6T SRAM GF(2^4),\nHsiao ECC & UCIe [S47-S55]",
        "Cat 6: Wormhole NoC, 112G\nC2C & DRO DVFS [S56-S60]"
    ]
    src_counts = [15, 10, 10, 11, 9, 5]
    mod_links  = [58, 39, 36, 39, 28, 17]
    y_pos = np.arange(len(cats))[::-1]
    h = 0.36

    b1 = ax0.barh(y_pos + h/2, src_counts, height=h, color="#1f4e78", edgecolor="#0d253f", label="Distinct Primary Sources (Total = 60)")
    b2 = ax0.barh(y_pos - h/2, mod_links,  height=h, color="#2e8b57", edgecolor="#14452f", label="Module-to-Source Trace Links (217)")

    for bar in b1:
        w = bar.get_width()
        ax0.text(w + 0.8, bar.get_y() + bar.get_height()/2, f"{int(w)} src", va="center", ha="left", fontsize=7.2, fontweight="bold", color="#1f4e78")
    for bar in b2:
        w = bar.get_width()
        ax0.text(w + 0.8, bar.get_y() + bar.get_height()/2, f"{int(w)} links", va="center", ha="left", fontsize=7.2, color="#1b5e20")

    ax0.set_yticks(y_pos)
    ax0.set_yticklabels(cats)
    ax0.set_xlim(0, 72)
    ax0.set_xlabel("Verified Count (Sources / RTL Module Trace Links)")
    ax0.set_title("(a) 60-Source Catalog Across 6 Domains & 23 RTL Modules")
    ax0.grid(axis="x", linestyle="--", alpha=0.4)
    ax0.legend(loc="lower right", framealpha=0.92)

    # -------------------------------------------------------------------------
    # Panel (b): Pre-Remediation vs. Post-Remediation Audit Compliance (001..006)
    # -------------------------------------------------------------------------
    ax1 = axes[1]
    findings = [
        "AF-001 (M01)\nBL-WL Interlock",
        "AF-002 (M03)\nE8M0=0xFF qNaN",
        "AF-003 (M05/H1)\nMBU [72..127] DED",
        "AF-004 (M08)\n64-Band 128K RoPE",
        "AF-005 (M09)\nQ8.8 log2(e)=369",
        "AF-006 (H3)\nBiased TopK MoE"
    ]
    pre_scores  = [0.0, 50.0, 0.0, 50.0, 0.0, 50.0]
    post_scores = [100.0, 100.0, 100.0, 100.0, 100.0, 100.0]
    x_pos = np.arange(len(findings))
    bw = 0.35

    r1 = ax1.bar(x_pos - bw/2, pre_scores,  width=bw, color="#d95f02", edgecolor="#7f2704", label="Pre-Stage 23 Audit Baseline (%)")
    r2 = ax1.bar(x_pos + bw/2, post_scores, width=bw, color="#1b9e77", edgecolor="#00441b", label="Post-Stage 23 Remediated (SAT Q.E.D. + UVM)")

    annotations = [
        "0->100%\nNo Crowbar",
        "INT16+RNE\nqNaN Masked",
        "56/56 MBU\n0%->100% DED",
        "32->64 Bands\nQ0.24 /8",
        "-0.5586 ->\n+1.4414 Exact",
        "s'=s+b TopK\nUnbiased Gate"
    ]
    for idx, bar in enumerate(r2):
        ax1.text(bar.get_x() + bar.get_width()/2, 102.5, annotations[idx],
                 ha="center", va="bottom", fontsize=6.6, fontweight="bold", color="#0b4f35")
    for bar in r1:
        val = bar.get_height()
        ax1.text(bar.get_x() + bar.get_width()/2, val + 1.5, f"{int(val)}%",
                 ha="center", va="bottom", fontsize=6.8, color="#8c2d04")

    ax1.set_xticks(x_pos)
    ax1.set_xticklabels(findings, rotation=18, ha="right")
    ax1.set_ylim(0, 124)
    ax1.set_ylabel("Specification & Formal Compliance (%)")
    ax1.set_title("(b) Stage 22-24 Remediation Across AUDIT-FINDING-001..006")
    ax1.grid(axis="y", linestyle="--", alpha=0.4)
    ax1.legend(loc="upper left", framealpha=0.92)

    # -------------------------------------------------------------------------
    # Panel (c): End-to-End Verification Closure Pyramid
    # -------------------------------------------------------------------------
    ax2 = axes[2]
    ax2.set_xlim(0, 10)
    ax2.set_ylim(0, 6.6)
    ax2.axis("off")
    ax2.set_title("(c) End-to-End Verification Sign-Off Pyramid (0 Errors)")

    tiers = [
        (0.3, 0.25, 9.4, 0.90, "#08306b", "Tier 1: 60M-Cycle Soak (50M + 10M Post-Fix) | 135,029,144 Txns | 0 Errors"),
        (0.7, 1.30, 8.6, 0.90, "#08519c", "Tier 2: Verilator C++17 UVM + Stage 23/24 Suite | 410,000+ Txns | 0 Errors"),
        (1.1, 2.35, 7.8, 0.90, "#2171b5", "Tier 3: Native SV IEEE 1800.2 Accellera uvm-core-2020.3.1 | 5,120 Txns | 0 Err"),
        (1.5, 3.40, 7.0, 0.90, "#2b8cbe", "Tier 4: Post-Synth Gate Equiv (21/21 Q.E.D., 145,519 Gates) & 15/15 Seq-Equiv"),
        (1.9, 4.45, 6.2, 0.90, "#4eb3d3", "Tier 5: Yosys 0.60 Formal SAT (48+ Q.E.D. incl. 6/6 Audit) & 100/100 Mutants"),
        (2.3, 5.50, 5.4, 0.90, "#238b45", "Tier 6: 60-Source Spec Audit [S01-S60] Across All 23 RTL Modules (9,939 LOC)"),
    ]
    for (x, y, w, h_box, col, txt) in tiers:
        patch = FancyBboxPatch((x, y), w, h_box, boxstyle="round,pad=0.06,rounding_size=0.12",
                               facecolor=col, edgecolor="#041836", linewidth=1.1)
        ax2.add_patch(patch)
        ax2.text(x + w/2, y + h_box/2, txt, ha="center", va="center", color="white",
                 fontsize=7.1, fontweight="bold")

    fig.suptitle("Taalas HC1/HC2 Stages 21-25: 60-Source Literature Audit, Surgical RTL Remediation & Silicon Sign-Off",
                 fontsize=11, fontweight="bold", y=0.97)

    for ext in ["pdf", "png", "svg"]:
        out_path = os.path.join(out_dir, f"fig_stage25_60source_audit.{ext}")
        fig.savefig(out_path, dpi=300)
        print(f"Saved: {out_path}")

if __name__ == "__main__":
    main()
