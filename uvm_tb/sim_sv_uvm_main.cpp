// =============================================================================
// File:        uvm_tb/sim_sv_uvm_main.cpp
// Project:     Taalas HC1/HC2 Hardwired LLM Inference ASIC
// Description: Verilator 5.054 (--timing) Main Event Loop for Native Accellera
//              IEEE 1800.2 SystemVerilog UVM-2020.3.1 Testbench
//              (tb_sv_uvm_taalas_top).
// =============================================================================

#include "Vtb_sv_uvm_taalas_top.h"
#include "verilated.h"
#include "verilated_cov.h"
#include <memory>

int main(int argc, char** argv) {
    auto context = std::make_unique<VerilatedContext>();
    context->commandArgs(argc, argv);
    auto top = std::make_unique<Vtb_sv_uvm_taalas_top>(context.get());
    while (!context->gotFinish()) {
        top->eval();
        if (!top->eventsPending()) break;
        context->time(top->nextTimeSlot());
    }
    top->final();
    context->coveragep()->write("uvm_tb/coverage_sv_uvm.dat");
    return 0;
}
