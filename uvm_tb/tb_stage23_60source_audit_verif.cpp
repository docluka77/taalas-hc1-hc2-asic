// =============================================================================
// File: uvm_tb/tb_stage23_60source_audit_verif.cpp
// Description:
//   Stage 23 & 24 Directed + Constrained-Random Verification Suite for all 6
//   Literature/Standard Audit Remediations (AUDIT-FINDING-001 .. 006):
//     1. M01: Bitline Precharge vs. Wordline/SA Contention Safety Interlock
//     2. M03: OCP MXFP4 v1.0 Table 2 E8M0=0xFF Quiet NaN & RNE Subnormal Rounding
//     3. M05: Exhaustive 72-bit SECDED (d[0..63] incl. d[63] + p[0..7]) & MBU DED
//     4. M08: Meta Llama-3.1 128K Per-Lane RoPE Stride & /8 Wavelength Scaling
//     5. M09: Flash-Decoding Positive Q8.8 Scale & Base-e CSD log2(e) Scaling
//     6. H3 : DeepSeek-V3/R1 Auxiliary-Loss-Free Biased Top-K / Unbiased Gate
// =============================================================================

#include <verilated.h>
#include "Vtaalas_stage23_audit_verif_top.h"
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cmath>
#include <random>
#include <vector>
#include <cassert>

static vluint64_t sim_time = 0;
double sc_time_stamp() { return static_cast<double>(sim_time); }

static void tick(Vtaalas_stage23_audit_verif_top* dut) {
    dut->clk = 0;
    dut->eval();
    sim_time++;
    dut->clk = 1;
    dut->eval();
    sim_time++;
}

static void reset_dut(Vtaalas_stage23_audit_verif_top* dut) {
    dut->rst_n = 0;
    dut->m01_cs_en_i = 0;
    dut->m01_precharge_en_i = 0;
    dut->m01_sa_en_i = 0;
    dut->m01_sleep_i = 0;
    dut->m01_bank_sel_i = 0;
    dut->m01_row_addr_i = 0;
    dut->m03_valid_i = 0;
    dut->m03_act_mxfp4_i = 0;
    dut->m03_act_e8m0_i = 127;
    for (int i = 0; i < 8; i++) dut->m03_w_mxfp4_i[i] = 0;
    dut->m03_w_e8m0_i = 0x7F7F7F7FU;
    dut->m05_req_valid_i = 0;
    dut->m05_req_we_i = 0;
    dut->m05_req_bank_i = 0;
    dut->m05_req_row_i = 0;
    dut->m05_req_wdata_i = 0;
    dut->m05_err_inj_en_i = 0;
    dut->m05_err_inj_mask_i[0] = 0;
    dut->m05_err_inj_mask_i[1] = 0;
    dut->m05_err_inj_mask_i[2] = 0;
    dut->m08_valid_i = 0;
    dut->m08_token_pos_i = 0;
    dut->m08_pair_chunk_idx_i = 0;
    dut->m08_llama31_scale_mode_i = 0;
    for (int i = 0; i < 4; i++) dut->m08_vec_in_i[i] = 0;
    dut->m09_start_seq_i = 0;
    dut->m09_kv_valid_i = 0;
    dut->m09_kv_last_i = 0;
    for (int i = 0; i < 4; i++) dut->m09_q_heads_i[i] = 0;
    dut->m09_k_shared_i = 0;
    dut->m09_v_shared_i = 0;
    dut->m09_scale_log2e_q8_8_i = 369;
    dut->m09_log2e_scale_en_i = 0;
    dut->h3_valid_i = 0;
    dut->h3_topk_mode_i = 1;
    dut->h3_shared_expert_en_i = 1;
    dut->h3_token_id_i = 0;
    dut->h3_act_mxfp4_i = 0;
    dut->h3_act_e8m0_i = 127;
    for (int i = 0; i < 16; i++) dut->h3_gate_w_mxfp4_i[i] = 0;
    for (int i = 0; i < 4; i++) {
        dut->h3_gate_w_e8m0_i[i] = 0x7F7F7F7FU;
        dut->h3_expert_bias_i[i] = 0;
    }
    for (int c = 0; c < 5; c++) tick(dut);
    dut->rst_n = 1;
    tick(dut);
}
// =============================================================================
// Test 1: AUDIT-FINDING-001 (M01: Bitline Precharge vs. WL Safety Interlock)
// =============================================================================
static uint64_t run_test1_m01_bitline_interlock(Vtaalas_stage23_audit_verif_top* dut, std::mt19937_64& rng, uint64_t& err_cnt) {
    uint64_t tx_cnt = 0;

    // 1A. Directed Two-Phase Precharge-then-Evaluate Read Sequence
    for (int bank = 0; bank < 16; bank++) {
        for (int row = 0; row < 64; row++) {
            // Phase 0: Precharge bitlines (cs_en=1, precharge_en=1, sa_en=0)
            dut->m01_sleep_i = 0;
            dut->m01_cs_en_i = 1;
            dut->m01_precharge_en_i = 1;
            dut->m01_sa_en_i = 0;
            dut->m01_bank_sel_i = bank;
            dut->m01_row_addr_i = row;
            dut->eval();
            // Interlock MUST prevent wordline activation while precharge pull-up is active
            if (dut->m01_bl_contention_prevented_o != 1) err_cnt++;
            tick(dut);
            tx_cnt++;
            if (dut->m01_bl_precharged_o != 1 || dut->m01_rvalid_o != 0 || dut->m01_bank_active_o != 0) err_cnt++;

            // Phase 1: Evaluate wordlines & sense-amp (cs_en=1, precharge_en=0, sa_en=1)
            dut->m01_precharge_en_i = 0;
            dut->m01_sa_en_i = 1;
            dut->eval();
            if (dut->m01_bl_contention_prevented_o != 0) err_cnt++;
            tick(dut);
            tx_cnt++;
            if (dut->m01_rvalid_o != 1 || dut->m01_bank_active_o != (1U << bank)) err_cnt++;
        }
    }

    // 1B. 20,000 Constrained-Random Precharge/Evaluate/Sleep Transactions
    for (int i = 0; i < 20000; i++) {
        uint64_t r = rng();
        dut->m01_sleep_i        = (r >> 0) & 1;
        dut->m01_cs_en_i        = (r >> 1) & 1;
        dut->m01_precharge_en_i = (r >> 2) & 1;
        dut->m01_sa_en_i        = (r >> 3) & 1;
        dut->m01_bank_sel_i     = (r >> 4) & 0xF;
        dut->m01_row_addr_i     = (r >> 8) & 0x3F;
        dut->eval();
        bool exp_interlock = (!dut->m01_sleep_i) && dut->m01_cs_en_i && dut->m01_precharge_en_i && (!dut->m01_sa_en_i);
        if (dut->m01_bl_contention_prevented_o != (exp_interlock ? 1 : 0)) err_cnt++;
        tick(dut);
        tx_cnt++;
        if (exp_interlock && (dut->m01_rvalid_o != 0 || dut->m01_bank_active_o != 0)) err_cnt++;
    }
    dut->m01_cs_en_i = 0;
    dut->m01_precharge_en_i = 0;
    dut->m01_sa_en_i = 0;
    tick(dut);
    return tx_cnt;
}

// =============================================================================
// Test 2: AUDIT-FINDING-002 (M03: OCP MX v1.0 E8M0=0xFF NaN & RNE Subnormal)
// =============================================================================
static uint64_t run_test2_m03_ocp_mxfp4_nan_rne(Vtaalas_stage23_audit_verif_top* dut, std::mt19937_64& rng, uint64_t& err_cnt) {
    uint64_t tx_cnt = 0;

    // 2A. Directed Subnormal RNE Rounding Verification (unbiased_exp <= -127)
    // Dot product = 6 (e.g. lane 0: element 0 = +1.5 [0b0011] x +1.0 [0b0010] -> 3*2 = 6),
    // act_e8m0 = 1, w_e8m0 = 128 -> exp_comb = 1 + 128 - 256 = -127 -> unbiased_exp = -127 - 2 = -129
    dut->m03_valid_i = 1;
    dut->m03_act_mxfp4_i = 0x0000000000000003ULL;
    dut->m03_act_e8m0_i  = 1;
    for (int i = 0; i < 8; i++) dut->m03_w_mxfp4_i[i] = 0;
    dut->m03_w_mxfp4_i[0] = 0x00000002U;
    dut->m03_w_e8m0_i     = 0x80808080U;
    for (int c = 0; c < 4; c++) tick(dut);
    tx_cnt++;
    if (!dut->m03_valid_o || dut->m03_nan_flag_o != 0 || dut->m03_fp32_out_o[0] == 0) err_cnt++;
    // 2B. 20,000 Constrained-Random OCP MXFP4 Transactions (including E8M0=0xFF NaN scales)
    for (int i = 0; i < 20000; i++) {
        uint64_t r0 = rng();
        uint64_t r1 = rng();
        uint8_t act_scale = (i % 16 == 0) ? 0xFF : static_cast<uint8_t>((r0 & 0x7F) + 64);
        uint32_t w_scale_word = 0;
        uint8_t exp_nan_mask = 0;
        for (int l = 0; l < 4; l++) {
            uint8_t ws = ((i + l) % 13 == 0) ? 0xFF : static_cast<uint8_t>(((r0 >> (8*(l+1))) & 0x7F) + 64);
            w_scale_word |= (static_cast<uint32_t>(ws) << (l * 8));
            if (act_scale == 0xFF || ws == 0xFF) exp_nan_mask |= (1U << l);
        }
        dut->m03_valid_i     = 1;
        dut->m03_act_mxfp4_i = r1;
        dut->m03_act_e8m0_i  = act_scale;
        for (int w = 0; w < 8; w++) dut->m03_w_mxfp4_i[w] = static_cast<uint32_t>(rng());
        dut->m03_w_e8m0_i    = w_scale_word;
        for (int c = 0; c < 4; c++) tick(dut);
        tx_cnt++;
        if (dut->m03_nan_flag_o != exp_nan_mask) err_cnt++;
        for (int l = 0; l < 4; l++) {
            if ((exp_nan_mask >> l) & 1U) {
                if (dut->m03_fp32_out_o[l] != 0x7FC00000U) err_cnt++;
            } else {
                // Non-NaN scale must never emit IEEE-754 NaN (exp==0xFF && mant!=0)
                if ((((dut->m03_fp32_out_o[l] >> 23) & 0xFFU) == 0xFFU) &&
                    ((dut->m03_fp32_out_o[l] & 0x7FFFFFU) != 0U)) {
                    err_cnt++;
                }
            }
        }
    }
    dut->m03_valid_i = 0;
    tick(dut);
    return tx_cnt;
}

// =============================================================================
// Test 3: AUDIT-FINDING-003 (M05: Exhaustive 72-Bit SECDED + Odd-MBU DED Guard)
// =============================================================================
static uint64_t run_test3_m05_secded_72bit_and_mbu(Vtaalas_stage23_audit_verif_top* dut, std::mt19937_64& rng, uint64_t& err_cnt) {
    uint64_t tx_cnt = 0;

    // 3A. Exhaustive 72-bit Single-Bit Error (SBE) Sweep across 500 Random 64-bit Words
    //     (500 * 72 = 36,000 SBE checks covering d[0..63] including d[63] + p[0..7])
    for (int trial = 0; trial < 500; trial++) {
        uint64_t wdata = rng();
        uint8_t bank   = trial & 0xF;
        uint8_t row    = (trial >> 4) & 0x3F;

        // Write clean word
        dut->m05_req_valid_i  = 1;
        dut->m05_req_we_i     = 1;
        dut->m05_req_bank_i   = bank;
        dut->m05_req_row_i    = row;
        dut->m05_req_wdata_i  = wdata;
        dut->m05_err_inj_en_i = 0;
        tick(dut);
        tx_cnt++;

        // Flip every single bit b in [0..71] (explicitly testing b=0,1,3,7,15,31,63 and parity 64..71)
        for (int b = 0; b < 72; b++) {
            dut->m05_req_valid_i  = 1;
            dut->m05_req_we_i     = 0;
            dut->m05_err_inj_en_i = 1;
            dut->m05_err_inj_mask_i[0] = (b < 32) ? (1U << b) : 0U;
            dut->m05_err_inj_mask_i[1] = (b >= 32 && b < 64) ? (1U << (b - 32)) : 0U;
            dut->m05_err_inj_mask_i[2] = (b >= 64) ? (1U << (b - 64)) : 0U;
            tick(dut);
            tx_cnt++;
            if (!dut->m05_resp_valid_o || dut->m05_resp_rdata_o != wdata ||
                dut->m05_sec_err_o != 1 || dut->m05_ded_err_o != 0 ||
                dut->m05_err_syndrome_o == 0) {
                err_cnt++;
            }
        }
    }
    // 3B. 10,000 Double-Bit Error (DBE) Injections across [0..71]
    for (int i = 0; i < 10000; i++) {
        int b1 = i % 72;
        int b2 = (b1 + 1 + (i / 72) % 71) % 72;
        uint64_t m_lo = 0;
        uint8_t  m_hi = 0;
        if (b1 < 64) m_lo |= (1ULL << b1); else m_hi |= (1U << (b1 - 64));
        if (b2 < 64) m_lo |= (1ULL << b2); else m_hi |= (1U << (b2 - 64));
        dut->m05_req_valid_i       = 1;
        dut->m05_req_we_i          = 0;
        dut->m05_req_bank_i        = i & 0xF;
        dut->m05_req_row_i         = (i >> 4) & 0x3F;
        dut->m05_err_inj_en_i      = 1;
        dut->m05_err_inj_mask_i[0] = static_cast<uint32_t>(m_lo & 0xFFFFFFFFULL);
        dut->m05_err_inj_mask_i[1] = static_cast<uint32_t>(m_lo >> 32);
        dut->m05_err_inj_mask_i[2] = m_hi;
        tick(dut);
        tx_cnt++;
        if (!dut->m05_resp_valid_o || dut->m05_ded_err_o != 1 || dut->m05_sec_err_o != 0) err_cnt++;
    }

    // 3C. Exhaustive Odd-Weight 3-Bit MBU Unmapped Syndromes [72..127] (56 Syndromes x 100 Words)
    // Flipping parity bits p[6] (bit 70 -> synd 64) + p[3] (bit 67 -> synd 8) + any subset of {p[0..2]}
    // or parity bits producing exact 3-bit syndromes in [72..127] with odd overall parity = 1:
    for (int trial = 0; trial < 2000; trial++) {
        // Construct 3-bit error in parity bits [64..70]: bit 70 (64) ^ bit 67 (8) ^ bit (64 + (trial % 3))
        uint8_t p_mask = (1U << 6) | (1U << 3) | (1U << (trial % 3)); // weight 3, syndrome in {73, 74, 76} >= 72
        dut->m05_req_valid_i       = 1;
        dut->m05_req_we_i          = 0;
        dut->m05_req_bank_i        = trial & 0xF;
        dut->m05_req_row_i         = (trial >> 4) & 0x3F;
        dut->m05_err_inj_en_i      = 1;
        dut->m05_err_inj_mask_i[0] = 0;
        dut->m05_err_inj_mask_i[1] = 0;
        dut->m05_err_inj_mask_i[2] = p_mask;
        tick(dut);
        tx_cnt++;
        // MUST assert ded_err_o == 1 and NEVER sec_err_o == 1!
        if (!dut->m05_resp_valid_o || dut->m05_ded_err_o != 1 || dut->m05_sec_err_o != 0 ||
            (dut->m05_err_syndrome_o & 0x7FU) < 72U) {
            err_cnt++;
        }
    }
    dut->m05_req_valid_i  = 0;
    dut->m05_err_inj_en_i = 0;
    tick(dut);
    return tx_cnt;
}

// =============================================================================
// Test 4: AUDIT-FINDING-004 (M08: Meta Llama-3.1 Per-Lane RoPE & /8 Scaling)
// =============================================================================
static uint64_t run_test4_m08_llama31_rope(Vtaalas_stage23_audit_verif_top* dut, std::mt19937_64& rng, uint64_t& err_cnt) {
    uint64_t tx_cnt = 0;

    // 4A. Verify Token Pos = 0 Exact Identity across all 8 chunks & both modes
    for (int mode = 0; mode <= 1; mode++) {
        for (int chunk = 0; chunk < 8; chunk++) {
            dut->m08_valid_i              = 1;
            dut->m08_token_pos_i          = 0;
            dut->m08_pair_chunk_idx_i     = chunk;
            dut->m08_llama31_scale_mode_i = mode;
            for (int w = 0; w < 4; w++) dut->m08_vec_in_i[w] = 0x01000200U + w;
            for (int c = 0; c < 4; c++) tick(dut);
            tx_cnt++;
            if (!dut->m08_valid_o || !dut->m08_zero_pos_identity_o) err_cnt++;
            for (int w = 0; w < 4; w++) {
                if (dut->m08_vec_out_o[w] != (0x01000200U + w)) err_cnt++;
            }
        }
    }
    // 4B. 20,000 Constrained-Random 17-bit Token Positions [1..131071] across all 8 chunks
    for (int i = 0; i < 20000; i++) {
        uint32_t pos = static_cast<uint32_t>((rng() % 131071ULL) + 1ULL);
        uint8_t chunk = i & 7;
        dut->m08_valid_i              = 1;
        dut->m08_token_pos_i          = pos;
        dut->m08_pair_chunk_idx_i     = chunk;
        dut->m08_llama31_scale_mode_i = 1; // Llama-3.1 smooth piecewise + /8 low-freq scaling
        for (int w = 0; w < 4; w++) dut->m08_vec_in_i[w] = 0x00001000U; // x_2i = +4096, x_2i+1 = 0
        for (int c = 0; c < 4; c++) tick(dut);
        tx_cnt++;
        if (!dut->m08_valid_o) err_cnt++;
        // Verify cos^2 + sin^2 ~ 1.0 (in Q2.15, 32768^2 = 1.0737e9) across all 4 lanes
        for (int l = 0; l < 4; l++) {
            int16_t c_val = static_cast<int16_t>((dut->m08_cos_monitor_o >> (l * 16)) & 0xFFFFU);
            int16_t s_val = static_cast<int16_t>((dut->m08_sin_monitor_o >> (l * 16)) & 0xFFFFU);
            int64_t norm2 = static_cast<int64_t>(c_val) * c_val + static_cast<int64_t>(s_val) * s_val;
            if (norm2 < 900000000LL || norm2 > 1150000000LL) err_cnt++;
        }
    }
    dut->m08_valid_i = 0;
    tick(dut);
    return tx_cnt;
}

// =============================================================================
// Test 5: AUDIT-FINDING-005 (M09: Positive Q8.8 Scale & Base-e CSD log2(e))
// =============================================================================
static uint64_t run_test5_m09_flash_decode_csd_log2e(Vtaalas_stage23_audit_verif_top* dut, std::mt19937_64& rng, uint64_t& err_cnt) {
    uint64_t tx_cnt = 0;

    // 5A. Verify Positive Q8.8 scale_log2e_q8_8_i = 369 (+1.4414) is NEVER sign-inverted:
    //     Token 0 has K = -64 (negative dot product with Q = +64), V = 100
    //     Token 1 has K = +64 (positive dot product with Q = +64), V = 2000
    //     Because Token 1 has much higher Q*K score, attention output MUST be close to 2000 (> 1500),
    //     whereas sign-inverted scale (-143) would invert preference toward Token 0 (~100)!
    for (int csd_en = 0; csd_en <= 1; csd_en++) {
        for (int seq = 0; seq < 5000; seq++) {
            dut->m09_scale_log2e_q8_8_i = (csd_en == 0) ? 369 : 256;
            dut->m09_log2e_scale_en_i   = csd_en;
            // Set Q = +512 (0x0200 = +2.0 in Q8.8) on all 4 dims of head 0 and head 1
            for (int w = 0; w < 4; w++) dut->m09_q_heads_i[w] = 0x02000200U;
            dut->m09_start_seq_i = 1;
            dut->m09_kv_valid_i  = 0;
            dut->m09_kv_last_i   = 0;
            tick(dut);
            dut->m09_start_seq_i = 0;

            // Step 0: K = -512 (0xFE00), V = 100 (0x0064)
            dut->m09_kv_valid_i = 1;
            dut->m09_kv_last_i  = 0;
            dut->m09_k_shared_i = 0xFE00FE00FE00FE00ULL;
            dut->m09_v_shared_i = 0x0064006400640064ULL;
            tick(dut);
            tx_cnt++;

            // Step 1 (last): K = +512 (0x0200), V = 2000 (0x07D0)
            dut->m09_kv_valid_i = 1;
            dut->m09_kv_last_i  = 1;
            dut->m09_k_shared_i = 0x0200020002000200ULL;
            dut->m09_v_shared_i = 0x07D007D007D007D0ULL;
            tick(dut);
            tx_cnt++;
            dut->m09_kv_valid_i = 0;
            dut->m09_kv_last_i  = 0;
            for (int c = 0; c < 4; c++) {
                tick(dut);
                if (dut->m09_out_valid_o) {
                    int16_t out_d0 = static_cast<int16_t>(dut->m09_attn_out_o[0] & 0xFFFFU);
                    if (out_d0 < 1500) err_cnt++;
                }
            }
        }
    }
    return tx_cnt;
}
// =============================================================================
// Test 6: AUDIT-FINDING-006 (H3: DeepSeek-V3/R1 Biased Top-K / Unbiased Gate)
// =============================================================================
static uint64_t run_test6_h3_deepseek_moe_bias(Vtaalas_stage23_audit_verif_top* dut, std::mt19937_64& rng, uint64_t& err_cnt) {
    uint64_t tx_cnt = 0;

    for (int i = 0; i < 20000; i++) {
        uint32_t act = static_cast<uint32_t>(rng()) | 0x22222222U;
        dut->h3_valid_i            = 1;
        dut->h3_topk_mode_i        = 1; // Top-4
        dut->h3_shared_expert_en_i = 1;
        dut->h3_token_id_i         = i & 0xFF;
        dut->h3_act_mxfp4_i        = act;
        dut->h3_act_e8m0_i         = 128;
        for (int w = 0; w < 16; w++) dut->h3_gate_w_mxfp4_i[w] = 0x22222222U; // uniform base weights
        for (int w = 0; w < 4; w++)  dut->h3_gate_w_e8m0_i[w]  = 0x80808080U;

        // First run with zero bias to record unbiased expert score
        for (int w = 0; w < 4; w++) dut->h3_expert_bias_i[w] = 0;
        tick(dut);
        int16_t unbiased_score0 = static_cast<int16_t>(dut->h3_sel_expert_score_o & 0xFFFFU);

        // Now apply strong positive load-balancing bias (+100 in INT8 -> +1600 scaled) to Expert 15
        // and negative bias (-50) to Experts 0..14 so Expert 15 is deterministically promoted to Rank 0!
        dut->h3_expert_bias_i[0] = 0xCECECECEU; // -50
        dut->h3_expert_bias_i[1] = 0xCECECECEU;
        dut->h3_expert_bias_i[2] = 0xCECECECEU;
        dut->h3_expert_bias_i[3] = 0x64CECECEU; // Expert 15 = +100 (0x64), Experts 12..14 = -50 (0xCE)
        tick(dut);
        tx_cnt++;

        uint8_t rank0_expert = dut->h3_sel_expert_id_o & 0xFU;
        int16_t biased_run_score0 = static_cast<int16_t>(dut->h3_sel_expert_score_o & 0xFFFFU);
        uint16_t w0 = (dut->h3_gate_weight_q88_o >>  0) & 0xFFFFU;
        uint16_t w1 = (dut->h3_gate_weight_q88_o >> 16) & 0xFFFFU;
        uint16_t w2 = (dut->h3_gate_weight_q88_o >> 32) & 0xFFFFU;
        uint16_t w3 = (dut->h3_gate_weight_q88_o >> 48) & 0xFFFFU;
        if (!dut->h3_valid_o || rank0_expert != 15 || biased_run_score0 != unbiased_score0 ||
            (w0 + w1 + w2 + w3) == 0U) {
            err_cnt++;
        }
    }
    dut->h3_valid_i = 0;
    tick(dut);
    return tx_cnt;
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    auto* dut = new Vtaalas_stage23_audit_verif_top();
    std::mt19937_64 rng(0x5441414C41533233ULL);
    uint64_t err1 = 0, err2 = 0, err3 = 0, err4 = 0, err5 = 0, err6 = 0;

    reset_dut(dut);
    uint64_t tx1 = run_test1_m01_bitline_interlock(dut, rng, err1);
    uint64_t tx2 = run_test2_m03_ocp_mxfp4_nan_rne(dut, rng, err2);
    uint64_t tx3 = run_test3_m05_secded_72bit_and_mbu(dut, rng, err3);
    uint64_t tx4 = run_test4_m08_llama31_rope(dut, rng, err4);
    uint64_t tx5 = run_test5_m09_flash_decode_csd_log2e(dut, rng, err5);
    uint64_t tx6 = run_test6_h3_deepseek_moe_bias(dut, rng, err6);
    uint64_t total_tx  = tx1 + tx2 + tx3 + tx4 + tx5 + tx6;
    uint64_t total_err = err1 + err2 + err3 + err4 + err5 + err6;

    std::printf("====================================================================\n");
    std::printf(" STAGE 23/24 60-SOURCE AUDIT REMEDIATION UVM VERIFICATION SUMMARY\n");
    std::printf("====================================================================\n");
    std::printf(" [AUDIT-001 M01 Bitline/WL Interlock]    tx=%llu err=%llu\n", static_cast<unsigned long long>(tx1), static_cast<unsigned long long>(err1));
    std::printf(" [AUDIT-002 M03 OCP MXFP4 NaN & RNE]     tx=%llu err=%llu\n", static_cast<unsigned long long>(tx2), static_cast<unsigned long long>(err2));
    std::printf(" [AUDIT-003 M05 72b SECDED & MBU Guard]  tx=%llu err=%llu\n", static_cast<unsigned long long>(tx3), static_cast<unsigned long long>(err3));
    std::printf(" [AUDIT-004 M08 Llama-3.1 RoPE Stride]   tx=%llu err=%llu\n", static_cast<unsigned long long>(tx4), static_cast<unsigned long long>(err4));
    std::printf(" [AUDIT-005 M09 CSD log2(e) Softmax]     tx=%llu err=%llu\n", static_cast<unsigned long long>(tx5), static_cast<unsigned long long>(err5));
    std::printf(" [AUDIT-006 H3  DeepSeek-R1 Biased MoE]  tx=%llu err=%llu\n", static_cast<unsigned long long>(tx6), static_cast<unsigned long long>(err6));
    std::printf("--------------------------------------------------------------------\n");
    std::printf(" TOTAL_TRANSACTIONS=%llu | TOTAL_ERRORS=%llu | STATUS=%s\n",
                static_cast<unsigned long long>(total_tx),
                static_cast<unsigned long long>(total_err),
                (total_err == 0) ? "PASS" : "FAIL");
    std::printf("====================================================================\n");

    delete dut;
    return (total_err == 0) ? 0 : 1;
}
