# Stage 27: Second-Wave Line-by-Line Audit of All 23 RTL Modules & Golden Reference Model (120 Sources `[S01]`–`[S120]`)
## 1. Executive Summary
- **Total Literature & Standards Cross-Checked**: `120` verifiable sources (`[S01]`–`[S60]` Wave 1 + `[S61]`–`[S120]` Wave 2).
- **Wave 1 Findings (`AUDIT-FINDING-001`..`006`)**: `6` findings in `M01`, `M03`, `M05`/`H1`/`M18`, `M08`/`M14`, `M09`, and `H3` (`100% REMEDIATED & PROVEN Q.E.D.` in Stage 23–24).
- **Wave 2 Findings (`AUDIT-FINDING-007`..`014`)**: `8` deep corner-case, protocol-handshake, and Reference-Model findings across `M02`, `M04`, `M06`, `M10`, `M11`, `M12`, `M13`, `H2`, and `golden_model/taalas_golden_model.py`.

## 2. Complete 23-Module Audit Matrix (`M01`–`M19`, `H1`–`H4`)
| Module | RTL File | Primary Sources | Audit Findings | Status |
|---|---|---|---|---|
| `M01` | `rtl_v3/taalas_rom_metal_tile.sv` | `[S01],[S05],[S15],[S68],[S119]` | `AUDIT-FINDING-001 (Wave 1)` | **VERIFIED_EXACT** |
| `M02` | `rtl_v3/taalas_3b6b_wired_mac_array.sv` | `[S26],[S61],[S63],[S65],[S68]` | `AUDIT-FINDING-007 (Wave 2)` | **REMEDIATED_STAGE28** |
| `M03` | `rtl_v3/taalas_sparse_outlier_cam_6b.sv` | `[S24],[S25],[S77]-[S80]` | `AUDIT-FINDING-002 (Wave 1)` | **VERIFIED_EXACT** |
| `M04` | `rtl_v3/taalas_group_dequant_scale_unit.sv` | `[S22],[S23],[S71],[S75],[S76]` | `AUDIT-FINDING-008 (Wave 2)` | **REMEDIATED_STAGE28** |
| `M05` | `rtl_v3/taalas_sram_6t_bank_macro.sv` | `[S32],[S33],[S93]-[S98]` | `AUDIT-FINDING-003 (Wave 1)` | **VERIFIED_EXACT** |
| `M06` | `rtl_v3/taalas_kv_cache_manager.sv` | `[S43],[S81]-[S86]` | `AUDIT-FINDING-009 (Wave 2)` | **REMEDIATED_STAGE28** |
| `M07` | `rtl_v3/taalas_lora_sram_Rank16_adapter.sv` | `[S35],[S119],[S120]` | `Clean (0 discrepancies)` | **VERIFIED_EXACT** |
| `M08` | `rtl_v3/taalas_rope_rotary_embedding.sv` | `[S37],[S38],[S40],[S104],[S105]` | `AUDIT-FINDING-004 (Wave 1)` | **VERIFIED_EXACT** |
| `M09` | `rtl_v3/taalas_gqa_flash_attention_unit.sv` | `[S41],[S42],[S44],[S106]-[S108]` | `AUDIT-FINDING-005 (Wave 1)` | **VERIFIED_EXACT** |
| `M10` | `rtl_v3/taalas_rmsnorm_engine.sv` | `[S46],[S99],[S100],[S71]` | `AUDIT-FINDING-010 (Wave 2)` | **REMEDIATED_STAGE28** |
| `M11` | `rtl_v3/taalas_swiglu_ffn_pipe.sv` | `[S47],[S101]-[S103],[S71]` | `AUDIT-FINDING-011 (Wave 2)` | **REMEDIATED_STAGE28** |
| `M12` | `rtl_v3/taalas_token_pipe_noc_router.sv` | `[S51],[S52],[S87],[S88]` | `AUDIT-FINDING-013 (Wave 2)` | **REMEDIATED_STAGE28** |
| `M13` | `rtl_v3/taalas_pcie_csr_ctrl.sv` | `[S91],[S92],[S113],[S114]` | `AUDIT-FINDING-012 (Wave 2)` | **REMEDIATED_STAGE28** |
| `M14` | `rtl_v3/taalas_llama3_8b_decoder_layer.sv` | `[S37],[S38],[S118],[S119]` | `AUDIT-FINDING-004/009` | **REMEDIATED_STAGE28** |
| `M15` | `rtl_v3/taalas_hc1_chip_top.sv` | `[S01]-[S14],[S113]-[S118]` | `Clean (Integrates M13/M14)` | **REMEDIATED_STAGE28** |
| `M16` | `rtl_v3/taalas_hc1_32layer_reticle_top.sv` | `[S01],[S02],[S51],[S117],[S118]` | `Clean (32-Layer Reticle)` | **VERIFIED_EXACT** |
| `M17` | `rtl_v3/taalas_rom_custom_cell_lib.sv` | `[S15],[S16],[S65],[S68]` | `Clean (Physical Cell Library)` | **VERIFIED_EXACT** |
| `M18` | `rtl_v3/taalas_sram_bist_ecc_repair_ctrl.sv` | `[S32],[S33],[S93]-[S96]` | `AUDIT-FINDING-003 (Wave 1)` | **VERIFIED_EXACT** |
| `M19` | `rtl_v3/taalas_pvt_thermal_dvfs_ctrl.sv` | `[S53]-[S55],[S109]-[S112]` | `Clean (PI Thermal Loop + BBM)` | **VERIFIED_EXACT** |
| `H1` | `rtl_hc2/taalas_hc2_3d_sram_knoll_ctrl.sv` | `[S34],[S93],[S97],[S98]` | `AUDIT-FINDING-003 (Wave 1)` | **VERIFIED_EXACT** |
| `H2` | `rtl_hc2/taalas_hc2_c2c_llr_serdes_ctrl.sv` | `[S56],[S57],[S89],[S90]` | `AUDIT-FINDING-013 (Wave 2)` | **REMEDIATED_STAGE28** |
| `H3` | `rtl_hc2/taalas_hc2_mxfp4_custom_mac_tile.sv` | `[S28]-[S30],[S70]-[S74]` | `AUDIT-FINDING-006 (Wave 1)` | **VERIFIED_EXACT** |
| `H4` | `rtl_hc2/taalas_hc2_moe_top_k_router.sv` | `[S48]-[S50],[S85],[S86]` | `Clean (Top-K MoE + MLA)` | **VERIFIED_EXACT** |

## 3. Detailed Second-Wave Audit Findings (`AUDIT-FINDING-007` .. `AUDIT-FINDING-014`)

### AUDIT-FINDING-007: M02 17-bit Outlier Accumulator Corner-Case Overflow (16 x +4096 = +65536) & Zero-Skip Telemetry Omission of 6-bit Outliers + RefModel Sign-Magnitude Mismatch
- **Modules**: `M02, GOLDEN_REF_M02` (`rtl_v3/taalas_3b6b_wired_mac_array.sv, golden_model/taalas_golden_model.py` Lines `109-113, 163-176, 215-260`)
- **Literature / Standard Sources**: `[S61], [S63], [S65], [S68], [S26]`
- **Severity**: `MEDIUM-HIGH (Corner-Case Overflow & Telemetry Undercount)`
- **Root Cause Analysis**: 1) In M02 (rtl_v3/taalas_3b6b_wired_mac_array.sv L216), out_sum_comb is declared as logic signed [16:0] (range [-65536, +65535]). When NUM_OUTLIERS=16 and all 16 outlier weights are w_6b=-32 (6'b100000) with x_in=-128 (8'h80), each product is (-32)*(-128) = +4096, and their sum is 16 * 4096 = +65536, which overflows 17-bit signed out_sum_comb to -65536! Widening out_sum_comb to 20-bit signed (logic signed [19:0]) completely eliminates overflow. 2) L163-176 increments ch_zero_skip[ch] only for 3-bit base CSD zero-skips, omitting gated 6-bit outlier zero-skips even though outlier6_shift_add gates x_iso=0 when zskip_en && (w_6b==0 || x_in==0). 3) In golden_model/taalas_golden_model.py (M2), decode_6b_outlier decoded 6-bit weights as sign-magnitude instead of 2's complement [-32..+31].
- **Hardware & Reference Model Remediation**: Widen out_sum_comb in M02 to logic signed [19:0], add outlier zero-skip telemetry accumulation (gated by zskip_outlier_cnt_en_i or accumulated cleanly), and fix M2 in golden_model/taalas_golden_model.py to use exact 6-bit 2's complement and 3-bit CSD hardware equations.

### AUDIT-FINDING-008: M04 Premature 24-bit Clamping of Zero-Point Difference Before Fractional Scale & Optional IEEE-754 RNE Rounding
- **Modules**: `M04, GOLDEN_REF_M04` (`rtl_v3/taalas_group_dequant_scale_unit.sv, golden_model/taalas_golden_model.py` Lines `102-105, 150-195`)
- **Literature / Standard Sources**: `[S71], [S75], [S76], [S22], [S23]`
- **Severity**: `MEDIUM (Premature Intermediate Clamp & Asymmetric Half-Way Rounding Bias)`
- **Root Cause Analysis**: In M04 (rtl_v3/taalas_group_dequant_scale_unit.sv L104), zp_diff = 28'(raw_acc_elem[j]) - 28'(zp_prod) is clamped to 24 bits (clamp_int24) BEFORE multiplying by the fractional Q16.16 scale factor, and L177 uses round-half-up ((prod_s56 + 32768) >>> 16) rather than unbiased IEEE-754 Round-to-Nearest-Even (RNE).
- **Hardware & Reference Model Remediation**: Add rne_round_en_i (default 1'b0 for legacy bit-equivalence, 1'b1 for strict IEEE-754 RNE unbiased tie-breaking per [S71]) and wide_zp_en_i support in M04, plus bit-exact M04 modeling in golden_model.

### AUDIT-FINDING-009: M06 Cross-Head KV Address Collision When MAX_SEQ_LEN > 16 & Golden Model StreamingLLM Attention Sink Overwrite
- **Modules**: `M06, GOLDEN_REF_M06` (`rtl_v3/taalas_kv_cache_manager.sv, golden_model/taalas_golden_model.py` Lines `101-102, 179-190, 202-210`)
- **Literature / Standard Sources**: `[S43], [S81], [S82], [S84]`
- **Severity**: `HIGH (Multi-Head XOR Address Aliasing When MAX_SEQ_LEN > 16 & RefModel Sink Wrap Bug)`
- **Root Cause Analysis**: 1) In M06 (rtl_v3/taalas_kv_cache_manager.sv L101), HEAD_BANKS was set to (MAX_SEQ_LEN <= 16) ? NUM_KV_HEADS : 1. When MAX_SEQ_LEN > 16 (such as MAX_SEQ_LEN=32 in M14), HEAD_BANKS became 1 and L207 computed wr_mem_idx = {act_slot_q, cur_slot_wr_ptr ^ PTR_W'(act_head_q)}. Because pos ^ head aliases across positions and heads (e.g. pos=1, head=0 collides with pos=0, head=1), multi-head KV writes corrupt each other! 2) In golden_model/taalas_golden_model.py (M6), wr_ptr wrapped via (wr_ptr + 1) % max_seq_len to 0, overwriting StreamingLLM Attention Sink tokens [0..sink_tokens-1] instead of wrapping to sink_tokens.
- **Hardware & Reference Model Remediation**: Set HEAD_BANKS = NUM_KV_HEADS unconditionally in M06 so every KV head has its own conflict-free storage slice {act_slot_q, act_head_q, cur_slot_wr_ptr}, track per-slot/per-head pointers cleanly, and update Golden Model M6 to preserve StreamingLLM sink tokens [0..sink_tokens-1] on ring wrap.

### AUDIT-FINDING-010: M10 Unclamped 16-bit Truncation of x_norm_q8 Causes Sign-Inversion on Extreme Crest-Factor Activation Outliers
- **Modules**: `M10, GOLDEN_REF_M10` (`rtl_v3/taalas_rmsnorm_engine.sv, golden_model/taalas_golden_model.py` Lines `272-275`)
- **Literature / Standard Sources**: `[S46], [S99], [S100], [S71]`
- **Severity**: `HIGH (Intermediate 16-bit Sign-Wrap Before Gamma Scaling on High-Crest-Factor Outliers)`
- **Root Cause Analysis**: In M10 (rtl_v3/taalas_rmsnorm_engine.sv L273), x_norm_q8 is truncated to 16-bit signed via x_norm_q8 = 16'((x_norm_q16 + 32'sd128) >>> 8) without saturation clamping before multiplying by gam_i. When DIM=16 and one element has a large activation while others are near zero (or when inv_rms_q8_8_q is large), (x_rep * inv_rms_q8_8_q + 128) >>> 8 can exceed +32767 (up to +131072), wrapping 16-bit signed x_norm_q8 to a negative number before multiplying by a small fractional gamma!
- **Hardware & Reference Model Remediation**: Widen x_norm_q8 in M10 from logic signed [15:0] to logic signed [23:0] (and y_prod_q16 to logic signed [39:0]) so intermediate normalized values never sign-wrap before final clamp_int16 saturation.

### AUDIT-FINDING-011: M11 SwiGLU Hadamard & Re-Quantization IEEE-754 RNE Tie-Breaking Support & Complete Integer Pipeline RefModel
- **Modules**: `M11, GOLDEN_REF_M11` (`rtl_v3/taalas_swiglu_ffn_pipe.sv, golden_model/taalas_golden_model.py` Lines `213, 223`)
- **Literature / Standard Sources**: `[S47], [S71], [S101], [S102]`
- **Severity**: `MEDIUM (RNE Tie-Breaking Option & Full 4-Stage Cycle-Accurate Integer RefModel)`
- **Root Cause Analysis**: M11 (rtl_v3/taalas_swiglu_ffn_pipe.sv L213, L223) used only round-half-up (+128 >>> 8), and golden_model/taalas_golden_model.py modeled M11 using floating-point math without modeling the 16-segment Q8.8 PWL SiLU LUT, Hadamard Q16.16 clamp, INT8 re-quantization, and 3-bit CSD W_down MAC tree.
- **Hardware & Reference Model Remediation**: Add rne_en_i option to M11 for unbiased IEEE-754 RNE rounding and implement the complete cycle-accurate integer 4-stage M11 pipeline in golden_model/taalas_golden_model.py and golden_model/taalas_golden_ref_lib.hpp.

### AUDIT-FINDING-012: M13 AXI4-Lite Slave Requires Simultaneous AWVALID & WVALID, Deadlocking Decoupled AXI4-Lite Masters per ARM IHI 0022E
- **Modules**: `M13, GOLDEN_REF_M13` (`rtl_v3/taalas_pcie_csr_ctrl.sv, golden_model/taalas_golden_model.py` Lines `195-198, 228-235`)
- **Literature / Standard Sources**: `[S91], [S113], [S114]`
- **Severity**: `HIGH (ARM AMBA AXI4-Lite Protocol Deadlock on Decoupled AWVALID / WVALID Masters)`
- **Root Cause Analysis**: In M13 (rtl_v3/taalas_pcie_csr_ctrl.sv L195-197), s_axi_awready = !bvalid_q && s_axi_wvalid and s_axi_wready = !bvalid_q && s_axi_awvalid. Per ARM AMBA AXI4-Lite Specification (ARM IHI 0022E Section A3.3.1 [S91]), an AXI4-Lite master is permitted to assert AWVALID and wait for AWREADY before asserting WVALID (or assert WVALID and wait for WREADY before asserting AWVALID). Requiring both in the same clock cycle violates AXI4-Lite handshake independence rules and deadlocks decoupled PCIe-to-AXI4-Lite bridges!
- **Hardware & Reference Model Remediation**: Add independent aw_latched_q / awaddr_latched_q and w_latched_q / wdata_latched_q / wstrb_latched_q holding registers in M13 so AW-only, W-only, and simultaneous AW+W arrivals all complete in full compliance with ARM IHI 0022E.

### AUDIT-FINDING-013: M12 NoC Router Corrupted-Flit CRC Error Telemetry & H2 C2C LLR Modulo-256 Windowed Cumulative ACK Support
- **Modules**: `M12, H2, GOLDEN_REF_M12_H2` (`rtl_v3/taalas_token_pipe_noc_router.sv, rtl_hc2/taalas_hc2_c2c_llr_serdes_ctrl.sv` Lines `M12 L195-210; H2 L143-195`)
- **Literature / Standard Sources**: `[S87], [S88], [S89], [S90]`
- **Severity**: `MEDIUM (CRC-8 Error Telemetry Counter & Modulo-256 Cumulative Sequence-Window ACK)`
- **Root Cause Analysis**: 1) In M12 (rtl_v3/taalas_token_pipe_noc_router.sv), corrupted flits detected by check_crc8 increment dropped_flits_o together with buffer-full drops without a dedicated crc_err_flits_o counter for link diagnostics. 2) In H2 (rtl_hc2/taalas_hc2_c2c_llr_serdes_ctrl.sv L143-145), ack_hit_comb checked only exact head sequence match (replay_buf_q[head_ptr_q].seq == c2c_rx_ack_seq_i); adding cumulative in-window sequence acknowledgment per IEEE 802.3 LLR / UCIe 2.0 ([S89], [S90]) allows cumulative ACK advancement across multiple in-flight frames.
- **Hardware & Reference Model Remediation**: Add crc_err_flits_o telemetry port to M12 and cumulative modulo-256 window ACK advancement to H2.

### AUDIT-FINDING-014: Complete Upgrade of Golden Reference Model from 14-Module v1 Float Approximation to 23-Module Bit-Exact Integer/Fixed-Point Lockstep Model (Python + C++)
- **Modules**: `ALL_23_MODULES_GOLDEN_REF` (`golden_model/taalas_golden_model.py, golden_model/taalas_golden_ref_lib.hpp` Lines `1-399`)
- **Literature / Standard Sources**: `[S01]-[S120]`
- **Severity**: `HIGH (Reference Model Coverage & Bit-Exactness Upgrade)`
- **Root Cause Analysis**: golden_model/taalas_golden_model.py previously covered only M01-M14 with floating-point approximations for M08-M11 and lacked M15-M19 and H1-H4 as well as Stage 23 (AUDIT-FINDING-001..006) and Stage 28 (AUDIT-FINDING-007..013) semantics. A complete 23-module bit-exact Python + C++ lockstep Golden Reference Library is required for 10M+ transaction UVM co-simulation.
- **Hardware & Reference Model Remediation**: Upgrade golden_model/taalas_golden_model.py and create golden_model/taalas_golden_ref_lib.hpp covering all 23 modules (M01-M19, H1-H4) with 100% bit-exact integer/fixed-point arithmetic.

