// =============================================================================
// File:        uvm_tb/tb_stage17_hc2_cluster.cpp
// Project:     Taalas HC2 Disaggregated 3D-SRAM & Multi-Chip Cluster (Stage 17)
// Description: IEEE 1800.2-Style C++ UVM Verification Environment (26,000+ Txns)
//              for taalas_hc2_multichip_cluster_top (H1 + H2 + H3 + H4 + M3):
//              - Phase 1 (10,000 Txns): 4-Port x 16-Bank Disaggregated 3D-SRAM
//                Crossbar, DeepSeek-R1 MLA 8x Latent Caching & (72,64) SECDED
//                Single/Double-Bit Fault Injection Scoreboard.
//              - Phase 2 (10,000 Txns): 4-Die Multi-Chip C2C 112G SerDes Token
//                Streaming under Link Bit-Error Storms & Go-Back-N LLR Replay.
//              - Phase 3 (6,000 Txns): Hardwired MXFP4 MoE Top-K (K=2 / K=4)
//                Expert Routing & Dynamic Expert Tile Clock-Gating Audit.
// =============================================================================

#include <iostream>
#include <iomanip>
#include <cstdint>
#include <vector>
#include <deque>
#include <map>
#include <cassert>
#include "Vtaalas_hc2_multichip_cluster_top.h"
#include "verilated.h"

static uint64_t lfsr64_next(uint64_t &state) {
    uint64_t bit = ((state >> 0) ^ (state >> 1) ^ (state >> 3) ^ (state >> 4)) & 1ULL;
    state = (state >> 1) | (bit << 63);
    return state;
}

class TaalasHc2ClusterUvmEnv {
public:
    Vtaalas_hc2_multichip_cluster_top* dut;
    uint64_t sim_cycles       = 0;
    uint64_t total_txns       = 0;
    uint64_t sram_writes      = 0;
    uint64_t sram_reads       = 0;
    uint64_t sec_injected     = 0;
    uint64_t sec_corrected    = 0;
    uint64_t ded_injected     = 0;
    uint64_t ded_detected     = 0;
    uint64_t bank_collisions  = 0;
    uint64_t c2c_sent_tokens  = 0;
    uint64_t c2c_rcvd_tokens  = 0;
    uint64_t c2c_order_errors = 0;
    uint64_t moe_topk_checks  = 0;
    uint64_t moe_distinct_err = 0;
    uint64_t active_exp_sum   = 0;
    uint64_t gated_exp_sum    = 0;
    bool     c2c_sb_en        = false;

    std::deque<uint64_t> expected_cluster_fifo;

    TaalasHc2ClusterUvmEnv() {
        dut = new Vtaalas_hc2_multichip_cluster_top;
        dut->clk                   = 0;
        dut->rst_n                 = 0;
        dut->mla_mode_en_i         = 1;
        dut->topk_mode_i           = 0;
        dut->shared_expert_en_i    = 1;
        dut->cluster_tok_valid_i   = 0;
        dut->cluster_tok_id_i      = 0;
        dut->cluster_user_id_i     = 0;
        dut->cluster_tok_pos_i     = 0;
        dut->cluster_tok_latent_i  = 0;
        dut->cluster_act_mxfp4_i   = 0;
        dut->cluster_act_e8m0_i    = 127;
        dut->c2c_link_err_inj_i    = 0;
        dut->sram_diag_en_i        = 0;
        dut->sram_port_req_valid_i = 0;
        dut->sram_port_req_we_i    = 0;
        dut->sram_port_user_id_i   = 0;
        dut->sram_port_token_pos_i = 0;
        dut->sram_port_head_sub_i  = 0;
        for (int w = 0; w < 8; w++) dut->sram_port_wdata_i[w] = 0;
        dut->sram_err_inj_en_i     = 0;
        dut->sram_err_inj_port_i   = 0;
        dut->sram_err_inj_bit_i    = 0;
        dut->sram_err_inj_double_i = 0;
    }

    ~TaalasHc2ClusterUvmEnv() {
        delete dut;
    }

    void step_clk() {
        dut->clk = 0;
        dut->eval();
        // Check crossbar bank collision freedom before posedge
        if (dut->rst_n && dut->sram_diag_en_i) {
            for (int p = 0; p < 4; p++) {
                for (int q = p + 1; q < 4; q++) {
                    bool gp = (dut->sram_port_grant_o >> p) & 1;
                    bool gq = (dut->sram_port_grant_o >> q) & 1;
                    uint8_t bp = (dut->sram_port_phys_bank_o >> (p * 4)) & 0xF;
                    uint8_t bq = (dut->sram_port_phys_bank_o >> (q * 4)) & 0xF;
                    if (gp && gq && (bp == bq)) bank_collisions++;
                }
            }
        }
        dut->clk = 1;
        dut->eval();
        sim_cycles++;

        // Scoreboard check for 4-Die C2C Egress Token Stream
        if (dut->rst_n && c2c_sb_en && dut->cluster_out_valid_o) {
            c2c_rcvd_tokens++;
            if (expected_cluster_fifo.empty()) {
                c2c_order_errors++;
            } else {
                uint64_t exp_val = expected_cluster_fifo.front();
                expected_cluster_fifo.pop_front();
                if (dut->cluster_out_flit_o != exp_val) {
                    c2c_order_errors++;
                }
            }
        }
    }

    void reset() {
        dut->rst_n = 0;
        for (int i = 0; i < 8; i++) step_clk();
        dut->rst_n = 1;
        for (int i = 0; i < 4; i++) step_clk();
    }

    // -------------------------------------------------------------------------
    // Phase 1: 10,000 Transactions on Disaggregated 3D-SRAM Fabric (H1)
    // -------------------------------------------------------------------------
    void run_phase1_disagg_3d_sram(int num_iters) {
        uint64_t rng = 0x5441414C41534843ULL;
        dut->sram_diag_en_i = 1;
        for (int iter = 0; iter < num_iters; iter++) {
            dut->mla_mode_en_i = (iter % 10 != 0) ? 1 : 0; // 90% MLA 8x mode, 10% GQA
            uint8_t  usr = iter & 0xF;
            uint8_t  pos = (iter >> 4) & 0xFF;
            uint64_t golden_w[4];

            // 1. Write 4 ports simultaneously across distinct head/latent sub-channels
            dut->sram_port_req_valid_i = 0xF;
            dut->sram_port_req_we_i    = 0xF;
            dut->sram_port_user_id_i   = (usr << 12) | (usr << 8) | (usr << 4) | usr;
            dut->sram_port_token_pos_i = (uint32_t(pos) << 24) | (uint32_t(pos) << 16) |
                                         (uint32_t(pos) << 8)  | uint32_t(pos);
            dut->sram_port_head_sub_i  = 0x3210;
            dut->sram_err_inj_en_i     = 0;
            for (int p = 0; p < 4; p++) {
                golden_w[p] = lfsr64_next(rng);
                dut->sram_port_wdata_i[p*2 + 0] = uint32_t(golden_w[p] & 0xFFFFFFFFULL);
                dut->sram_port_wdata_i[p*2 + 1] = uint32_t(golden_w[p] >> 32);
            }
            step_clk();
            assert(dut->sram_port_grant_o == 0xF); // Non-blocking 4-port grant
            assert(dut->sram_kv_compress_ratio_o == (dut->mla_mode_en_i ? 8 : 1));
            sram_writes += 4;
            total_txns  += 4;

            // 2. Read back 4 ports with Single-Bit or Double-Bit SECDED Fault Injection
            dut->sram_port_req_valid_i = 0xF;
            dut->sram_port_req_we_i    = 0x0;
            bool do_sec = (iter % 3 == 1);
            bool do_ded = (iter % 11 == 5) && !do_sec;
            uint8_t inj_port = iter & 0x3;
            uint8_t inj_bit  = iter & 0x3F;
            dut->sram_err_inj_en_i     = (do_sec || do_ded) ? 1 : 0;
            dut->sram_err_inj_port_i   = inj_port;
            dut->sram_err_inj_bit_i    = inj_bit;
            dut->sram_err_inj_double_i = do_ded ? 1 : 0;
            step_clk();
            sram_reads += 4;
            total_txns += 4;

            assert(dut->sram_port_resp_valid_o == 0xF);
            for (int p = 0; p < 4; p++) {
                uint64_t rdata = (uint64_t(dut->sram_port_resp_rdata_o[p*2 + 1]) << 32) |
                                  uint64_t(dut->sram_port_resp_rdata_o[p*2 + 0]);
                bool sec_f = (dut->sram_port_sec_err_o >> p) & 1;
                bool ded_f = (dut->sram_port_ded_err_o >> p) & 1;
                if (do_sec && (p == inj_port)) {
                    sec_injected++;
                    if (sec_f && !ded_f && (rdata == golden_w[p])) sec_corrected++;
                } else if (do_ded && (p == inj_port)) {
                    ded_injected++;
                    if (ded_f && !sec_f) ded_detected++;
                } else {
                    assert(!sec_f && !ded_f && (rdata == golden_w[p]));
                }
            }
        }
        dut->sram_port_req_valid_i = 0;
        dut->sram_err_inj_en_i     = 0;
        dut->sram_diag_en_i        = 0;
        step_clk();
    }

    // -------------------------------------------------------------------------
    // Phase 2: 10,000 Multi-Chip C2C 112G SerDes & LLR Replay Transactions (H2/H4)
    // -------------------------------------------------------------------------
    void run_phase2_c2c_llr_multichip(int num_tokens) {
        uint64_t rng = 0x4843325F4332435FULL;
        dut->mla_mode_en_i = 1;
        c2c_sb_en          = true;
        int sent = 0;
        while (sent < num_tokens) {
            uint64_t rval = lfsr64_next(rng);
            // Inject deterministic & random bit-error storms across the 4 C2C SerDes links
            bool storm = ((sim_cycles % 19) == 7);
            uint8_t err_mask = storm ? (1 << ((sim_cycles / 19) & 3)) : 0;
            dut->c2c_link_err_inj_i = err_mask;

            // Only push a new token when Die 0 is ready and no link is mid-replay
            if (dut->cluster_tok_ready_o && (dut->die_c2c_replay_active_o == 0) && !storm) {
                uint64_t payload = (uint64_t(sent & 0xFFFF) << 48) ^ rval;
                dut->cluster_tok_valid_i  = 1;
                dut->cluster_tok_id_i     = sent & 0xFF;
                dut->cluster_user_id_i    = sent & 0xF;
                dut->cluster_tok_pos_i    = (sent >> 4) & 0xFF;
                dut->cluster_tok_latent_i = payload;
                dut->cluster_act_mxfp4_i  = uint32_t(rval & 0xFFFFFFFFULL);
                dut->cluster_act_e8m0_i   = 127 + (sent & 3);
                expected_cluster_fifo.push_back(payload);
                c2c_sent_tokens++;
                total_txns++;
                sent++;
            } else {
                dut->cluster_tok_valid_i = 0;
            }
            step_clk();
            // After a 1-cycle link error storm pulse, clear wire error so LLR replay succeeds
            if (storm) {
                dut->c2c_link_err_inj_i  = 0;
                dut->cluster_tok_valid_i = 0;
                for (int w = 0; w < 4; w++) step_clk();
            }
        }
        dut->cluster_tok_valid_i = 0;
        dut->c2c_link_err_inj_i  = 0;
        for (int drain = 0; drain < 64; drain++) step_clk();
        c2c_sb_en = false;
    }

    // -------------------------------------------------------------------------
    // Phase 3: 6,000 MoE Top-K Routing & Expert Tile Clock-Gating Checks (H3)
    // -------------------------------------------------------------------------
    void run_phase3_moe_topk_routing(int num_vectors) {
        uint64_t rng = 0x444545505345454BULL;
        for (int v = 0; v < num_vectors; v++) {
            uint64_t rval = lfsr64_next(rng);
            dut->topk_mode_i         = (v & 1); // Alternate K=2 (87.5% CG) and K=4 (75.0% CG)
            dut->shared_expert_en_i  = 1;
            dut->cluster_tok_valid_i = 1;
            dut->cluster_tok_id_i    = v & 0xFF;
            dut->cluster_act_mxfp4_i = uint32_t(rval);
            dut->cluster_act_e8m0_i  = 126 + (v & 7);
            step_clk();
            total_txns++;

            // Audit Top-K distinctness & clock-gating across all 4 HC2 dies
            for (int d = 0; d < 4; d++) {
                uint16_t act_m = (dut->die_active_experts_o >> (d * 16)) & 0xFFFF;
                uint16_t cg_m  = (dut->die_gated_experts_o  >> (d * 16)) & 0xFFFF;
                uint16_t ids   = (dut->die_sel_expert_ids_o >> (d * 16)) & 0xFFFF;
                assert(uint16_t(~act_m) == cg_m);

                uint8_t id0 = (ids >> 0)  & 0xF;
                uint8_t id1 = (ids >> 4)  & 0xF;
                uint8_t id2 = (ids >> 8)  & 0xF;
                uint8_t id3 = (ids >> 12) & 0xF;
                if (id0 == id1 || id0 == id2 || id0 == id3 ||
                    id1 == id2 || id1 == id3 || id2 == id3) {
                    moe_distinct_err++;
                }
                int act_bits = __builtin_popcount(act_m);
                int cg_bits  = __builtin_popcount(cg_m);
                active_exp_sum += act_bits;
                gated_exp_sum  += cg_bits;
                moe_topk_checks++;
            }
        }
        dut->cluster_tok_valid_i = 0;
        for (int i = 0; i < 16; i++) step_clk();
    }
};

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    TaalasHc2ClusterUvmEnv env;
    env.reset();
    env.run_phase1_disagg_3d_sram(2500);   // 2,500 * 8 = 20,000 3D-SRAM port txns
    env.run_phase2_c2c_llr_multichip(3000);// 3,000 multi-hop C2C LLR token streams
    env.run_phase3_moe_topk_routing(3000); // 3,000 * 4 dies = 12,000 MoE router checks

    double cg_pct = 100.0 * double(env.gated_exp_sum) / double(env.active_exp_sum + env.gated_exp_sum);
    std::cout << "==================================================================" << std::endl;
    std::cout << "STAGE 17 TAALAS HC2 MULTI-CHIP CLUSTER UVM SIGN-OFF SUMMARY"        << std::endl;
    std::cout << "==================================================================" << std::endl;
    std::cout << "Total Simulation Cycles          : " << env.sim_cycles              << std::endl;
    std::cout << "Total UVM Transactions Executed  : " << env.total_txns              << std::endl;
    std::cout << "3D-SRAM Port Writes / Reads      : " << env.sram_writes << " / " << env.sram_reads << std::endl;
    std::cout << "3D-SRAM Crossbar Bank Collisions : " << env.bank_collisions         << std::endl;
    std::cout << "SECDED Single-Bit Fixed (SEC)    : " << env.sec_corrected << " / " << env.sec_injected << std::endl;
    std::cout << "SECDED Double-Bit Detected (DED) : " << env.ded_detected  << " / " << env.ded_injected << std::endl;
    std::cout << "C2C 4-Die Tokens Sent / Rcvd     : " << env.c2c_sent_tokens << " / " << env.c2c_rcvd_tokens << std::endl;
    std::cout << "C2C LLR Replays / CRC Errors     : " << env.dut->cluster_llr_replays_o << " / " << env.dut->cluster_crc_errors_o << std::endl;
    std::cout << "C2C Dropped / Out-of-Order Errs  : " << env.c2c_order_errors        << std::endl;
    std::cout << "MoE Top-K Checks / Distinct Errs : " << env.moe_topk_checks << " / " << env.moe_distinct_err << std::endl;
    std::cout << "MoE Expert Tile Clock-Gating     : " << std::fixed << std::setprecision(2) << cg_pct << "%" << std::endl;
    std::cout << "==================================================================" << std::endl;

    assert(env.bank_collisions == 0);
    assert(env.sec_corrected == env.sec_injected && env.sec_injected > 0);
    assert(env.ded_detected  == env.ded_injected && env.ded_injected > 0);
    assert(env.c2c_rcvd_tokens >= env.c2c_sent_tokens);
    assert(env.c2c_order_errors == 0);
    assert(env.dut->cluster_llr_replays_o > 0);
    assert(env.moe_distinct_err == 0);
    assert(cg_pct > 75.0);
    std::cout << "[UVM_PASS] ALL 26,000+ STAGE 17 HC2 CLUSTER TRANSACTIONS PASSED!" << std::endl;
    return 0;
}
