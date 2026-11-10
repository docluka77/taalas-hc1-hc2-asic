// =============================================================================
// File:        uvm_tb/tb_stage20_10m_cycle_soak.cpp
// Project:     Taalas HC1/HC2 Autonomous Hardware Engineering Marathon (Stage 20C)
// Description: 10,000,000-Cycle Continuous Hardware Soak & Corner-Case Stress
//              UVM Verification Environment across all 9 Core HC1/HC2 Engines:
//                - M02: taalas_3b6b_wired_mac_array (2,500,000 txns)
//                - M03: taalas_mxfp4_hc2_mac_lane (2,500,000 txns)
//                - M04: taalas_group_dequant_scale_unit (2,500,000 txns)
//                - M05: taalas_sram_6t_banked_macro (5,000,000 R/W + SBE/DBE txns)
//                - M07: taalas_lora_sram_overlay_engine (2,500,000 txns)
//                - M12: taalas_token_pipe_noc_router (2,500,000 flit txns)
//                - M18: taalas_ecc_bist_scrubber (10M-cycle SEU patrol + CAM + BIST)
//                - H2:  taalas_hc2_c2c_llr_serdes_ctrl (C2C bit-error storm + replay)
//                - H3:  taalas_hc2_moe_mla_router (2,500,000 Top-K MoE txns)
// =============================================================================

#include <iostream>
#include <fstream>
#include <iomanip>
#include <cstdint>
#include <cstring>
#include <cmath>
#include <vector>
#include <deque>
#include <chrono>
#include <cassert>

#include "Vtaalas_stage20_soak_top.h"
#include "verilated.h"

namespace {

static inline uint64_t xorshift64(uint64_t& state) {
    uint64_t x = state;
    x ^= x << 13;
    x ^= x >> 7;
    x ^= x << 17;
    state = x;
    return x;
}

static inline int64_t clamp_signed(int64_t val, int bits) {
    int64_t lo = -(1LL << (bits - 1));
    int64_t hi = (1LL << (bits - 1)) - 1LL;
    if (val < lo) return lo;
    if (val > hi) return hi;
    return val;
}

static inline int decode_e2m1_int2x_ref(uint8_t code4) {
    static const int lut[8] = {0, 1, 2, 3, 4, 6, 8, 12};
    int mag = lut[code4 & 0x7u];
    return ((code4 >> 3) & 1u) ? -mag : mag;
}

static inline uint8_t calc_noc_crc8(uint32_t hdr_24b) {
    uint8_t b0 = hdr_24b & 0xFFu;
    uint8_t b1 = (hdr_24b >> 8) & 0xFFu;
    uint8_t b2 = (hdr_24b >> 16) & 0xFFu;
    return static_cast<uint8_t>(b0 ^ b1 ^ b2 ^ 0x5Au);
}

static inline uint32_t make_noc_hdr(uint8_t ftype, uint8_t vc, uint8_t src, uint8_t dst, uint8_t slot) {
    uint32_t h24 = ((uint32_t)(ftype & 0xFu) << 20) |
                   ((uint32_t)(vc    & 0x3u) << 18) |
                   ((uint32_t)(src   & 0x3Fu) << 12) |
                   ((uint32_t)(dst   & 0x3Fu) << 6)  |
                   ((uint32_t)(slot  & 0x3Fu));
    uint8_t crc = calc_noc_crc8(h24);
    return (h24 << 8) | crc;
}

static inline uint8_t gf16_mul_by_3_ref(uint8_t a) {
    uint8_t a0 = (a >> 0) & 1u;
    uint8_t a1 = (a >> 1) & 1u;
    uint8_t a2 = (a >> 2) & 1u;
    uint8_t a3 = (a >> 3) & 1u;
    uint8_t r0 = a0 ^ a3;
    uint8_t r1 = a0 ^ a1 ^ a3;
    uint8_t r2 = a1 ^ a2;
    uint8_t r3 = a2 ^ a3;
    return static_cast<uint8_t>((r3 << 3) | (r2 << 2) | (r1 << 1) | r0);
}

static inline uint8_t swizzle_gf16_bank_ref(uint8_t logical_bank, uint8_t row_addr_8b) {
    uint8_t r_lo = row_addr_8b & 0xFu;
    uint8_t r_hi = (row_addr_8b >> 4) & 0xFu;
    return static_cast<uint8_t>((logical_bank & 0xFu) ^ r_lo ^ gf16_mul_by_3_ref(r_hi));
}

static inline uint16_t crc16_ccitt_step64_ref(uint16_t crc_in, uint64_t data_in) {
    uint16_t c = crc_in;
    for (int b = 63; b >= 0; --b) {
        uint16_t fb = ((c >> 15) & 1U) ^ static_cast<uint16_t>((data_in >> b) & 1ULL);
        c = static_cast<uint16_t>((c << 1) ^ (fb ? 0x1021U : 0x0000U));
    }
    return c;
}

struct SoakWavePattern {
    // M02 Stimulus & Golden
    uint8_t  m02_zskip;
    uint64_t m02_act_lo;
    uint64_t m02_act_hi;
    uint64_t m02_w3b_pat;
    uint64_t m02_out_pat;
    int16_t  exp_m02_act_sum;
    uint16_t exp_m02_zero_ops;
    uint64_t exp_m02_acc_lo;
    uint64_t exp_m02_acc_mid;
    uint64_t exp_m02_acc_hi;

    // M03 Stimulus & Golden
    uint64_t m03_act_mxfp4;
    uint8_t  m03_act_e8m0;
    uint64_t m03_w_base;
    uint32_t m03_w_e8m0;
    uint64_t exp_m03_dot_int16;
    uint64_t exp_m03_exp_comb;
    uint64_t exp_m03_fp32_lo;
    uint64_t exp_m03_fp32_hi;

    // M04 Stimulus & Golden
    uint8_t  m04_lora_en;
    uint32_t m04_raw_acc_ch0;
    int16_t  m04_act_sum;
    int16_t  m04_w_scale_ch0;
    int16_t  m04_act_scale;
    int8_t   m04_w_zp_ch0;
    int16_t  m04_lora_delta_ch0;
    uint64_t exp_m04_deq_lo;
    uint64_t exp_m04_deq_hi;
    uint8_t  exp_m04_sat;

    // M07 Stimulus & Golden
    uint8_t  m07_lora_en;
    uint8_t  m07_active_rank;
    int16_t  m07_alpha_q88;
    uint8_t  m07_skew_delay;
    uint64_t m07_act_lo;
    uint64_t m07_act_hi;
    uint64_t exp_m07_delta_lo;
    uint64_t exp_m07_delta_hi;

    // H3 Stimulus & Golden
    uint8_t  h3_topk_mode;
    uint8_t  h3_shared_en;
    uint8_t  h3_token_id;
    uint32_t h3_act_mxfp4;
    uint8_t  h3_act_e8m0;
    uint16_t exp_h3_sel_ids;
    uint32_t exp_h3_dst_chips;
    uint64_t exp_h3_weights;
    uint64_t exp_h3_scores;
    uint16_t exp_h3_act_mask;
    uint16_t exp_h3_cg_mask;
};

static void build_soak_wave_pattern(
    SoakWavePattern& pat,
    int idx,
    uint64_t& rng,
    const int8_t lora_a[8][16],
    const int8_t lora_b[8][8]
) {
    // 1. M02: 3b/6b CSD Wired MAC Array (VEC_LEN=16, OUT_CHANNELS=8, NUM_OUTLIERS=4)
    pat.m02_zskip   = (idx % 5 == 0) ? 0 : 1;
    pat.m02_act_lo  = (idx == 0) ? 0ULL : (idx == 1 ? 0x7F7F7F7F7F7F7F7FULL : xorshift64(rng));
    pat.m02_act_hi  = (idx == 0) ? 0ULL : (idx == 2 ? 0x8080808080808080ULL : xorshift64(rng));
    pat.m02_w3b_pat = (idx == 0) ? 0ULL : xorshift64(rng);
    pat.m02_out_pat = (idx == 0) ? 0ULL : xorshift64(rng);

    int8_t m02_act[16];
    int16_t act_sum = 0;
    for (int i = 0; i < 8; ++i) {
        m02_act[i]     = static_cast<int8_t>((pat.m02_act_lo >> (i * 8)) & 0xFFu);
        m02_act[i + 8] = static_cast<int8_t>((pat.m02_act_hi >> (i * 8)) & 0xFFu);
    }
    for (int i = 0; i < 16; ++i) act_sum = static_cast<int16_t>(act_sum + m02_act[i]);
    pat.exp_m02_act_sum = act_sum;

    uint16_t zops = 0;
    uint64_t acc_words[3] = {0ULL, 0ULL, 0ULL};
    for (int ch = 0; ch < 8; ++ch) {
        int64_t bsum = 0;
        for (int i = 0; i < 16; ++i) {
            uint8_t raw3 = static_cast<uint8_t>((pat.m02_w3b_pat >> (((ch * 3 + i) & 15) * 3)) & 0x7u);
            int8_t  w3   = (raw3 & 4u) ? static_cast<int8_t>(raw3 | 0xF8u) : static_cast<int8_t>(raw3);
            if (pat.m02_zskip && (w3 == 0 || m02_act[i] == 0)) zops++;
            bsum += static_cast<int64_t>(w3) * static_cast<int64_t>(m02_act[i]);
        }
        int64_t osum = 0;
        for (int k = 0; k < 4; ++k) {
            uint8_t raw6 = static_cast<uint8_t>((pat.m02_out_pat >> (((ch + k) & 7) * 6)) & 0x3Fu);
            int8_t  w6   = (raw6 & 32u) ? static_cast<int8_t>(raw6 | 0xC0u) : static_cast<int8_t>(raw6);
            uint8_t oidx = static_cast<uint8_t>((ch + k * 4) & 15);
            osum += static_cast<int64_t>(w6) * static_cast<int64_t>(m02_act[oidx]);
        }
        uint64_t c24 = static_cast<uint64_t>(clamp_signed(bsum + osum, 24)) & 0xFFFFFFULL;
        int bit_pos = ch * 24;
        for (int b = 0; b < 24; ++b) {
            if ((c24 >> b) & 1ULL) {
                acc_words[(bit_pos + b) >> 6] |= (1ULL << ((bit_pos + b) & 63));
            }
        }
    }
    pat.exp_m02_zero_ops = zops;
    pat.exp_m02_acc_lo   = acc_words[0];
    pat.exp_m02_acc_mid  = acc_words[1];
    pat.exp_m02_acc_hi   = acc_words[2];

    // 2. M03: HC2 OCP MXFP4 MAC Lane (BLOCK_SIZE=16, NUM_LANES=4)
    pat.m03_act_mxfp4  = (idx == 0) ? 0ULL : xorshift64(rng);
    pat.m03_act_e8m0   = static_cast<uint8_t>(115 + (xorshift64(rng) % 25));
    pat.m03_w_base     = (idx == 0) ? 0ULL : xorshift64(rng);
    pat.m03_w_e8m0     = 0U;
    pat.exp_m03_dot_int16 = 0ULL;
    pat.exp_m03_exp_comb  = 0ULL;
    pat.exp_m03_fp32_lo   = 0ULL;
    pat.exp_m03_fp32_hi   = 0ULL;

    for (int l = 0; l < 4; ++l) {
        uint8_t we8 = static_cast<uint8_t>(115 + (xorshift64(rng) % 25));
        pat.m03_w_e8m0 |= (static_cast<uint32_t>(we8) << (l * 8));
        uint64_t w_lane = pat.m03_w_base ^ (0x1111111111111111ULL * static_cast<uint64_t>(l));
        int64_t s_int = 0;
        for (int i = 0; i < 16; ++i) {
            uint8_t ac = static_cast<uint8_t>((pat.m03_act_mxfp4 >> (i * 4)) & 0xFu);
            uint8_t wc = static_cast<uint8_t>((w_lane >> (i * 4)) & 0xFu);
            s_int += decode_e2m1_int2x_ref(wc) * decode_e2m1_int2x_ref(ac);
        }
        int64_t ec = static_cast<int64_t>(we8) + static_cast<int64_t>(pat.m03_act_e8m0) - 256;
        float fval = (s_int == 0) ? 0.0f : std::ldexp(static_cast<float>(s_int), static_cast<int>(ec));
        uint32_t fbits = 0;
        std::memcpy(&fbits, &fval, sizeof(uint32_t));

        pat.exp_m03_dot_int16 |= (static_cast<uint64_t>(static_cast<uint16_t>(s_int)) << (l * 16));
        pat.exp_m03_exp_comb  |= ((static_cast<uint64_t>(ec) & 0x3FFULL) << (l * 10));
        if (l < 2) pat.exp_m03_fp32_lo |= (static_cast<uint64_t>(fbits) << (l * 32));
        else       pat.exp_m03_fp32_hi |= (static_cast<uint64_t>(fbits) << ((l - 2) * 32));
    }

    // 3. M04: Per-Group Zero-Point & Scale Dequantizer (OUT_CHANNELS=8)
    pat.m04_lora_en        = static_cast<uint8_t>(idx & 1);
    int64_t raw0           = (idx == 3) ? 450000LL : static_cast<int64_t>(static_cast<int32_t>(xorshift64(rng)) % 16000);
    pat.m04_raw_acc_ch0    = static_cast<uint32_t>(raw0) & 0xFFFFFFu;
    pat.m04_act_sum        = static_cast<int16_t>(static_cast<int32_t>(xorshift64(rng)) % 512);
    pat.m04_w_scale_ch0    = static_cast<int16_t>((idx == 3) ? 4096 : (static_cast<int32_t>(xorshift64(rng)) % 384));
    pat.m04_act_scale      = static_cast<int16_t>((idx == 3) ? 4096 : (static_cast<int32_t>(xorshift64(rng)) % 384));
    pat.m04_w_zp_ch0       = static_cast<int8_t>(static_cast<int32_t>(xorshift64(rng)) % 12);
    pat.m04_lora_delta_ch0 = static_cast<int16_t>(static_cast<int32_t>(xorshift64(rng)) % 512);

    pat.exp_m04_deq_lo = 0ULL;
    pat.exp_m04_deq_hi = 0ULL;
    pat.exp_m04_sat    = 0u;
    for (int j = 0; j < 8; ++j) {
        uint32_t r24_u = (pat.m04_raw_acc_ch0 + static_cast<uint32_t>(j * 64)) & 0xFFFFFFu;
        int64_t  r24_s = (r24_u & 0x800000u) ? static_cast<int64_t>(r24_u | 0xFFFFFFFFFF000000ULL)
                                             : static_cast<int64_t>(r24_u);
        int16_t ws_j = static_cast<int16_t>(pat.m04_w_scale_ch0 + j * 8);
        int8_t  zp_j = static_cast<int8_t>(pat.m04_w_zp_ch0 + j);
        int16_t ld_j = static_cast<int16_t>(pat.m04_lora_delta_ch0 + j * 4);

        int64_t zp_comp    = clamp_signed(r24_s - static_cast<int64_t>(zp_j) * static_cast<int64_t>(pat.m04_act_sum), 24);
        int64_t comb_scale = static_cast<int64_t>(ws_j) * static_cast<int64_t>(pat.m04_act_scale);
        int64_t ch_acc     = zp_comp * comb_scale;
        int64_t scaled     = (ch_acc + 32768LL) >> 16;
        if (pat.m04_lora_en) scaled += ld_j;
        int64_t clamped    = clamp_signed(scaled, 16);
        if (clamped != scaled) pat.exp_m04_sat = 1u;
        uint64_t c16 = static_cast<uint16_t>(clamped);
        if (j < 4) pat.exp_m04_deq_lo |= (c16 << (j * 16));
        else       pat.exp_m04_deq_hi |= (c16 << ((j - 4) * 16));
    }

    // 4. M07: Zero-Stall SRAM LoRA Overlay Engine (IN_DIM=16, OUT_CHANNELS=8, MAX_RANK=8)
    pat.m07_lora_en     = (idx % 7 == 0) ? 0u : 1u;
    pat.m07_active_rank = (idx % 3 == 0) ? 4u : 8u;
    pat.m07_alpha_q88   = static_cast<int16_t>(64 + (xorshift64(rng) % 384));
    pat.m07_skew_delay  = static_cast<uint8_t>(idx & 1); // 0 or 1 -> latency 2 or 3 cycles (< 4)
    pat.m07_act_lo      = xorshift64(rng);
    pat.m07_act_hi      = xorshift64(rng);

    int8_t m07_x[16];
    for (int i = 0; i < 8; ++i) {
        m07_x[i]     = static_cast<int8_t>((pat.m07_act_lo >> (i * 8)) & 0xFFu);
        m07_x[i + 8] = static_cast<int8_t>((pat.m07_act_hi >> (i * 8)) & 0xFFu);
    }
    int64_t exp_h[8];
    for (int r = 0; r < 8; ++r) {
        int64_t acc = 0;
        if (pat.m07_lora_en && r < pat.m07_active_rank) {
            for (int i = 0; i < 16; ++i) acc += static_cast<int64_t>(lora_a[r][i]) * static_cast<int64_t>(m07_x[i]);
        }
        exp_h[r] = clamp_signed(acc, 24);
    }
    pat.exp_m07_delta_lo = 0ULL;
    pat.exp_m07_delta_hi = 0ULL;
    for (int j = 0; j < 8; ++j) {
        int64_t uacc = 0;
        if (pat.m07_lora_en) {
            for (int r = 0; r < pat.m07_active_rank; ++r) uacc += static_cast<int64_t>(lora_b[j][r]) * exp_h[r];
        }
        int64_t scaled = (uacc * static_cast<int64_t>(pat.m07_alpha_q88) + 32768LL) >> 16;
        uint64_t d16   = pat.m07_lora_en ? static_cast<uint16_t>(clamp_signed(scaled, 16)) : 0u;
        if (j < 4) pat.exp_m07_delta_lo |= (d16 << (j * 16));
        else       pat.exp_m07_delta_hi |= (d16 << ((j - 4) * 16));
    }

    // 5. H3: DeepSeek-R1 Top-K MoE & MLA Router (NUM_EXPERTS=16, DIM_GATE=8, MAX_K=4, NUM_CHIPS=4)
    pat.h3_topk_mode = static_cast<uint8_t>(idx & 1);
    pat.h3_shared_en = static_cast<uint8_t>((idx % 5 == 0) ? 0u : 1u);
    pat.h3_token_id  = static_cast<uint8_t>(idx & 0xFFu);
    pat.h3_act_mxfp4 = static_cast<uint32_t>(xorshift64(rng));
    pat.h3_act_e8m0  = static_cast<uint8_t>(120 + (xorshift64(rng) % 16));

    int16_t exp_score[16];
    for (int e = 0; e < 16; ++e) {
        int16_t dot_sum = 0;
        for (int d = 0; d < 8; ++d) {
            uint8_t wc = static_cast<uint8_t>((e * 3 + d + 1) & 7);
            uint8_t xc = static_cast<uint8_t>((pat.h3_act_mxfp4 >> (d * 4)) & 0xFu);
            dot_sum = static_cast<int16_t>(dot_sum + decode_e2m1_int2x_ref(wc) * decode_e2m1_int2x_ref(xc));
        }
        uint8_t we8 = static_cast<uint8_t>(127 + (e & 7));
        uint8_t sc_sh = ((we8 & 7u) ^ ((we8 >> 3) & 7u) ^ ((we8 >> 6) & 3u) ^
                         (pat.h3_act_e8m0 & 7u) ^ ((pat.h3_act_e8m0 >> 3) & 7u) ^ ((pat.h3_act_e8m0 >> 6) & 3u) ^
                         (pat.h3_token_id & 7u) ^ ((pat.h3_token_id >> 3) & 7u) ^ ((pat.h3_token_id >> 6) & 3u)) & 7u;
        exp_score[e] = static_cast<int16_t>(dot_sum + sc_sh);
    }

    uint16_t picked_mask = 0u;
    uint8_t  top_id[4];
    int16_t  top_sc[4];
    uint8_t  top_dst[4];
    for (int k = 0; k < 4; ++k) {
        uint8_t best_idx = static_cast<uint8_t>(k);
        int16_t best_val = -32768;
        bool found = false;
        for (int e = 0; e < 16; ++e) {
            if (!((picked_mask >> e) & 1u)) {
                if (!found || exp_score[e] > best_val) {
                    best_idx = static_cast<uint8_t>(e);
                    best_val = exp_score[e];
                    found    = true;
                }
            }
        }
        top_id[k]  = best_idx;
        top_sc[k]  = best_val;
        top_dst[k] = best_idx & 3u;
        picked_mask |= static_cast<uint16_t>(1u << best_idx);
    }

    uint16_t mag_sum = 0u;
    uint16_t pos_mag[4];
    for (int k = 0; k < 4; ++k) {
        bool act_k = (k < 2) || (pat.h3_topk_mode != 0);
        if (act_k) {
            pos_mag[k] = (top_sc[k] > 0) ? static_cast<uint16_t>(top_sc[k] + 16) : 16u;
        } else {
            pos_mag[k] = 0u;
        }
        mag_sum = static_cast<uint16_t>(mag_sum + pos_mag[k]);
    }

    pat.exp_h3_sel_ids   = 0u;
    pat.exp_h3_dst_chips = 0u;
    pat.exp_h3_weights   = 0ULL;
    pat.exp_h3_scores    = 0ULL;
    for (int k = 0; k < 4; ++k) {
        uint16_t w_q88 = 0u;
        if ((k < 2) || (pat.h3_topk_mode != 0)) {
            uint8_t nsh = ((mag_sum >> 8) != 0u) ? 4u : (((mag_sum >> 6) != 0u) ? 6u : 7u);
            w_q88 = static_cast<uint16_t>((static_cast<uint32_t>(pos_mag[k]) << nsh) >> 4);
        }
        pat.exp_h3_sel_ids   |= static_cast<uint16_t>((top_id[k] & 0xFu) << (k * 4));
        pat.exp_h3_dst_chips |= static_cast<uint32_t>((top_dst[k] & 0x1Fu) << (k * 5));
        pat.exp_h3_weights   |= (static_cast<uint64_t>(w_q88) << (k * 16));
        pat.exp_h3_scores    |= (static_cast<uint64_t>(static_cast<uint16_t>(top_sc[k])) << (k * 16));
    }

    uint16_t amask = static_cast<uint16_t>((1u << top_id[0]) | (1u << top_id[1]));
    if (pat.h3_topk_mode) amask |= static_cast<uint16_t>((1u << top_id[2]) | (1u << top_id[3]));
    pat.exp_h3_act_mask = amask;
    pat.exp_h3_cg_mask  = static_cast<uint16_t>(~amask);
}

static inline void tick(Vtaalas_stage20_soak_top* dut, uint64_t& sim_cycles) {
    dut->clk = 0;
    dut->eval();
    dut->clk = 1;
    dut->eval();
    sim_cycles++;
}

} // namespace

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    uint64_t target_cycles = 50000000ULL;
    const char* out_json_arg = nullptr;
    for (int i = 1; i + 1 < argc; ++i) {
        if (std::strcmp(argv[i], "--cycles") == 0) {
            target_cycles = std::strtoull(argv[i + 1], nullptr, 10);
        } else if (std::strcmp(argv[i], "--out") == 0) {
            out_json_arg = argv[i + 1];
        }
    }
    const char* out_json = out_json_arg ? out_json_arg
        : ((target_cycles >= 50000000ULL) ? "results/stage20f_50m_cycle_soak.json"
                                          : "results/stage20_10m_cycle_soak.json");
    auto* dut = new Vtaalas_stage20_soak_top;

    auto t_start = std::chrono::high_resolution_clock::now();
    uint64_t sim_cycles = 0;
    uint64_t rng_state  = 0x5441414C41533230ULL;

    // 1. Reset and Initialize All Inputs
    dut->clk               = 0;
    dut->rst_n             = 0;
    dut->m05_bank_cg_en_i  = 0xFFFFu;
    dut->m12_loc_rx_ready_i = 1;
    dut->m12_out_ready_i   = 1;
    dut->m12_c2c_tx_ready_i = 1;
    dut->m18_canary_taps_i = 0xFFu;
    dut->m18_mac_active_lanes_i = 32u;

    for (int i = 0; i < 4; ++i) tick(dut, sim_cycles);
    dut->rst_n = 1;
    dut->eval();

    // 2. Program M07 LoRA SRAM Overlay Weights (lora_a[8][16], lora_b[8][8])
    int8_t lora_a[8][16];
    int8_t lora_b[8][8];
    for (int r = 0; r < 8; ++r) {
        uint64_t w_lo = 0ULL, w_hi = 0ULL;
        for (int i = 0; i < 16; ++i) {
            lora_a[r][i] = static_cast<int8_t>((static_cast<int>(xorshift64(rng_state) & 0x3Fu)) - 32);
            uint64_t b8  = static_cast<uint8_t>(lora_a[r][i]);
            if (i < 8) w_lo |= (b8 << (i * 8));
            else       w_hi |= (b8 << ((i - 8) * 8));
        }
        dut->m07_sram_we_i       = 1;
        dut->m07_sram_sel_b_i    = 0;
        dut->m07_sram_row_addr_i = static_cast<uint8_t>(r);
        dut->m07_sram_wdata_lo_i = w_lo;
        dut->m07_sram_wdata_hi_i = w_hi;
        tick(dut, sim_cycles);
    }
    for (int j = 0; j < 8; ++j) {
        uint64_t w_lo = 0ULL;
        for (int r = 0; r < 8; ++r) {
            lora_b[j][r] = static_cast<int8_t>((static_cast<int>(xorshift64(rng_state) & 0x3Fu)) - 32);
            uint64_t b8  = static_cast<uint8_t>(lora_b[j][r]);
            w_lo |= (b8 << (r * 8));
        }
        dut->m07_sram_we_i       = 1;
        dut->m07_sram_sel_b_i    = 1;
        dut->m07_sram_row_addr_i = static_cast<uint8_t>(j);
        dut->m07_sram_wdata_lo_i = w_lo;
        dut->m07_sram_wdata_hi_i = 0ULL;
        tick(dut, sim_cycles);
    }
    dut->m07_sram_we_i = 0;

    // 3. Pre-compute Expected CRC-16-CCITT for M18 256-Word Via-ROM BIST
    uint16_t exp_bist_crc16 = 0xFFFFu;
    for (int a = 0; a < 256; ++a) {
        uint64_t rom_word = 0x5441414C41530000ULL | static_cast<uint64_t>(a);
        exp_bist_crc16 = crc16_ccitt_step64_ref(exp_bist_crc16, rom_word);
    }
    dut->m18_expected_crc16_i = exp_bist_crc16;

    // 4. Pre-compute 4,096 Rich Constrained-Random & Corner-Case Soak Waves
    constexpr int NUM_PATTERNS = 4096;
    std::vector<SoakWavePattern> patterns(NUM_PATTERNS);
    for (int p = 0; p < NUM_PATTERNS; ++p) {
        build_soak_wave_pattern(patterns[p], p, rng_state, lora_a, lora_b);
    }

    // 5. Shadow Memory & Scoreboard Telemetry Counters
    uint64_t shadow_m05_sram[16][64];
    std::memset(shadow_m05_sram, 0, sizeof(shadow_m05_sram));
    std::deque<uint64_t> m12_exp_fifo;
    std::deque<uint64_t> h2_exp_fifo;

    uint64_t m02_txns = 0, m02_zero_ops_total = 0;
    uint64_t m03_txns = 0;
    uint64_t m04_txns = 0, m04_sat_events = 0;
    uint64_t m05_writes = 0, m05_reads = 0, m05_sec_fixed = 0, m05_ded_detected = 0;
    uint64_t m07_txns = 0;
    uint64_t m12_txns_in = 0, m12_txns_out = 0;
    uint64_t m18_seu_injected = 0, m18_dbe_injected = 0, m18_bist_runs = 0, m18_droop_injected = 0;
    uint64_t h2_txns_in = 0, h2_txns_out = 0, h2_err_injected = 0;
    uint64_t h3_txns = 0;
    uint64_t total_mismatches = 0;

    const SoakWavePattern* active_pat = &patterns[0];
    uint8_t  cur_m05_bank = 0, cur_m05_row = 0;
    uint8_t  exp_m05_sec = 0, exp_m05_ded = 0;

    // -------------------------------------------------------------------------
    // 6. Execute Continuous Multi-Engine Hardware Soak Loop (10M / 50M Cycles)
    // -------------------------------------------------------------------------
    for (uint64_t step = 0; sim_cycles < target_cycles; ++step) {
        uint64_t phase   = step & 3ULL;
        uint64_t wave_id = step >> 2;
        bool     active_window = (sim_cycles + 80ULL < target_cycles);

        // Clear single-cycle strobes by default
        dut->m02_valid_i       = 0;
        dut->m03_valid_i       = 0;
        dut->m04_valid_i       = 0;
        dut->m05_req_valid_i   = 0;
        dut->m05_err_inj_en_i  = 0;
        dut->m05_err_inj_lo_i  = 0ULL;
        dut->m05_err_inj_hi_i  = 0u;
        dut->m07_valid_i       = 0;
        dut->m12_in_valid_i    = 0;
        dut->m18_seu_inj_en_i  = 0;
        dut->m18_bist_start_i  = 0;
        dut->h2_tx_flit_valid_i = 0;
        dut->h3_valid_i        = 0;
        dut->m12_dn_credit_ret_i = (dut->m12_inflight_flits_o > 0u) ? 1 : 0;

        if (active_window) {
            if (phase == 0ULL) {
                active_pat = &patterns[(wave_id ^ (xorshift64(rng_state) & 0xFFFULL)) & 4095ULL];

                // Launch M02
                dut->m02_valid_i        = 1;
                dut->m02_zero_skip_en_i = active_pat->m02_zskip;
                dut->m02_act_lo_i       = active_pat->m02_act_lo;
                dut->m02_act_hi_i       = active_pat->m02_act_hi;
                dut->m02_w3b_pat_i      = active_pat->m02_w3b_pat;
                dut->m02_out_pat_i      = active_pat->m02_out_pat;

                // Launch M03
                dut->m03_valid_i        = 1;
                dut->m03_act_mxfp4_i    = active_pat->m03_act_mxfp4;
                dut->m03_act_e8m0_i     = active_pat->m03_act_e8m0;
                dut->m03_w_mxfp4_base_i = active_pat->m03_w_base;
                dut->m03_w_e8m0_i       = active_pat->m03_w_e8m0;

                // Launch M04
                dut->m04_valid_i          = 1;
                dut->m04_first_group_i    = 1;
                dut->m04_last_group_i     = 1;
                dut->m04_lora_en_i        = active_pat->m04_lora_en;
                dut->m04_raw_acc_ch0_i    = active_pat->m04_raw_acc_ch0;
                dut->m04_act_sum_i        = static_cast<uint16_t>(active_pat->m04_act_sum);
                dut->m04_w_scale_ch0_i    = static_cast<uint16_t>(active_pat->m04_w_scale_ch0);
                dut->m04_act_scale_i      = static_cast<uint16_t>(active_pat->m04_act_scale);
                dut->m04_w_zp_ch0_i       = static_cast<uint8_t>(active_pat->m04_w_zp_ch0);
                dut->m04_lora_delta_ch0_i = static_cast<uint16_t>(active_pat->m04_lora_delta_ch0);

                // Launch M07
                dut->m07_valid_i       = 1;
                dut->m07_lora_en_i     = active_pat->m07_lora_en;
                dut->m07_active_rank_i = active_pat->m07_active_rank;
                dut->m07_alpha_q88_i   = static_cast<uint16_t>(active_pat->m07_alpha_q88);
                dut->m07_skew_delay_i  = active_pat->m07_skew_delay;
                dut->m07_act_lo_i      = active_pat->m07_act_lo;
                dut->m07_act_hi_i      = active_pat->m07_act_hi;

                // Launch H3
                dut->h3_valid_i            = 1;
                dut->h3_topk_mode_i        = active_pat->h3_topk_mode;
                dut->h3_shared_expert_en_i = active_pat->h3_shared_en;
                dut->h3_token_id_i         = active_pat->h3_token_id;
                dut->h3_act_mxfp4_i        = active_pat->h3_act_mxfp4;
                dut->h3_act_e8m0_i         = active_pat->h3_act_e8m0;

                // Launch M05 Write
                cur_m05_bank = static_cast<uint8_t>(wave_id & 15ULL);
                cur_m05_row  = static_cast<uint8_t>((wave_id >> 4) & 63ULL);
                uint64_t wdat = xorshift64(rng_state);
                shadow_m05_sram[cur_m05_bank][cur_m05_row] = wdat;
                dut->m05_req_valid_i = 1;
                dut->m05_req_we_i    = 1;
                dut->m05_req_bank_i  = cur_m05_bank;
                dut->m05_req_row_i   = cur_m05_row;
                dut->m05_req_wdata_i = wdat;
                dut->m05_req_wmask_i = 0xFFu;
                m05_writes++;

                // Launch M12 Flit
                if (dut->m12_in_ready_o && dut->m12_avail_credits_o > 0u) {
                    dut->m12_in_valid_i  = 1;
                    dut->m12_in_hdr_i    = make_noc_hdr(8u, static_cast<uint8_t>(wave_id & 3ULL), 0u, 3u, static_cast<uint8_t>(wave_id & 7ULL));
                    dut->m12_in_pay_lo_i = wdat;
                    m12_exp_fifo.push_back(wdat);
                    m12_txns_in++;
                }

                // Launch H2 C2C LLR Flit
                if (dut->h2_tx_flit_ready_o && dut->h2_unacked_cnt_o == 0u) {
                    uint64_t c2c_dat = wdat ^ 0xA5A55A5A0F0FF0F0ULL;
                    dut->h2_tx_flit_valid_i = 1;
                    dut->h2_tx_flit_data_i  = c2c_dat;
                    h2_exp_fifo.push_back(c2c_dat);
                    h2_txns_in++;
                }
            } else if (phase == 1ULL) {
                // Launch M05 Read with Periodic SBE/DBE Injection
                dut->m05_req_valid_i = 1;
                dut->m05_req_we_i    = 0;
                dut->m05_req_bank_i  = cur_m05_bank;
                dut->m05_req_row_i   = cur_m05_row;
                if ((wave_id & 31ULL) == 7ULL) {
                    int b = static_cast<int>(wave_id % 72ULL);
                    dut->m05_err_inj_en_i = 1;
                    dut->m05_err_inj_lo_i = (b < 64) ? (1ULL << b) : 0ULL;
                    dut->m05_err_inj_hi_i = (b >= 64) ? static_cast<uint8_t>(1u << (b - 64)) : 0u;
                    exp_m05_sec = 1u; exp_m05_ded = 0u;
                } else if ((wave_id & 127ULL) == 31ULL) {
                    int b1 = static_cast<int>(wave_id % 64ULL);
                    int b2 = (b1 + 13) % 64;
                    dut->m05_err_inj_en_i = 1;
                    dut->m05_err_inj_lo_i = (1ULL << b1) | (1ULL << b2);
                    dut->m05_err_inj_hi_i = 0u;
                    exp_m05_sec = 0u; exp_m05_ded = 1u;
                } else {
                    exp_m05_sec = 0u; exp_m05_ded = 0u;
                }
            }
        }

        if (active_window && phase == 2ULL) {
            dut->h2_link_err_inj_i = ((wave_id & 31ULL) == 15ULL) ? 1 : 0;
            if (dut->h2_link_err_inj_i) h2_err_injected++;
        } else {
            dut->h2_link_err_inj_i = 0;
        }

        if (active_window && phase == 3ULL) {
            // M18 Cosmic-Ray SEU / MBU Injection, Periodic Via-ROM BIST & Droop
            if ((wave_id & 511ULL) == 100ULL && (sim_cycles + 20000ULL < target_cycles)) {
                int b = static_cast<int>(wave_id % 72ULL);
                dut->m18_seu_inj_en_i      = 1;
                dut->m18_seu_inj_bank_i    = static_cast<uint8_t>((wave_id >> 9) & 15ULL);
                dut->m18_seu_inj_addr_i    = static_cast<uint8_t>((wave_id >> 13) & 63ULL);
                dut->m18_seu_inj_mask_lo_i = (b < 64) ? (1ULL << b) : 0ULL;
                dut->m18_seu_inj_mask_hi_i = (b >= 64) ? static_cast<uint8_t>(1u << (b - 64)) : 0u;
                m18_seu_injected++;
            } else if (wave_id >= 2000ULL && wave_id <= 16000ULL && (wave_id % 2000ULL) == 0ULL) {
                uint8_t dbe_idx = static_cast<uint8_t>((wave_id / 2000ULL) - 1ULL);
                dut->m18_seu_inj_en_i      = 1;
                dut->m18_seu_inj_bank_i    = dbe_idx & 15u;
                dut->m18_seu_inj_addr_i    = static_cast<uint8_t>(dbe_idx * 7u);
                dut->m18_seu_inj_mask_lo_i = 0x3ULL << (dbe_idx * 4u);
                dut->m18_seu_inj_mask_hi_i = 0u;
                m18_dbe_injected++;
            }
            if ((wave_id % 50000ULL) == 200ULL) {
                dut->m18_bist_start_i = 1;
                m18_bist_runs++;
            }
            if ((wave_id % 10000ULL) == 500ULL) {
                dut->m18_canary_taps_i = 0x1Fu;
                m18_droop_injected++;
            } else {
                dut->m18_canary_taps_i = 0xFFu;
            }
        } else {
            dut->m18_canary_taps_i = 0xFFu;
        }

        // Negative clock edge & M12 combinational egress handshake sampling
        dut->clk = 0;
        dut->eval();
        if (dut->m12_out_valid_o && dut->m12_out_ready_i) {
            m12_txns_out++;
            if (m12_exp_fifo.empty() || dut->m12_out_pay_lo_o != m12_exp_fifo.front()) {
                total_mismatches++;
            }
            if (!m12_exp_fifo.empty()) m12_exp_fifo.pop_front();
        }

        // Positive clock edge
        dut->clk = 1;
        dut->eval();
        sim_cycles++;

        // Cycle-Accurate Scoreboard Checks Across All 9 Engines
        if ((dut->m12_avail_credits_o + dut->m12_inflight_flits_o) != 8u || dut->m12_crc_err_o != 0u) {
            total_mismatches++;
        }
        if (dut->m07_stall_cycles_o != 0u) {
            total_mismatches++;
        }
        if (dut->m02_valid_o) {
            m02_txns++;
            m02_zero_ops_total += dut->m02_zero_ops_saved_o;
            if (static_cast<int16_t>(dut->m02_act_sum_o) != active_pat->exp_m02_act_sum ||
                dut->m02_zero_ops_saved_o != active_pat->exp_m02_zero_ops ||
                dut->m02_acc_lo_o != active_pat->exp_m02_acc_lo ||
                dut->m02_acc_mid_o != active_pat->exp_m02_acc_mid ||
                dut->m02_acc_hi_o != active_pat->exp_m02_acc_hi) {
                total_mismatches++;
            }
        }
        if (dut->m03_valid_o) {
            m03_txns++;
            if (dut->m03_dot_int16_o != active_pat->exp_m03_dot_int16 ||
                dut->m03_exp_comb_o != active_pat->exp_m03_exp_comb ||
                dut->m03_fp32_lo_o != active_pat->exp_m03_fp32_lo ||
                dut->m03_fp32_hi_o != active_pat->exp_m03_fp32_hi) {
                total_mismatches++;
            }
        }
        if (dut->m04_valid_o) {
            m04_txns++;
            if (dut->m04_sat_flag_o) m04_sat_events++;
            if (dut->m04_dequant_lo_o != active_pat->exp_m04_deq_lo ||
                dut->m04_dequant_hi_o != active_pat->exp_m04_deq_hi ||
                dut->m04_sat_flag_o != active_pat->exp_m04_sat) {
                total_mismatches++;
            }
        }
        if (dut->m05_resp_valid_o) {
            m05_reads++;
            if (dut->m05_sec_err_o) m05_sec_fixed++;
            if (dut->m05_ded_err_o) m05_ded_detected++;
            uint8_t exp_pbank = swizzle_gf16_bank_ref(cur_m05_bank, cur_m05_row);
            if (dut->m05_sec_err_o != exp_m05_sec ||
                dut->m05_ded_err_o != exp_m05_ded ||
                dut->m05_phys_bank_o != exp_pbank ||
                (!exp_m05_ded && dut->m05_resp_rdata_o != shadow_m05_sram[cur_m05_bank][cur_m05_row])) {
                total_mismatches++;
            }
        }
        if (dut->m07_valid_o) {
            m07_txns++;
            if (dut->m07_lora_delta_lo_o != active_pat->exp_m07_delta_lo ||
                dut->m07_lora_delta_hi_o != active_pat->exp_m07_delta_hi) {
                total_mismatches++;
            }
        }
        if (dut->h2_rx_flit_valid_o) {
            h2_txns_out++;
            if (h2_exp_fifo.empty() || dut->h2_rx_flit_data_o != h2_exp_fifo.front()) {
                total_mismatches++;
            }
            if (!h2_exp_fifo.empty()) h2_exp_fifo.pop_front();
        }
        if (dut->h3_valid_o) {
            h3_txns++;
            if (dut->h3_sel_expert_id_o != active_pat->exp_h3_sel_ids ||
                dut->h3_dst_chip_id_o != active_pat->exp_h3_dst_chips ||
                dut->h3_gate_weight_q88_o != active_pat->exp_h3_weights ||
                dut->h3_sel_expert_score_o != active_pat->exp_h3_scores ||
                dut->h3_active_expert_mask_o != active_pat->exp_h3_act_mask ||
                dut->h3_clock_gated_expert_mask_o != active_pat->exp_h3_cg_mask) {
                total_mismatches++;
            }
        }
    }

    // Verify post-soak queue & scrubber healing invariants
    if (!m12_exp_fifo.empty() || !h2_exp_fifo.empty()) {
        total_mismatches++;
    }
    if (dut->m18_sbe_scrubbed_cnt_o != m18_seu_injected ||
        dut->m18_spare_rows_used_o != 8u ||
        dut->m18_bist_done_o != 1u ||
        dut->m18_bist_pass_o != 1u ||
        dut->m18_bist_crc16_o != exp_bist_crc16 ||
        dut->m18_droop_event_cnt_o != m18_droop_injected) {
        total_mismatches++;
    }

    auto t_end = std::chrono::high_resolution_clock::now();
    double wall_sec = std::chrono::duration<double>(t_end - t_start).count();
    double sim_khz  = (static_cast<double>(sim_cycles) / 1000.0) / wall_sec;

    uint64_t total_txns = m02_txns + m03_txns + m04_txns + m05_writes + m05_reads +
                          m07_txns + m12_txns_out + m18_seu_injected + m18_dbe_injected +
                          m18_bist_runs + h2_txns_out + h3_txns;

    std::cout << "=============================================================================\n"
              << " TAALAS HC1/HC2 STAGE 20F — " << sim_cycles << "-CYCLE HARDWARE SOAK SUMMARY\n"
              << "=============================================================================\n"
              << " Total Simulated Clock Cycles : " << sim_cycles << "\n"
              << " Total Verified Transactions  : " << total_txns << "\n"
              << " Wall-Clock Execution Time    : " << std::fixed << std::setprecision(2) << wall_sec << " s ("
              << sim_khz << " kHz)\n"
              << " M02 3b/6b CSD MAC Txns       : " << m02_txns << " (Zero-Ops Saved: " << m02_zero_ops_total << ")\n"
              << " M03 HC2 MXFP4 MAC Txns       : " << m03_txns << "\n"
              << " M04 Group Dequant+LoRA Txns  : " << m04_txns << " (Sat Events: " << m04_sat_events << ")\n"
              << " M05 16-Bank 6T SRAM Ops      : " << (m05_writes + m05_reads)
              << " (SEC Fixed: " << m05_sec_fixed << ", DED Det: " << m05_ded_detected << ")\n"
              << " M07 Zero-Stall LoRA Txns     : " << m07_txns << " (Stall Cycles: " << dut->m07_stall_cycles_o << ")\n"
              << " M12 Wormhole NoC Flits       : " << m12_txns_out << " (Avail Credits: " << (int)dut->m12_avail_credits_o << "/8)\n"
              << " M18 Cosmic-Ray SBE Scrubbed  : " << dut->m18_sbe_scrubbed_cnt_o << " / " << m18_seu_injected
              << " (CAM Rows: " << (int)dut->m18_spare_rows_used_o << "/8, Droop: " << dut->m18_droop_event_cnt_o << ")\n"
              << " H2  112G C2C LLR Delivered   : " << h2_txns_out << " / " << h2_txns_in
              << " (Error Storms Injected: " << h2_err_injected << ")\n"
              << " H3  MoE Top-K Routed Tokens  : " << h3_txns
              << " (Gated Expert Cycles: " << dut->h3_cum_gated_expert_cycles_o << ")\n"
              << " Total Scoreboard Mismatches  : " << total_mismatches << "\n"
              << " Overall Soak Status          : " << (total_mismatches == 0 ? "PASS" : "FAIL") << "\n"
              << "=============================================================================\n";

    std::ofstream jf(out_json);
    if (jf.is_open()) {
        jf << "{\n"
           << "  \"stage\": \"" << (target_cycles >= 50000000ULL
                ? "Stage 20F — 50,000,000-Cycle Continuous Ultra-Soak Hardware Regression"
                : "Stage 20C — 10,000,000-Cycle Continuous Hardware Soak Regression") << "\",\n"
           << "  \"total_clock_cycles\": " << sim_cycles << ",\n"
           << "  \"total_verified_transactions\": " << total_txns << ",\n"
           << "  \"wall_clock_seconds\": " << std::fixed << std::setprecision(3) << wall_sec << ",\n"
           << "  \"simulation_speed_khz\": " << std::fixed << std::setprecision(1) << sim_khz << ",\n"
           << "  \"m02_csd_mac_txns\": " << m02_txns << ",\n"
           << "  \"m02_zero_ops_saved\": " << m02_zero_ops_total << ",\n"
           << "  \"m03_mxfp4_mac_txns\": " << m03_txns << ",\n"
           << "  \"m04_dequant_lora_txns\": " << m04_txns << ",\n"
           << "  \"m04_saturation_events\": " << m04_sat_events << ",\n"
           << "  \"m05_sram_writes\": " << m05_writes << ",\n"
           << "  \"m05_sram_reads\": " << m05_reads << ",\n"
           << "  \"m05_sec_errors_corrected\": " << m05_sec_fixed << ",\n"
           << "  \"m05_ded_errors_detected\": " << m05_ded_detected << ",\n"
           << "  \"m07_lora_overlay_txns\": " << m07_txns << ",\n"
           << "  \"m07_pipeline_stall_cycles\": " << dut->m07_stall_cycles_o << ",\n"
           << "  \"m12_noc_flits_routed\": " << m12_txns_out << ",\n"
           << "  \"m12_final_avail_credits\": " << (int)dut->m12_avail_credits_o << ",\n"
           << "  \"m12_final_inflight_flits\": " << (int)dut->m12_inflight_flits_o << ",\n"
           << "  \"m18_sbe_injected\": " << m18_seu_injected << ",\n"
           << "  \"m18_sbe_scrubbed\": " << dut->m18_sbe_scrubbed_cnt_o << ",\n"
           << "  \"m18_dbe_injected\": " << m18_dbe_injected << ",\n"
           << "  \"m18_cam_spare_rows_used\": " << (int)dut->m18_spare_rows_used_o << ",\n"
           << "  \"m18_rom_bist_runs\": " << m18_bist_runs << ",\n"
           << "  \"m18_rom_bist_crc16\": \"0x" << std::hex << std::uppercase << dut->m18_bist_crc16_o << std::dec << "\",\n"
           << "  \"m18_droop_stretch_events\": " << dut->m18_droop_event_cnt_o << ",\n"
           << "  \"h2_c2c_flits_delivered\": " << h2_txns_out << ",\n"
           << "  \"h2_c2c_link_errors_injected\": " << h2_err_injected << ",\n"
           << "  \"h3_moe_topk_routed_tokens\": " << h3_txns << ",\n"
           << "  \"h3_cum_gated_expert_cycles\": " << dut->h3_cum_gated_expert_cycles_o << ",\n"
           << "  \"total_scoreboard_mismatches\": " << total_mismatches << ",\n"
           << "  \"overall_status\": \"" << (total_mismatches == 0 ? "PASS" : "FAIL") << "\"\n"
           << "}\n";
    }

    delete dut;
    return (total_mismatches == 0) ? 0 : 1;
}
