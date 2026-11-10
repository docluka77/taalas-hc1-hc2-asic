source "helpers.tcl"
source "flow_helpers.tcl"
source "asap7/asap7.vars"
set design "baseline_fp16_int8_mac_array"
set top_module "baseline_fp16_int8_mac_array"
set synth_verilog "baseline_fp16_int8_mac_array_netlist.v"
set sdc_file "baseline_fp16_int8_mac_array.sdc"
set die_area {0 0 99.36 99.36}
set core_area {2.16 2.16 97.20 97.20}
include -echo "custom_flow.tcl"
exit
