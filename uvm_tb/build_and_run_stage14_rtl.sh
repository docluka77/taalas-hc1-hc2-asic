#!/usr/bin/env bash
set -e
cd /nfs/share/home/chenpei/hyr/taalas_hc1_marathon

OBJ_DIR="uvm_tb/obj_stage14_v3"
mkdir -p "$OBJ_DIR" results

if [ ! -f "$OBJ_DIR/Vstage4_compute_ips_top__ALL.a" ]; then
    verilator -cc -sv -Irtl_v3 uvm_tb/stage4_compute_ips_top.sv --Mdir "$OBJ_DIR" --prefix Vstage4_compute_ips_top -CFLAGS "-O3 -std=c++17"
    make -C "$OBJ_DIR" -f Vstage4_compute_ips_top.mk -j8 >/dev/null
fi

for mod in taalas_rope_cordic_unit taalas_flash_decode_attention taalas_rmsnorm_engine taalas_swiglu_ffn_pipe taalas_hc1_chip_top; do
    if [ ! -f "$OBJ_DIR/V${mod}__ALL.a" ]; then
        verilator -cc -sv -Irtl_v3 "rtl_v3/${mod}.sv" --Mdir "$OBJ_DIR" --prefix "V${mod}" -CFLAGS "-O3 -std=c++17"
        make -C "$OBJ_DIR" -f "V${mod}.mk" -j8 >/dev/null
    fi
done

VERILATOR_ROOT_DIR=$(verilator -getenv VERILATOR_ROOT)
g++ -O3 -std=c++17 \
    -I"$OBJ_DIR" \
    -I"${VERILATOR_ROOT_DIR}/include" \
    -I"${VERILATOR_ROOT_DIR}/include/vltstd" \
    uvm_tb/tb_stage14_real_llm_rtl_runner.cpp \
    "${VERILATOR_ROOT_DIR}/include/verilated.cpp" \
    "$OBJ_DIR/Vstage4_compute_ips_top__ALL.a" \
    "$OBJ_DIR/Vtaalas_rope_cordic_unit__ALL.a" \
    "$OBJ_DIR/Vtaalas_flash_decode_attention__ALL.a" \
    "$OBJ_DIR/Vtaalas_rmsnorm_engine__ALL.a" \
    "$OBJ_DIR/Vtaalas_swiglu_ffn_pipe__ALL.a" \
    "$OBJ_DIR/Vtaalas_hc1_chip_top__ALL.a" \
    -o "$OBJ_DIR/sim_stage14_real_llm_rtl"

"./$OBJ_DIR/sim_stage14_real_llm_rtl" "${1:-results/stage14_rtl_stimulus_vectors.txt}"
