source "helpers.tcl"
source "flow_helpers.tcl"
source "asap7/asap7.vars"
set design "taalas_sram_6t_banked_macro"
set top_module "taalas_sram_6t_banked_macro"
set synth_verilog "taalas_sram_6t_banked_macro_netlist.v"
set sdc_file "taalas_sram_6t_banked_macro.sdc"
set die_area {0 0 75.60 75.60}
set core_area {2.16 2.16 73.44 73.44}
include -echo "custom_flow.tcl"
exit
