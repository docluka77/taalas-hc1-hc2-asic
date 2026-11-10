source "helpers.tcl"
source "flow_helpers.tcl"
source "sky130hd/sky130hd.vars"
set design "taalas_3b6b_wired_mac_array"
set top_module "taalas_3b6b_wired_mac_array"
set synth_verilog "taalas_3b6b_wired_mac_array_netlist.v"
set sdc_file "taalas_3b6b_wired_mac_array.sdc"
set die_area {0 0 600 600}
set core_area {20 20 580 580}
include -echo "custom_flow.tcl"
exit
