#!/usr/bin/env bash
set -e
cd /nfs/share/home/chenpei/hyr/taalas_hc1_marathon

OBJ_DIR="/tmp/taalas_stage5_obj"
rm -rf "$OBJ_DIR"
mkdir -p "$OBJ_DIR" results

for mod in taalas_rope_cordic_unit taalas_flash_decode_attention taalas_rmsnorm_engine taalas_swiglu_ffn_pipe; do
    verilator -cc -sv "rtl/${mod}.sv" --Mdir "$OBJ_DIR" --prefix "V${mod}" -CFLAGS "-O2 -std=c++17"
    make -C "$OBJ_DIR" -f "V${mod}.mk" -j4
done

VERILATOR_ROOT_DIR=$(verilator -getenv VERILATOR_ROOT)
g++ -O2 -std=c++17 \
    -I"$OBJ_DIR" \
    -I"${VERILATOR_ROOT_DIR}/include" \
    -I"${VERILATOR_ROOT_DIR}/include/vltstd" \
    uvm_tb/tb_stage5_attention_nonlin_ips.cpp \
    "${VERILATOR_ROOT_DIR}/include/verilated.cpp" \
    "$OBJ_DIR/Vtaalas_rope_cordic_unit__ALL.a" \
    "$OBJ_DIR/Vtaalas_flash_decode_attention__ALL.a" \
    "$OBJ_DIR/Vtaalas_rmsnorm_engine__ALL.a" \
    "$OBJ_DIR/Vtaalas_swiglu_ffn_pipe__ALL.a" \
    -o "$OBJ_DIR/sim_stage5_uvm"

"$OBJ_DIR/sim_stage5_uvm"
cat results/stage5_attention_nonlin_verification.json
