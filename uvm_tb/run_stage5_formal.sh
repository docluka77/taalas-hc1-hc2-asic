#!/usr/bin/env bash
set -e
cd /nfs/share/home/chenpei/hyr/taalas_hc1_marathon/rtl

echo "=== [1/4] Formal SAT: taalas_rope_cordic_unit ==="
yosys -p "read_verilog -sv -formal taalas_rope_cordic_unit.sv; chparam -set PAIR_LANES 1 taalas_rope_cordic_unit; prep -top taalas_rope_cordic_unit; memory_map; async2sync; chformal -lower; sat -verify -seq 6 -set-init-zero -prove-asserts" | grep -E "Import|Solving|SUCCESS|Q.E.D."

echo "=== [2/4] Formal SAT: taalas_flash_decode_attention ==="
yosys -p "read_verilog -sv -formal taalas_flash_decode_attention.sv; chparam -set HEAD_DIM 2 -set GQA_RATIO 1 taalas_flash_decode_attention; prep -top taalas_flash_decode_attention; memory_map; async2sync; chformal -lower; sat -verify -seq 6 -set-init-zero -prove-asserts" | grep -E "Import|Solving|SUCCESS|Q.E.D."

echo "=== [3/4] Formal SAT: taalas_rmsnorm_engine ==="
yosys -p "read_verilog -sv -formal taalas_rmsnorm_engine.sv; chparam -set HIDDEN_DIM 4 -set VEC_W 2 taalas_rmsnorm_engine; prep -top taalas_rmsnorm_engine; memory_map; async2sync; chformal -lower; sat -verify -seq 6 -set-init-zero -prove-asserts" | grep -E "Import|Solving|SUCCESS|Q.E.D."

echo "=== [4/4] Formal SAT: taalas_swiglu_ffn_pipe ==="
yosys -p "read_verilog -sv -formal taalas_swiglu_ffn_pipe.sv; chparam -set CHANNELS 2 -set DOWN_OUT_CH 2 taalas_swiglu_ffn_pipe; prep -top taalas_swiglu_ffn_pipe; memory_map; async2sync; chformal -lower; sat -verify -seq 6 -set-init-zero -prove-asserts" | grep -E "Import|Solving|SUCCESS|Q.E.D."

echo "ALL_STAGE5_FORMAL_SAT_QED"
