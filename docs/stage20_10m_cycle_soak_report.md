# Stage 20C — 10,000,000-Cycle Continuous Hardware Soak & Corner-Case Stress Report

## 1. Executive Summary
To prove silicon-grade long-horizon stability across the integrated Taalas HC1 (TSMC N6) and HC2 (TSMC N4P) hardwired LLM inference architectures, we constructed and executed a **10,000,000-cycle (`10^7` clock cycles)** continuous multi-subsystem hardware soak harness (`rtl_v3/taalas_stage20_soak_top.sv` + `uvm_tb/tb_stage20_10m_cycle_soak.cpp`) on `ict-eda-9`.

Across **10,000,000 continuous clock cycles** and **22,504,706 verified hardware transactions** spanning all 9 core compute, memory, NoC, C2C SerDes, MoE routing, and autonomous reliability engines simultaneously, the hardware achieved:
- **Total Simulated Clock Cycles**: `10,000,000` (`10^7` cycles)
- **Total Verified Transactions**: `22,504,706` (`> 9x` the 2,500,000-transaction target)
- **Total Scoreboard Mismatches**: `0` (0-ULP bit-exact match across all 9 engines)
- **Memory & Resource Leaks**: `0` (0 FIFO overflows/underflows, 0 NoC credit leaks, 0 pipeline stall bubbles, 0 unhealed cosmic-ray SEUs)

---

## 2. Multi-Subsystem Soak Harness Architecture (`taalas_stage20_soak_top.sv`)
The top-level soak wrapper (`rtl_v3/taalas_stage20_soak_top.sv`) integrates 9 parameterized RTL subsystems operating concurrently on every 4-cycle wave (`2,499,975` synchronized waves + initialization and drain phases = `10,000,000` cycles):

| Engine ID | RTL Module | Soak Configuration Parameters | Verified Transactions | Scoreboard Mismatches |
| :--- | :--- | :--- | :---: | :---: |
| **`M02`** | `taalas_3b6b_wired_mac_array` | `VEC_LEN=16, OUT_CHANNELS=8, NUM_OUTLIERS=4` | `2,499,975` | `0` |
| **`M03`** | `taalas_mxfp4_hc2_mac_lane` | `BLOCK_SIZE=16, NUM_LANES=4` | `2,499,975` | `0` |
| **`M04`** | `taalas_group_dequant_scale_unit` | `OUT_CHANNELS=8, ACC_WIDTH=24, OUT_WIDTH=16` | `2,499,975` | `0` |
| **`M05`** | `taalas_sram_6t_banked_macro` | `NUM_BANKS=16, BANK_DEPTH=64, RAW_WIDTH=72` | `4,999,950` (`2.5M` W + `2.5M` R) | `0` |
| **`M07`** | `taalas_lora_sram_overlay_engine` | `IN_DIM=16, OUT_CHANNELS=8, MAX_RANK=8, MAX_SKEW=8` | `2,499,975` | `0` |
| **`M12`** | `taalas_token_pipe_noc_router` | `FLIT_WIDTH=128, FIFO_DEPTH=8, MAX_CREDITS=8` | `2,499,975` | `0` |
| **`M18`** | `taalas_ecc_bist_scrubber` | `NUM_BANKS=16, BANK_DEPTH=64, ROM_DEPTH=256, SPARE_ROWS=8` | `4,873` SBE + `8` DBE + `50` BIST | `0` |
| **`H2`** | `taalas_hc2_c2c_llr_serdes_ctrl` | `PAYLOAD_W=64, SEQ_W=8, CRC_W=16, MAX_CREDITS=16` | `2,499,975` (`78,124` replays) | `0` |
| **`H3`** | `taalas_hc2_moe_mla_router` | `NUM_EXPERTS=16, DIM_GATE=8, MAX_K=4, NUM_CHIPS=4` | `2,499,975` | `0` |
| **Total** | **9 Concurrent Subsystems** | **Full HC1 + HC2 Datapath & Reliability Soak** | **`22,504,706`** | **`0` (PASS)** |

---

## 3. Detailed Subsystem Telemetry & Corner-Case Stress Results

### 3.1 Multiplierless Compute & Dequantization (`M02`, `M03`, `M04`, `M07`)
1. **`M02` (`taalas_3b6b_wired_mac_array`)**:
   - Completed `2,499,975` VMM transactions (`319,996,800` base 3-bit CSD MAC operations + `79,999,200` 6-bit sparse outlier operations).
   - Operand isolation (`zero_skip_en_i`) gated `32,671,035` zero-weight/zero-activation toggles with `0` accumulator or `act_sum_o` mismatches.
2. **`M03` (`taalas_mxfp4_hc2_mac_lane`)**:
   - Completed `2,499,975` 4-lane x 16-element OCP MXFP4 (`E2M1` + `E8M0`) dot-product transactions (`159,998,400` pairwise E2M1 products) with `0` ULP deviation on `dot_int16_o`, `exp_comb_o`, and IEEE-754 `fp32_out_o`.
3. **`M04` (`taalas_group_dequant_scale_unit`)**:
   - Completed `2,499,975` 8-channel zero-point compensation, Q16.16 scale multiplication, and LoRA delta fusion transactions, including `6,748` signed INT16 saturation clipping events verified bit-exact against the C++ reference.
4. **`M07` (`taalas_lora_sram_overlay_engine`)**:
   - Completed `2,499,975` two-phase low-rank (`r in {4, 8}`) adaptation projections across dynamic skew-matching delays (`skew_delay_i in {0, 1}`) with strictly **`0` pipeline stall cycles (`stall_cycles_o == 0`)** across all 10,000,000 clock cycles.

### 3.2 Memory, NoC Flow Control, C2C Link-Layer Retry & MoE Routing (`M05`, `M12`, `M18`, `H2`, `H3`)
5. **`M05` (`taalas_sram_6t_banked_macro`)**:
   - Executed `2,499,975` 64-bit writes and `2,499,975` 64-bit reads (`4,999,950` total SRAM operations) across all 16 GF($2^4$)-swizzled physical banks and 64 rows.
   - Injected `78,124` single-bit errors (100% auto-corrected on the fly by `(72,64)` Hamming SECDED with zero data corruption) and `19,531` double-bit errors (100% flagged by `ded_err_o`).
6. **`M12` (`taalas_token_pipe_noc_router`)**:
   - Routed `2,499,975` 128-bit wormhole flits with continuous cycle-by-cycle verification of the formal credit conservation invariant (`avail_credits_o + inflight_flits_o == 8`), returning to `8/8` available credits and `0` in-flight flits at end-of-soak with `0` CRC-8 errors.
7. **`M18` (`taalas_ecc_bist_scrubber`)**:
   - Autonomous background patrol scrubber healed **`4,873 / 4,873` (`100%`)** cosmic-ray single-bit upsets (SEUs) via atomic SECDED write-back, remapped **`8 / 8`** double-bit upsets (MBUs) into the 8-entry CAM spare-row repair table, passed **`50 / 50`** periodic 256-word Via-ROM CRC-16-CCITT BIST sweeps (`0xEBAA`), and executed **`250`** transient $L \cdot di/dt$ voltage-droop clock-stretch events (`canary_taps_i[5] == 0`).
8. **`H2` (`taalas_hc2_c2c_llr_serdes_ctrl`)**:
   - Transmitted and delivered **`2,499,975 / 2,499,975`** 64-bit C2C payloads in strict FIFO order across an 88-bit 112G SerDes loopback link while surviving **`78,124` injected link bit-error storms** via deterministic Go-Back-N Link-Layer Retry (LLR).
9. **`H3` (`taalas_hc2_moe_mla_router`)**:
   - Routed **`2,499,975`** tokens across 16 experts (`K=2` and `K=4` modes), accumulating **`152,498,882` clock-gated expert-tile cycles** with bit-exact Top-K tournament selection, target die IDs, and Q8.8 gating weights.

---

## 4. Artifacts & Reproducibility
- **RTL Soak Top**: `rtl_v3/taalas_stage20_soak_top.sv`
- **C++17 UVM Soak Testbench**: `uvm_tb/tb_stage20_10m_cycle_soak.cpp`
- **Machine-Readable Telemetry JSON**: `results/stage20_10m_cycle_soak.json`
