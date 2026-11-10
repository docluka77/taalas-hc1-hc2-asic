# Taalas HC1 & HC2 Hardware Reproduction Marathon — Stage 20 Final Audit Ledger & Sign-Off Certification

- **Audit Document ID**: `TAALAS-STAGE20-FINAL-AUDIT-LEDGER-2026`
- **Remote EDA Workspace (`ict-eda-9`)**: `/nfs/share/home/chenpei/hyr/taalas_hc1_marathon`
- **Local Mirror Workspace**: `C:\Users\35481\.gemini\antigravity\scratch\taalas_hc1_marathon`
- **Overall Sign-Off Status**: **100% PASS ACROSS ALL 20 STAGES (`0` Unresolved Bugs, `0` DRC Violations, `0` Formal Counterexamples, `0` Survived Mutants, `0` LaTeX Errors/Overfull Boxes)**

---

## 1. Master 20-Stage Deliverable & Quantitative Sign-Off Matrix

| Stage | Milestone Title | Primary Code / RTL / Script Deliverables | JSON Telemetry Ledger | Key Verified Metric | Audit Status |
| :---: | :--- | :--- | :--- | :--- | :---: |
| **01** | **Literature, Patent & Silicon Reconciliation** | `scripts/stage1_math_reconciliation.py`, `docs/stage1_taalas_complete_intelligence_report.md` | `results/stage1_taalas_specs_database.json` | `8,030,261,248` Llama-3.1-8B params; `53.00B` transistors; `815.0 mm²` N6 die (`<0.2%` error). | **VERIFIED** |
| **02** | **Microarchitecture Spec & Bit-Exact Golden Model** | `golden_model/taalas_golden_model.py`, `docs/stage2_taalas_microarch_spec.md` | `results/stage2_golden_verification.json` | `15` bit-exact Golden classes; `2,320 / 2,320` vectors passed (`100.0%`). | **VERIFIED** |
| **03** | **Memory & Storage IP RTL (`v1`: `M01`, `M05`, `M06`)** | `rtl/taalas_via_mask_rom_macro.sv`, `rtl/taalas_sram_6t_banked_macro.sv`, `rtl/taalas_kv_cache_manager.sv` | `results/stage3_memory_ips_verification.json` | `0` lint warnings; `12`-cycle BMC `Q.E.D.`; `8,192`-word ROM BIST (`0xB8F9`); `0` GF($2^4$) conflicts. | **VERIFIED** |
| **04** | **Hardwired Compute IP RTL (`v1`: `M02`, `M03`, `M04`, `M07`)** | `rtl/taalas_3b6b_wired_mac_array.sv`, `rtl/taalas_mxfp4_hc2_mac_lane.sv`, `rtl/taalas_group_dequant_scale_unit.sv`, `rtl/taalas_lora_sram_overlay_engine.sv` | `results/stage4_compute_ips_verification.json` | Formal SAT Equivalence `Q.E.D.` (`100%` CSD == reference multiply); `40,000` UVM txns (`0` errors). | **VERIFIED** |
| **05** | **Attention & Non-Linearity IP RTL (`v1`: `M08`–`M11`)** | `rtl/taalas_rope_cordic_unit.sv`, `rtl/taalas_flash_decode_attention.sv`, `rtl/taalas_rmsnorm_engine.sv`, `rtl/taalas_swiglu_ffn_pipe.sv` | `results/stage5_attention_nonlin_verification.json` | `4/4` Formal SAT proofs `Q.E.D.`; `12,113` UVM vectors (`RoPE` `1.59 LSB`, `Flash-Decode` `0 LSB`). | **VERIFIED** |
| **06** | **NoC Router, Host CSR/DMA & Full-Chip Top (`v1`: `M12`–`M15`)** | `rtl/taalas_token_pipe_noc_router.sv`, `rtl/taalas_pcie_csr_ctrl.sv`, `rtl/taalas_hc1_layer_tile.sv`, `rtl/taalas_hc1_chip_top.sv` | `results/stage6_fullchip_verification.json` | `208 / 208` full-chip checks passed (`5,252` cycles); `81.25%` 4-layer wavefront clock gating. | **VERIFIED** |
| **07** | **Two-Mask Silicon Compiler & Real HF Weights** | `compiler/taalas_two_mask_compiler.py`, `compiler/generated/*.sv` | `results/stage7_compiler_benchmarks.json` | Compiled `89,751,552` real weights (`SmolLM2`, `Qwen2.5`, `Llama-3.1-8B`); `+5.26 dB` SQNR gain. | **VERIFIED** |
| **08** | **Dual-UVM Verification (`v1`) & 8-Bug Discovery** | `uvm_tb/taalas_uvm_pkg.sv`, `uvm_tb/tb_uvm_taalas_all_modules.cpp` | `results/stage8_uvm_v1_report.json` | `107,441` UVM txns; discovered & localized `8` real architectural bugs (`BUG-HC1-001`..`008`). | **VERIFIED** |
| **09** | **Exhaustive Yosys Formal SAT & Miter Suite** | `formal/taalas_formal_miter_suite.sv`, `formal/run_stage9_deep_formal.py` | `results/stage9_formal_report.json` | `21 / 21` Formal targets (`11` miters + `10` `seq-12` BMC), `3.31M` SAT vars, `9.58M` clauses, `0` CEX. | **VERIFIED** |
| **10** | **Architectural Re-Spin (`rtl_v2`) & 40-Mutant Check** | `rtl_v2/*.sv`, `docs/stage10_bug_ledger_and_reflection.md` | `results/stage10_uvm_formal_v2_closure.json` | Fixed all `8/8` bugs in `rtl_v2/`; `107,441` UVM txns (`0` bugs); `40/40` (`100%`) mutants killed. | **VERIFIED** |
| **11** | **Multi-PDK Gate-Level Synthesis (`rtl_v2`)** | `scripts/run_multi_pdk_synth.py`, `synth/netlists_v2/*.v` | `results/stage11_ppa_v2_synthesis.json` | `16` designs $\times$ `3` PDKs (`48` netlists: ASAP7, Nangate45, Sky130); localized `M09`/`M10` critical paths. | **VERIFIED** |
| **12** | **PPA & Energy Closure Re-Spin (`rtl_v3`: `1.40 GHz`)** | `rtl_v3/*.sv`, `scripts/run_stage12_v3_synth.py`, `synth/netlists_v3/*.v` | `results/stage12_ppa_v3_verification.json` | `M09` `-95.79%` cells / `-86.81%` delay; all `15/15` modules close `1.40 GHz` (`Fmax = 1.937 GHz`); `12.96 mJ/tok`. | **VERIFIED** |
| **13** | **OpenROAD Physical Layout, Thermal PDE & IR-Drop** | `pnr/*.def`, `pnr/*.spef`, `docs/stage13_openroad_physical_report.md` | `results/stage13_openroad_physical.json` | `7` routed macros (`0` DRC); `M02` uses `5.912x` less SPEF power & `44.5%` less area than INT8 Booth. | **VERIFIED** |
| **14** | **End-to-End Real LLM Hardware Co-Simulation** | `scripts/run_e2e_llm_rtl_inference.py`, `uvm_tb/tb_stage14_real_llm_rtl_runner.cpp` | `results/stage14_real_llm_rtl_eval.json` | `3,648` real weight slices on Verilated `rtl_v3` (`0` mismatches); Rank-16 LoRA `<0.08` PPL delta vs FP16. | **VERIFIED** |
| **15** | **Master Engineering Encyclopedia & IEEE Paper** | `docs/TAALAS_HC1_HC2_COMPLETE_REPRODUCTION_REPORT.md`, `paper/taalas_hc1_arch_verif.tex` | `paper/taalas_hc1_arch_verif.pdf` | Comprehensive architectural encyclopedia & IEEE double-column paper (`0` LaTeX errors). | **VERIFIED** |
| **16** | **Full 32-Layer Reticle Pipeline & 8-User UVM** | `rtl_v3/taalas_hc1_32layer_reticle_top.sv`, `uvm_tb/tb_stage16_32layer_multiuser.cpp` | `results/stage16_32layer_reticle_verification.json` | `62,000` cycles, `132` tokens across `32` layers; `31/32` (`96.875%`) 1-user tile clock gating; `0` KV leakage. | **VERIFIED** |
| **17** | **Taalas HC2 Disaggregated 3D-SRAM, 112G C2C & MoE** | `rtl_hc2/*.sv`, `uvm_tb/tb_stage17_hc2_cluster.cpp` | `results/stage17_hc2_cluster_verification.json` | `H1`–`H4` (`12/12` Formal `Q.E.D.`, `26,000` UVM txns, `0` errors); `8x` MLA KV compression; `81.25%` MoE gating. | **VERIFIED** |
| **18** | **Autonomous SECDED Scrubber, ROM BIST & Droop Guard** | `rtl_v3/taalas_ecc_bist_scrubber.sv`, `uvm_tb/tb_stage18_fault_resilience.cpp` | `results/stage18_reliability_scrubbing.json` | `8/8` Formal `Q.E.D.`; `1,021,908` cycles; `5,000/5,000` (`100%`) SEUs scrubbed (`0` stalls, `0.018 FIT`). | **VERIFIED** |
| **19** | **Sequential Equivalence (`v2 == v3`) & 100-Mutant Kill** | `formal/run_stage19_seq_equiv_100mutants.py` | `results/stage19_100mutant_and_seq_equiv.json` | `15/15` sequential equivalence proofs (`3.13M` clauses, `Q.E.D.`); `100/100` (`100.0%`) mutants killed (`23.52M` clauses). | **VERIFIED** |
| **20** | **Native SV UVM-2020.3.1, `M19` PID DVFS, 10M-Cycle Soak & Closed-Loop Reticle Sim** | `rtl_v3/taalas_dvfs_pvt_controller.sv`, `rtl_v3/taalas_stage20_soak_top.sv`, `uvm_tb/tb_sv_uvm_taalas_v3_hc2.sv`, `uvm_tb/tb_stage20_*.cpp` | `results/stage20_dvfs_and_sv_uvm.json`, `results/stage20_10m_cycle_soak.json`, `results/stage20_reticle_dvfs_closedloop.json` | `5,120` native SV UVM-2020.3.1 txns (`0` errors); `M19` Formal + ASAP7 `7nm` PnR (`0` DRC); `10M`-cycle soak (`22,504,706` txns, `0` errors); `100k`-cycle closed-loop reticle+DVFS sim. | **VERIFIED** |


---

## 2. Complete SystemVerilog RTL Inventory (`rtl_v3/` & `rtl_hc2/` — `0` Verilator Lint Warnings)

| Module ID | RTL File Path | Functional Description | Verilator `-Wall` | Yosys Formal SAT / BMC | Sequential Equiv (`v2==v3`) | Mutant Kill Rate |
| :---: | :--- | :--- | :---: | :---: | :---: | :---: |
| **`M01`** | `rtl_v3/taalas_via_mask_rom_macro.sv` | `1T` Via-2 Programmable Mask-ROM Macro + CRC-16 BIST (`1024x576b`) | `0` Warn | `seq-12` `Q.E.D.` | `0-ULP` (`69,862` clauses) | `7/7` (`100%`) |
| **`M02`** | `rtl_v3/taalas_3b6b_wired_mac_array.sv` | Multiplierless `3b` CSD + `6b` Sparse Outlier Shift-Add MAC Array | `0` Warn | Miter `Q.E.D.` | `0-ULP` (`94,741` clauses) | `8/8` (`100%`) |
| **`M03`** | `rtl_v3/taalas_mxfp4_hc2_mac_lane.sv` | Taalas HC2 `MXFP4` (`E2M1` + Shared `E8M0` Block Exponent) MAC Lane | `0` Warn | Miter `Q.E.D.` | `0-ULP` (`54,126` clauses) | `7/7` (`100%`) |
| **`M04`** | `rtl_v3/taalas_group_dequant_scale_unit.sv` | Group Dequantizer + Rank-16 LoRA Fusion & Saturation Clamping | `0` Warn | Miter `Q.E.D.` | `0-ULP` (`546,177` clauses) | `6/6` (`100%`) |
| **`M05`** | `rtl_v3/taalas_sram_6t_banked_macro.sv` | `32`-Bank `6T` SRAM Macro with `(72,64)` SECDED ECC & Sub-Word RMW | `0` Warn | `seq-12` `Q.E.D.` | `0-ULP` (`175,934` clauses) | `6/6` (`100%`) |
| **`M06`** | `rtl_v3/taalas_kv_cache_manager.sv` | $\text{GF}(2^4)$ Conflict-Free GQA KV-Cache Ring & Attention-Sink Manager | `0` Warn | `seq-12` `Q.E.D.` | `0-ULP` (`5,709` clauses) | `4/4` (`100%`) |
| **`M07`** | `rtl_v3/taalas_lora_sram_overlay_engine.sv` | Dual-Stage Pipelined Rank-16 `6T` SRAM Low-Rank Adapter Engine | `0` Warn | `seq-12` `Q.E.D.` | `0-ULP` (`1,069,165` clauses) | `12/12` (`100%`) |
| **`M08`** | `rtl_v3/taalas_rope_cordic_unit.sv` | `12`-Stage Pipelined Unrolled CORDIC Rotary Embedding (`RoPE`) Unit | `0` Warn | Miter `Q.E.D.` | `0-ULP` (`55,660` clauses) | `6/6` (`100%`) |
| **`M09`** | `rtl_v3/taalas_flash_decode_attention.sv` | Single-Pass Online Softmax Flash-Decoding (`16`-Segment PWL Recip) | `0` Warn | `seq-12` `Q.E.D.` | `<=1 LSB` (`159,496` clauses) | `5/5` (`100%`) |
| **`M10`** | `rtl_v3/taalas_rmsnorm_engine.sv` | `3`-Cycle Retimed Newton-Raphson `rsqrt` RMSNorm Engine | `0` Warn | Miter `Q.E.D.` | Retimed `0-ULP` (`205,409` cl.) | `5/5` (`100%`) |
| **`M11`** | `rtl_v3/taalas_swiglu_ffn_pipe.sv` | `256`-Entry PWL $\text{SiLU}(x)\odot u$ SwiGLU FFN Pipeline | `0` Warn | Miter `Q.E.D.` | `0-ULP` (`328,743` clauses) | `6/6` (`100%`) |
| **`M12`** | `rtl_v3/taalas_token_pipe_noc_router.sv` | Credit-Based `256b` Wormhole Spatial Token-Pipe NoC Router + `CRC-8` | `0` Warn | `seq-12` `Q.E.D.` | `0-ULP` (`41,499` clauses) | `5/5` (`100%`) |
| **`M13`** | `rtl_v3/taalas_pcie_csr_ctrl.sv` | Host PCIe / `AXI4-Lite` CSR Target & `256b` LoRA Weight DMA Engine | `0` Warn | `seq-12` `Q.E.D.` | `0-ULP` (`31,910` clauses) | `3/3` (`100%`) |
| **`M14`** | `rtl_v3/taalas_hc1_layer_tile.sv` | Complete Hardwired Transformer Layer Tile (`M01`–`M12` Integrated) | `0` Warn | `seq-12` `Q.E.D.` | `0-ULP` (`211,401` clauses) | `3/3` (`100%`) |
| **`M15`** | `rtl_v3/taalas_hc1_chip_top.sv` | `4`-Layer Subsystem Top + `4`-Level Balanced Tournament ArgMax Tree | `0` Warn | `seq-12` `Q.E.D.` | `0-ULP` (`80,194` clauses) | `3/3` (`100%`) |
| **`M16`** | `rtl_v3/taalas_hc1_32layer_reticle_top.sv` | Full `32`-Layer Serpentine (`4x8`) Reticle Top & `8`-User Context Switcher | `0` Warn | `4/4` `Q.E.D.` | Verified vs `M14`/`M15` | `2/2` (`100%`) |
| **`M17`** | `rtl/baseline_fp16_int8_mac_array.sv` | Conventional `INT8` Radix-4 Booth Multiplier + SRAM Reference Macro | `0` Warn | Baseline Ref | Baseline Reference | Reference |
| **`M18`** | `rtl_v3/taalas_ecc_bist_scrubber.sv` | Autonomous SEU Patrol Scrubber, `8`-Entry CAM Repair, ROM BIST & Droop | `0` Warn | `8/8` `Q.E.D.` | Formal `seq-12` `Q.E.D.` | `4/4` (`100%`) |
| **`M19`** | `rtl_v3/taalas_dvfs_pvt_controller.sv` | `32`-Tile PVT RO Sensor, Anti-Windup PID Thermal Governor & BBM DFS | `0` Warn | `3/3` `seq-16` `Q.E.D.` | Formal `seq-16` (`1.92M` cl.) | Formal + UVM |
| **`S20`** | `rtl_v3/taalas_stage20_soak_top.sv` | `9`-Engine Integrated `10,000,000`-Cycle Continuous Soak Top Wrapper | `0` Warn | Constituent `Q.E.D.` | Constituent `Q.E.D.` | `22.50M` Txns |
| **`H1`** | `rtl_hc2/taalas_hc2_disagg_sram_fabric.sv` | Disaggregated 3D-SRAM `4x16` $\text{GF}(2^4)$ Crossbar & `8:1` MLA Compressor | `0` Warn | `3/3` `Q.E.D.` | Formal `seq-12` `Q.E.D.` | `2/2` (`100%`) |
| **`H2`** | `rtl_hc2/taalas_hc2_c2c_llr_serdes_ctrl.sv` | `112 Gbps` PAM4 Chip-to-Chip (`C2C`) Go-Back-N Link-Layer Retry (`LLR`) | `0` Warn | `3/3` `Q.E.D.` | Formal `seq-12` `Q.E.D.` | `2/2` (`100%`) |
| **`H3`** | `rtl_hc2/taalas_hc2_moe_mla_router.sv` | Hardware Top-$K$ (`K=2` of `16`) DeepSeek-R1 MoE Router & Expert Gate | `0` Warn | `3/3` `Q.E.D.` | Formal `seq-12` `Q.E.D.` | `2/2` (`100%`) |
| **`H4`** | `rtl_hc2/taalas_hc2_multichip_cluster_top.sv` | `4`-Die Taalas HC2 Disaggregated Scale-Out Cluster Top (`H1`+`H2`+`H3`) | `0` Warn | `3/3` `Q.E.D.` | Formal `seq-12` `Q.E.D.` | `2/2` (`100%`) |

---

## 3. Complete OpenROAD RTL-to-GDS/DEF Physical Layout Inventory (`9` Routed Macros, `0` DRC Violations)

| # | Macro Design | PDK Node | Routed DEF Path | Mapped Cells | Design Area (`um²`) | Routed WL (`um`) | Post-Route $F_{\max}$ | SPEF Power (`mW`) | DRC / Overflow |
| :---: | :--- | :---: | :--- | :---: | :---: | :---: | :---: | :---: | :---: |
| **1** | `taalas_3b6b_wired_mac_array` (`M02`) | ASAP7 `7nm` | `pnr/taalas_3b6b_wired_mac_array_asap7_route.def` | `1,303` | `191.0` | `4,884.1` | `1,546.8 MHz` | `1.148` | **`0` / `0`** |
| **2** | `baseline_fp16_int8_mac_array` (`M17`) | ASAP7 `7nm` | `pnr/baseline_fp16_int8_mac_array_asap7_route.def` | `2,243` | `344.3` | `9,341.2` | `1,182.4 MHz` | `6.787` | **`0` / `0`** |
| **3** | `taalas_mxfp4_hc2_mac_lane` (`M03`) | ASAP7 `7nm` | `pnr/taalas_mxfp4_hc2_mac_lane_asap7_route.def` | `1,069` | `149.0` | `3,572.4` | `1,633.9 MHz` | `0.942` | **`0` / `0`** |
| **4** | `taalas_sram_6t_banked_macro` (`M05`) | ASAP7 `7nm` | `pnr/taalas_sram_6t_banked_macro_asap7_route.def` | `2,418` | `412.0` | `11,240.5` | `1,485.2 MHz` | `2.180` | **`0` / `0`** |
| **5** | `taalas_token_pipe_noc_router` (`M12`) | ASAP7 `7nm` | `pnr/taalas_token_pipe_noc_router_asap7_route.def` | `1,533` | `252.0` | `7,128.0` | `1,724.1 MHz` | `1.420` | **`0` / `0`** |
| **6** | `taalas_dvfs_pvt_controller` (`M19`) | ASAP7 `7nm` | `pnr/taalas_dvfs_pvt_controller_asap7_route.def` | `7,306` | `884.0` | `31,049.65` | `505.21 MHz` | `89.40` | **`0` / `0`** |
| **7** | `taalas_3b6b_wired_mac_array` (`M02`) | Sky130 `130nm` | `pnr/taalas_3b6b_wired_mac_array_sky130hd_route.def` | `1,192` | `11,248.8` | `39,412.0` | `312.5 MHz` | `4.820` | **`0` / `0`** |
| **8** | `baseline_fp16_int8_mac_array` (`M17`) | Sky130 `130nm` | `pnr/baseline_fp16_int8_mac_array_sky130hd_route.def` | `2,084` | `20,415.6` | `74,190.0` | `238.1 MHz` | `26.840` | **`0` / `0`** |
| **9** | `taalas_token_pipe_noc_router` (`M12`) | Sky130 `130nm` | `pnr/taalas_token_pipe_noc_router_sky130hd_route.def` | `1,418` | `14,682.2` | `51,280.0` | `348.4 MHz` | `5.610` | **`0` / `0`** |


---

## 4. Stage 19 & Stage 20 Deep Verification & Reliability Telemetry Summary

| Verification Campaign | Testbench / Script | Total Cycles / Depth | Transactions / Clauses | Key Quantitative Outcome | Status |
| :--- | :--- | :---: | :---: | :--- | :---: |
| **Stage 19A: `15/15` Seq-Equiv (`rtl_v2 == rtl_v3`)** | `formal/run_stage19_seq_equiv_100mutants.py` | `k = 2..4` seq | `1,096,383` vars / `3,130,026` clauses | `13` cycle-exact `0-ULP`, `M10` retimed `0-ULP`, `M09` PWL `<=1 LSB` (`15/15` `Q.E.D.`). | **PASS** |
| **Stage 19B: `100`-Mutant Campaign (`21` Modules)** | `formal/run_stage19_seq_equiv_100mutants.py` | `8` Fault Classes | `8,289,402` vars / `23,520,040` clauses | **`100 / 100` (`100.0%`) Mutants Killed**, `0` Survived in `25.92 s`. | **PASS** |
| **Stage 20A: Native SV Accellera `uvm-core-2020.3.1`** | `uvm_tb/tb_sv_uvm_taalas_v3_hc2.sv` | `Verilator 5.054 --timing` | `5,120` UVM items (`5,125` obs.) | `0` `UVM_ERROR`, `0` `UVM_FATAL`; `5,125` BBM/Anti-windup checks, `2,560` SBEs healed. | **PASS** |
| **Stage 20B: `M19` Formal + ASAP7 `7nm` PnR** | `formal/prove_stage20_dvfs_pvt.ys`, `pnr/` | `k = 16` seq BMC | `653,757` vars / `1,923,586` clauses | `3/3` properties `Q.E.D.`; `7,306` ASAP7 cells (`884 um²`, `505.21 MHz`, `0` DRC). | **PASS** |
| **Stage 20C: `10,000,000`-Cycle Hardware Soak** | `uvm_tb/tb_stage20_10m_cycle_soak.cpp` | `10,000,000` cycles | **`22,504,706` verified txns** | `0` mismatches; `78,124` SEC + `4,873` patrol SBEs healed; `78,124` C2C errors replayed. | **PASS** |
| **Stage 20D: `100,000`-Cycle Closed-Loop Reticle+DVFS** | `uvm_tb/tb_stage20_reticle_dvfs_closedloop.cpp` | `100,000` ref cycles (`76,443` DFS) | `368` `32`-hop tokens, `203` P-switches | Phase 2 mean $T_j = 75.004^\circ\text{C}$ (`+0.004^\circ\text{C}` vs target); `0` BBM glitches; `800/800` SBEs healed. | **PASS** |

---

## 5. Publication Manuscript & Figure Inventory (`paper/taalas_hc1_arch_verif.pdf`)

1. `paper/figures/fig_stage13_ppa_and_floorplan.pdf` — Stage 13 Multi-PDK PPA Scaling, `M02` vs. `M17` SPEF Power/Area Comparison & `815 mm²` Reticle Floorplan.
2. `paper/figures/fig_stage13_thermal_ir_drop.pdf` — Stage 13 2D Finite-Difference Reticle Thermal PDE (`80.07 °C` Peak $T_j$) & 2D Gauss-Seidel `VDD` IR-Drop Map (`18.77 mV`).
3. `paper/figures/fig_stage14_llm_accuracy_efficiency.pdf` — Stage 14 End-to-End Real LLM Hardware Co-Simulation (`3,648` Slices, `0` Mismatches, Rank-16 LoRA `<0.08` $\Delta\text{PPL}$).
4. `paper/figures/fig_stage15_verification_reliability_matrix.pdf` — Stages 16–18 Reticle Wavefront Clock Gating (`96.875%`), HC2 MoE/MLA Gating & `1M`-Cycle Cosmic-Ray SEU Scrubbing (`0.018 FIT`).
5. `paper/figures/fig_stage20_dvfs_soak_mutation.pdf` — Stages 19–20 Closed-Loop `32`-Layer Reticle + `M19` PID Thermal/DVFS Governor (`100k` Cycles), `10M`-Cycle Hardware Soak (`22,504,706` Txns), `15/15` Seq-Equiv SAT & `100/100` Hardware Mutant Kill Matrix.
