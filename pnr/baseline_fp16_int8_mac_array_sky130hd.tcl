source "helpers.tcl"
source "flow_helpers.tcl"
source "sky130hd/sky130hd.vars"
set design "baseline_fp16_int8_mac_array"
set top_module "baseline_fp16_int8_mac_array"
set synth_verilog "baseline_fp16_int8_mac_array_netlist.v"
set sdc_file "baseline_fp16_int8_mac_array.sdc"
set die_area {0 0 780 780}
set core_area {20 20 760 760}
include -echo "custom_flow.tcl"
exit
