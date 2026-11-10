#!/usr/bin/env bash
set -e
cd "$(dirname "$0")/.."

python3 - << 'EOF'
with open("uvm_tb/tb_uvm_taalas_all_modules.cpp") as f:
    s = f.read()
s = s.replace("Verilated::traceEverOn(true);", "")
s = s.replace("VerilatedVcdC* tfp = new VerilatedVcdC;", "VerilatedVcdC* tfp = nullptr;")
s = s.replace("dut->trace(tfp, 99);", "")
s = s.replace('tfp->open("uvm_tb/taalas_uvm_trace.vcd");', "")
s = s.replace("if (tfp && sim_cyc < 4000) tfp->dump(sim_time);", "")
s = s.replace("tfp->close();", "")
s = s.replace("delete tfp;", "")
s = s.replace("uvm_tb/coverage.dat", "uvm_tb/coverage_v3.dat")
with open("uvm_tb/tb_uvm_taalas_all_modules_v3.cpp", "w") as f:
    f.write(s)
EOF

make -C obj_dir_uvm_v3 -j16 OPT_FAST="-O3" -f Vtaalas_uvm_all_modules_top.mk > obj_dir_uvm_v3/build_link.log 2>&1
./obj_dir_uvm_v3/Vtaalas_uvm_all_modules_top > uvm_tb/stage12_cpp_uvm_v3.log 2>&1
tail -n 38 uvm_tb/stage12_cpp_uvm_v3.log
