// =============================================================================
// File:        uvm_tb/tb_stage18_fault_resilience.cpp
// Project:     Taalas HC1/HC2 Autonomous Hardware Engineering Marathon
// Stage:       Stage 18 — 1,000,000-Cycle Cosmic-Ray SEU/MBU Fault-Injection,
//              8-Entry CAM Spare-Row Repair, Via-ROM CRC-16 BIST & L*di/dt
//              Voltage-Droop Clock-Stretch UVM Verification Campaign
// =============================================================================

#include <iostream>
#include <fstream>
#include <iomanip>
#include <vector>
#include <cstdint>
#include <chrono>
#include <cassert>
#include "Vtaalas_ecc_bist_scrubber.h"
#include "verilated.h"

namespace {

static inline uint8_t get_syndrome_col_ref(uint8_t bit_idx) {
    if (bit_idx == 0)       return 3;
    else if (bit_idx <= 3)  return bit_idx + 4;
    else if (bit_idx <= 10) return bit_idx + 5;
    else if (bit_idx <= 25) return bit_idx + 6;
    else if (bit_idx <= 56) return bit_idx + 7;
    else                    return bit_idx + 8;
}

static inline uint8_t secded_encode_ref(uint64_t d_in) {
    uint8_t p_hamming = 0;
    for (int i = 0; i < 64; ++i) {
        if ((d_in >> i) & 1ULL) {
            p_hamming ^= get_syndrome_col_ref(static_cast<uint8_t>(i));
        }
    }
    uint8_t p_overall = (__builtin_popcountll(d_in) ^ __builtin_popcount(p_hamming)) & 1U;
    return static_cast<uint8_t>((p_overall << 7) | (p_hamming & 0x7FU));
}

static inline uint64_t secded_read_correct_ref(uint64_t data_rx, uint8_t ecc_rx, bool& sbe, bool& dbe) {
    uint8_t ecc_calc    = secded_encode_ref(data_rx);
    uint8_t synd_7b     = (ecc_rx ^ ecc_calc) & 0x7FU;
    uint8_t overall_par = ((ecc_rx >> 7) ^ (ecc_calc >> 7) ^ __builtin_popcount(synd_7b)) & 1U;
    sbe = false;
    dbe = false;
    uint64_t data_corr = data_rx;
    if (overall_par == 1U) {
        sbe = true;
        for (int i = 0; i < 64; ++i) {
            if (synd_7b == get_syndrome_col_ref(static_cast<uint8_t>(i))) {
                data_corr ^= (1ULL << i);
            }
        }
    } else if (synd_7b != 0U) {
        dbe = true;
    }
    return data_corr;
}

static inline uint16_t crc16_ccitt_step64_ref(uint16_t crc_in, uint64_t data_in) {
    uint16_t c = crc_in;
    for (int b = 63; b >= 0; --b) {
        uint16_t fb = ((c >> 15) & 1U) ^ static_cast<uint16_t>((data_in >> b) & 1ULL);
        c = static_cast<uint16_t>((c << 1) ^ (fb ? 0x1021U : 0x0000U));
    }
    return c;
}

struct SramWord72 {
    uint64_t data;
    uint8_t  ecc;
};

static inline void tick(Vtaalas_ecc_bist_scrubber* dut, uint64_t& total_cycles) {
    dut->clk = 0;
    dut->eval();
    dut->clk = 1;
    dut->eval();
    total_cycles++;
}

} // namespace

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    auto* dut = new Vtaalas_ecc_bist_scrubber;

    constexpr int NUM_BANKS  = 32;
    constexpr int BANK_DEPTH = 256;
    constexpr int SRAM_WORDS = NUM_BANKS * BANK_DEPTH; // 8,192 words
    constexpr int ROM_WORDS  = 8192;
    constexpr int SPARE_ROWS = 8;

    auto t_start = std::chrono::high_resolution_clock::now();
    uint64_t total_cycles = 0;

    // Initialize DUT inputs
    dut->clk                 = 0;
    dut->rst_n               = 0;
    dut->active_sram_req_i   = 0;
    dut->active_sram_bank_i  = 0;
    dut->active_sram_addr_i  = 0;
    dut->scrub_sram_rvalid_i = 0;
    dut->scrub_sram_rbank_i  = 0;
    dut->scrub_sram_raddr_i  = 0;
    dut->scrub_sram_rdata_i[0] = 0;
    dut->scrub_sram_rdata_i[1] = 0;
    dut->scrub_sram_rdata_i[2] = 0;
    dut->bist_start_i        = 0;
    dut->bist_rom_data_i     = 0;
    dut->expected_crc16_i    = 0;
    dut->canary_taps_i       = 0xFFU; // Healthy 0.75V (all 8 delay-line taps propagate)
    dut->mac_active_lanes_i  = 32;

    for (int i = 0; i < 5; ++i) tick(dut, total_cycles);
    dut->rst_n = 1;
    dut->eval();

    // -------------------------------------------------------------------------
    // Initialize Golden Via-ROM (8,192 x 64b) & 6T SRAM (32 x 256 x 72b)
    // -------------------------------------------------------------------------
    std::vector<uint64_t> rom_array(ROM_WORDS);
    uint16_t golden_rom_crc16 = 0xFFFFU;
    for (int i = 0; i < ROM_WORDS; ++i) {
        uint64_t w = 0x9E3779B97F4A7C15ULL * static_cast<uint64_t>(i + 1) ^ 0xA55A5AA5C33C3CC3ULL;
        rom_array[i]     = w;
        golden_rom_crc16 = crc16_ccitt_step64_ref(golden_rom_crc16, w);
    }

    std::vector<uint64_t>   golden_sram(SRAM_WORDS);
    std::vector<SramWord72> phys_sram(SRAM_WORDS);
    std::vector<SramWord72> spare_sram(SPARE_ROWS, {0ULL, secded_encode_ref(0ULL)});

    for (int idx = 0; idx < SRAM_WORDS; ++idx) {
        uint64_t val    = 0x6A09E667F3BCC908ULL ^ (static_cast<uint64_t>(idx) * 0xBF58476D1CE4E5B9ULL);
        golden_sram[idx] = val;
        phys_sram[idx]   = {val, secded_encode_ref(val)};
    }

    // =========================================================================
    // PHASE 1: Power-On Via-ROM CRC-16 BIST (Clean Pass + 1-Bit Defect Catch)
    // =========================================================================
    dut->expected_crc16_i = golden_rom_crc16;
    dut->bist_start_i     = 1;
    tick(dut, total_cycles);
    dut->bist_start_i     = 0;

    while (!dut->bist_done_o) {
        uint16_t r_addr      = dut->bist_rom_addr_o;
        dut->bist_rom_data_i = rom_array[r_addr];
        tick(dut, total_cycles);
    }
    bool phase1_clean_bist_pass = (dut->bist_done_o == 1) && (dut->bist_pass_o == 1) &&
                                  (dut->bist_crc16_o == golden_rom_crc16);
    assert(phase1_clean_bist_pass && "Phase 1 Clean Via-ROM CRC-16 BIST failed!");

    // Inject deliberate 1-bit metal-via mask defect at ROM word 4096 bit 37
    rom_array[4096] ^= (1ULL << 37);
    dut->bist_start_i = 1;
    tick(dut, total_cycles);
    dut->bist_start_i = 0;
    while (!dut->bist_done_o) {
        uint16_t r_addr      = dut->bist_rom_addr_o;
        dut->bist_rom_data_i = rom_array[r_addr];
        tick(dut, total_cycles);
    }
    bool phase1_defect_caught = (dut->bist_done_o == 1) && (dut->bist_pass_o == 0) &&
                                (dut->bist_crc16_o != golden_rom_crc16);
    assert(phase1_defect_caught && "Phase 1 1-bit Via-ROM mask defect was not caught!");
    rom_array[4096] ^= (1ULL << 37); // Restore clean ROM

    // =========================================================================
    // PHASE 2: 1,000,000-Cycle Concurrent LLM KV-Cache Traffic (~65% Util) +
    //          5,000 Cosmic-Ray SEU Injections & Zero-Overhead Patrol Scrubbing
    // =========================================================================
    constexpr uint64_t PHASE2_CYCLES = 1000000ULL;
    constexpr uint32_t TARGET_SEUS   = 5000U;
    uint32_t seus_injected           = 0;
    uint64_t active_kv_reads         = 0;
    uint64_t corrupted_kv_reads      = 0;
    uint64_t active_traffic_stalls   = 0;
    uint64_t prng_state              = 0xCAFEBABE12345678ULL;

    auto next_rand = [&]() -> uint64_t {
        prng_state ^= prng_state << 13;
        prng_state ^= prng_state >> 7;
        prng_state ^= prng_state << 17;
        return prng_state;
    };

    bool     pending_scrub_read = false;
    uint8_t  pending_scrub_bank = 0;
    uint8_t  pending_scrub_addr = 0;

    for (uint64_t cyc = 0; cyc < PHASE2_CYCLES; ++cyc) {
        // Inject 5,000 cosmic-ray SEUs across the first 950,000 cycles (1 every 190 cyc)
        if ((cyc < 950000ULL) && ((cyc % 190ULL) == 0ULL) && (seus_injected < TARGET_SEUS)) {
            uint32_t target_idx = static_cast<uint32_t>(next_rand() % SRAM_WORDS);
            // Ensure we pick an uncorrupted cell within the current 23.4k-cycle sweep window
            while (phys_sram[target_idx].data != golden_sram[target_idx] ||
                   phys_sram[target_idx].ecc  != secded_encode_ref(golden_sram[target_idx])) {
                target_idx = (target_idx + 1U) % SRAM_WORDS;
            }
            uint32_t flip_bit = static_cast<uint32_t>(next_rand() % 72U);
            if (flip_bit < 64U) {
                phys_sram[target_idx].data ^= (1ULL << flip_bit);
            } else {
                phys_sram[target_idx].ecc ^= static_cast<uint8_t>(1U << (flip_bit - 64U));
            }
            seus_injected++;
        }

        // Apply atomic write-back from Patrol Scrubber if asserted on previous cycle
        if (dut->scrub_wb_we_o) {
            uint32_t wb_idx = (static_cast<uint32_t>(dut->scrub_wb_bank_o) << 8) |
                              static_cast<uint32_t>(dut->scrub_wb_addr_o);
            uint64_t wb_d = (static_cast<uint64_t>(dut->scrub_wb_data_o[1]) << 32) |
                            static_cast<uint64_t>(dut->scrub_wb_data_o[0]);
            uint8_t  wb_e = static_cast<uint8_t>(dut->scrub_wb_data_o[2] & 0xFFU);
            phys_sram[wb_idx] = {wb_d, wb_e};
        }

        // Present SRAM read data for patrol scrub read issued on previous cycle
        if (pending_scrub_read) {
            uint32_t s_idx = (static_cast<uint32_t>(pending_scrub_bank) << 8) |
                             static_cast<uint32_t>(pending_scrub_addr);
            dut->scrub_sram_rvalid_i   = 1;
            dut->scrub_sram_rbank_i    = pending_scrub_bank;
            dut->scrub_sram_raddr_i    = pending_scrub_addr;
            dut->scrub_sram_rdata_i[0] = static_cast<uint32_t>(phys_sram[s_idx].data & 0xFFFFFFFFULL);
            dut->scrub_sram_rdata_i[1] = static_cast<uint32_t>(phys_sram[s_idx].data >> 32);
            dut->scrub_sram_rdata_i[2] = static_cast<uint32_t>(phys_sram[s_idx].ecc);
        } else {
            dut->scrub_sram_rvalid_i = 0;
        }

        // Generate ~65% active LLM KV-cache read traffic
        bool is_active_req = ((next_rand() % 100ULL) < 65ULL);
        dut->active_sram_req_i = is_active_req ? 1 : 0;
        if (is_active_req) {
            uint32_t act_idx = static_cast<uint32_t>(next_rand() % SRAM_WORDS);
            dut->active_sram_bank_i = static_cast<uint8_t>(act_idx >> 8);
            dut->active_sram_addr_i = static_cast<uint8_t>(act_idx & 0xFFU);
            active_kv_reads++;

            bool sbe_rd = false, dbe_rd = false;
            uint64_t clean_rd = secded_read_correct_ref(
                phys_sram[act_idx].data, phys_sram[act_idx].ecc, sbe_rd, dbe_rd);
            if (clean_rd != golden_sram[act_idx] || dbe_rd) {
                corrupted_kv_reads++;
            }
        }

        dut->eval();
        if (is_active_req && dut->scrub_sram_re_o) {
            active_traffic_stalls++;
        }

        pending_scrub_read = (dut->scrub_sram_re_o == 1);
        pending_scrub_bank = dut->scrub_sram_bank_o;
        pending_scrub_addr = dut->scrub_sram_addr_o;

        tick(dut, total_cycles);
    }

    // Flush final pending write-back if any
    if (dut->scrub_wb_we_o) {
        uint32_t wb_idx = (static_cast<uint32_t>(dut->scrub_wb_bank_o) << 8) |
                          static_cast<uint32_t>(dut->scrub_wb_addr_o);
        uint64_t wb_d = (static_cast<uint64_t>(dut->scrub_wb_data_o[1]) << 32) |
                        static_cast<uint64_t>(dut->scrub_wb_data_o[0]);
        uint8_t  wb_e = static_cast<uint8_t>(dut->scrub_wb_data_o[2] & 0xFFU);
        phys_sram[wb_idx] = {wb_d, wb_e};
    }

    uint32_t residual_sram_errors = 0;
    for (int idx = 0; idx < SRAM_WORDS; ++idx) {
        if (phys_sram[idx].data != golden_sram[idx] ||
            phys_sram[idx].ecc  != secded_encode_ref(golden_sram[idx])) {
            residual_sram_errors++;
        }
    }
    uint32_t phase2_sbe_scrubbed = dut->sbe_scrubbed_cnt_o;
    assert(seus_injected == TARGET_SEUS && "Phase 2 did not inject 5,000 SEUs!");
    assert(phase2_sbe_scrubbed == TARGET_SEUS && "Phase 2 did not scrub 100% of 5,000 SEUs!");
    assert(residual_sram_errors == 0 && "Phase 2 left residual un-healed SRAM errors!");
    assert(corrupted_kv_reads == 0 && "Phase 2 experienced corrupted KV-cache reads!");
    assert(active_traffic_stalls == 0 && "Phase 2 imposed stalls on active LLM traffic!");

    // =========================================================================
    // PHASE 3: Multi-Bit Upset (MBU / DBE) Fault Injection Across 8 Defective
    //          SRAM Rows & 8-Entry CAM Spare-Row Remapping Verification
    // =========================================================================
    dut->active_sram_req_i   = 0;
    dut->scrub_sram_rvalid_i = 0;
    tick(dut, total_cycles);

    const uint32_t defective_rows[SPARE_ROWS] = {
        (0U  << 8) | 17U,  (4U  << 8) | 53U,  (9U  << 8) | 88U,  (13U << 8) | 129U,
        (18U << 8) | 164U, (22U << 8) | 201U, (27U << 8) | 233U, (31U << 8) | 250U
    };

    uint32_t dbe_irqs_caught   = 0;
    uint32_t cam_remaps_issued = 0;

    for (int r = 0; r < SPARE_ROWS; ++r) {
        uint32_t idx  = defective_rows[r];
        uint8_t  bank = static_cast<uint8_t>(idx >> 8);
        uint8_t  addr = static_cast<uint8_t>(idx & 0xFFU);

        // Inject 2-bit MBU (flip bits 11 and 47 in data word)
        uint64_t mbu_data = golden_sram[idx] ^ (1ULL << 11) ^ (1ULL << 47);
        uint8_t  mbu_ecc  = secded_encode_ref(golden_sram[idx]);

        dut->scrub_sram_rvalid_i   = 1;
        dut->scrub_sram_rbank_i    = bank;
        dut->scrub_sram_raddr_i    = addr;
        dut->scrub_sram_rdata_i[0] = static_cast<uint32_t>(mbu_data & 0xFFFFFFFFULL);
        dut->scrub_sram_rdata_i[1] = static_cast<uint32_t>(mbu_data >> 32);
        dut->scrub_sram_rdata_i[2] = static_cast<uint32_t>(mbu_ecc);

        tick(dut, total_cycles);
        dut->scrub_sram_rvalid_i = 0;

        if (dut->uncorrectable_dbe_irq_o) dbe_irqs_caught++;
        if (dut->remap_valid_o) {
            cam_remaps_issued++;
            uint8_t dst_spare = dut->remap_dst_row_o;
            spare_sram[dst_spare] = {golden_sram[idx], secded_encode_ref(golden_sram[idx])};
        }
    }

    // Verify all 8 defective rows now hit the CAM spare-row table during active LLM reads
    uint32_t spare_hits_verified = 0;
    for (int r = 0; r < SPARE_ROWS; ++r) {
        uint32_t idx = defective_rows[r];
        dut->active_sram_req_i  = 1;
        dut->active_sram_bank_i = static_cast<uint8_t>(idx >> 8);
        dut->active_sram_addr_i = static_cast<uint8_t>(idx & 0xFFU);
        dut->eval();
        if (dut->active_hit_spare_o &&
            spare_sram[dut->active_spare_row_o].data == golden_sram[idx]) {
            spare_hits_verified++;
        }
        tick(dut, total_cycles);
    }
    dut->active_sram_req_i = 0;
    assert(dbe_irqs_caught == SPARE_ROWS && "Phase 3 missed DBE interrupt!");
    assert(cam_remaps_issued == SPARE_ROWS && "Phase 3 failed to allocate 8 CAM spare rows!");
    assert(spare_hits_verified == SPARE_ROWS && "Phase 3 CAM spare-row lookup failed!");

    // =========================================================================
    // PHASE 4: 500 Transient L*di/dt Voltage-Droop Events (0.75V -> 0.67V)
    //          Verifying 1-Cycle Clock-Stretch Engagement & 0 Timing Violations
    // =========================================================================
    constexpr uint32_t TARGET_DROOPS = 500U;
    uint32_t droop_events_injected   = 0;
    uint32_t droop_1cyc_verified     = 0;
    uint32_t timing_violations       = 0;

    for (uint32_t d = 0; d < TARGET_DROOPS; ++d) {
        // Inject transient L*di/dt voltage droop (0.75V -> 0.67V => 5 taps 0x1F)
        // alternating with sudden di/dt current jump (32 -> 192 active MAC lanes)
        if ((d & 1U) == 0U) {
            dut->canary_taps_i      = 0x1FU; // < 0.71V threshold (tap[5] == 0)
            dut->mac_active_lanes_i = 64U;
        } else {
            dut->canary_taps_i      = 0x3FU;
            dut->mac_active_lanes_i = 192U;  // +160 lane jump >= DIDT_THRESH(64)
        }
        droop_events_injected++;
        tick(dut, total_cycles);

        // Verify clk_stretch_en_o engages within 1 clock cycle!
        if (dut->clk_stretch_en_o == 1) {
            droop_1cyc_verified++;
        } else {
            timing_violations++;
        }

        // Restore nominal 0.75V (8 taps 0xFF) & let 8-cycle stretch window drain
        dut->canary_taps_i      = 0xFFU;
        dut->mac_active_lanes_i = 32U;
        for (int w = 0; w < 10; ++w) {
            tick(dut, total_cycles);
        }
    }
    assert(droop_1cyc_verified == TARGET_DROOPS && "Phase 4 missed 1-cycle droop clock stretch!");
    assert(timing_violations == 0 && "Phase 4 experienced setup timing violations!");

    auto t_end = std::chrono::high_resolution_clock::now();
    double elapsed_sec = std::chrono::duration<double>(t_end - t_start).count();

    std::cout << "====================================================================\n";
    std::cout << " STAGE 18 SILICON RELIABILITY & FAULT-INJECTION UVM CAMPAIGN PASS\n";
    std::cout << "====================================================================\n";
    std::cout << " Total Simulated Cycles       : " << total_cycles << " ("
              << std::fixed << std::setprecision(3) << elapsed_sec << " s)\n";
    std::cout << " Phase 1 Via-ROM CRC-16 BIST  : Clean PASS (0x" << std::hex << golden_rom_crc16
              << std::dec << "), 1-Bit Mask Defect Caught = YES\n";
    std::cout << " Phase 2 Cosmic-Ray SEUs      : " << phase2_sbe_scrubbed << " / " << TARGET_SEUS
              << " Scrubbed (100.0%), Residual = " << residual_sram_errors << "\n";
    std::cout << " Phase 2 Active KV Traffic    : " << active_kv_reads
              << " Reads, Corrupted = " << corrupted_kv_reads
              << ", Stalls = " << active_traffic_stalls << "\n";
    std::cout << " Phase 3 MBU / DBE Spare Rows : " << dbe_irqs_caught << " / " << SPARE_ROWS
              << " IRQs, " << spare_hits_verified << " / " << SPARE_ROWS << " CAM Repaired\n";
    std::cout << " Phase 4 L*di/dt Droop Events : " << droop_1cyc_verified << " / " << TARGET_DROOPS
              << " 1-Cycle Clock-Stretched, Timing Violations = " << timing_violations << "\n";
    std::cout << "====================================================================\n";

    delete dut;
    return 0;
}
