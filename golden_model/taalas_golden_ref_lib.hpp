#ifndef TAALAS_GOLDEN_REF_LIB_HPP
#define TAALAS_GOLDEN_REF_LIB_HPP

#include <cstdint>
#include <algorithm>

namespace taalas_golden {

inline int64_t clamp_s(int64_t val, int bits) {
    int64_t lo = -(1LL << (bits - 1));
    int64_t hi = (1LL << (bits - 1)) - 1;
    return std::max(lo, std::min(hi, val));
}

inline int64_t rne_shift_right(int64_t val, int shift, bool rne_en) {
    int64_t half = 1LL << (shift - 1);
    int64_t mask = (1LL << shift) - 1;
    int64_t frac = val & mask;
    int64_t lsb  = (val >> shift) & 1LL;
    int64_t rnd  = (rne_en && (frac == half)) ? (val + (lsb ? half : 0)) : (val + half);
    return rnd >> shift;
}

// M01: 4-bit sign-magnitude outlier nibble -> 6-bit 2's complement (AUDIT-FINDING-001)
inline int8_t ref_m01_outlier_4b_to_6b(uint8_t nib4) {
    int8_t mag = nib4 & 0x7;
    if (mag == 0) return 0;
    int8_t val = (nib4 & 0x8) ? -(mag << 2) : (mag << 2);
    return static_cast<int8_t>(clamp_s(val, 6));
}

// M02: 3b CSD + 6b Outlier MAC with 20-bit signed outlier sum (AUDIT-FINDING-007)
inline int32_t ref_m02_mac_channel(
    const int8_t* act, const int8_t* w3, int vec_len,
    const int8_t* w6, const uint8_t* idx6, int num_outliers,
    bool zskip_en, bool zskip_out_en, uint16_t& zskip_cnt_out
) {
    int64_t base_sum = 0;
    uint16_t zcnt = 0;
    for (int i = 0; i < vec_len; ++i) {
        if (zskip_en && (w3[i] == 0 || act[i] == 0)) {
            zcnt++;
        } else {
            base_sum += static_cast<int64_t>(w3[i]) * static_cast<int64_t>(act[i]);
        }
    }
    int64_t out_sum = 0;
    for (int k = 0; k < num_outliers; ++k) {
        uint8_t eff_idx = (zskip_en && w6[k] == 0) ? 0 : (idx6[k] % vec_len);
        int8_t xsel = act[eff_idx];
        if (zskip_en && (w6[k] == 0 || xsel == 0)) {
            if (zskip_out_en) zcnt++;
        } else {
            out_sum += static_cast<int64_t>(w6[k]) * static_cast<int64_t>(xsel);
        }
    }
    out_sum = clamp_s(out_sum, 20);
    zskip_cnt_out = zcnt;
    return static_cast<int32_t>(clamp_s(base_sum + out_sum, 24));
}

// M03 & H3: OCP MXFP4 E8M0=0xFF NaN check & E2M1 integer dot product (AUDIT-FINDING-002/006)
inline bool ref_m03_h3_is_nan(uint8_t exp_a, uint8_t exp_w) {
    return (exp_a == 0xFF) || (exp_w == 0xFF);
}

// M04: Group Dequant with Wide 28-bit ZP & IEEE-754 RNE (AUDIT-FINDING-008)
inline int16_t ref_m04_dequant_elem(
    int32_t raw_acc, int16_t act_sum, int8_t w_zp, int16_t w_scale, int16_t act_scale,
    int16_t lora_delta, bool lora_en, bool wide_zp_en, bool rne_en, bool& sat_out
) {
    int64_t zp_diff = static_cast<int64_t>(raw_acc) - static_cast<int64_t>(w_zp) * static_cast<int64_t>(act_sum);
    int64_t zp_comp = wide_zp_en ? clamp_s(zp_diff, 28) : clamp_s(zp_diff, 24);
    int64_t comb_sc = static_cast<int64_t>(w_scale) * static_cast<int64_t>(act_scale);
    int64_t prod56  = zp_comp * comb_sc;
    int64_t shifted = rne_shift_right(prod56, 16, rne_en);
    int64_t fused   = shifted + (lora_en ? static_cast<int64_t>(lora_delta) : 0);
    sat_out = (fused > 32767) || (fused < -32768);
    return static_cast<int16_t>(clamp_s(fused, 16));
}

// M10: RMSNorm scale with 24-bit x_norm_q8 preventing sign-wrap (AUDIT-FINDING-010)
inline int16_t ref_m10_rmsnorm_elem(int16_t x_rep, uint16_t inv_rms_q8_8, int16_t gamma_q8_8) {
    int64_t x_norm_q16 = static_cast<int64_t>(x_rep) * static_cast<int64_t>(inv_rms_q8_8);
    int64_t x_norm_q8  = clamp_s((x_norm_q16 + 128) >> 8, 24);
    int64_t y_prod_q16 = x_norm_q8 * static_cast<int64_t>(gamma_q8_8);
    int64_t y_shifted  = (y_prod_q16 + 128) >> 8;
    return static_cast<int16_t>(clamp_s(y_shifted, 16));
}

// M11: SwiGLU Hadamard & INT8 Quant with optional RNE (AUDIT-FINDING-011)
inline void ref_m11_hadamard_quant(int16_t silu_q8_8, int16_t up_q8_8, bool rne_en, int16_t& had_o, int8_t& q8_o) {
    int64_t prod = static_cast<int64_t>(silu_q8_8) * static_cast<int64_t>(up_q8_8);
    had_o = static_cast<int16_t>(clamp_s(rne_shift_right(prod, 8, rne_en), 16));
    q8_o  = static_cast<int8_t>(clamp_s(rne_shift_right(had_o, 8, rne_en), 8));
}

// H2: Modulo-256 cumulative sequence-window ACK advance (AUDIT-FINDING-013)
inline uint8_t ref_h2_ack_advance(uint8_t head_seq, uint8_t ack_seq, uint8_t unacked_cnt) {
    if (unacked_cnt == 0) return 0;
    uint8_t delta = static_cast<uint8_t>(ack_seq - head_seq);
    return (delta < unacked_cnt) ? static_cast<uint8_t>(delta + 1) : 0;
}

} // namespace taalas_golden

#endif // TAALAS_GOLDEN_REF_LIB_HPP
