source "helpers.tcl"
source "flow_helpers.tcl"
source "asap7/asap7.vars"
set design "taalas_3b6b_wired_mac_array"
set top_module "taalas_3b6b_wired_mac_array"
set synth_verilog "taalas_3b6b_wired_mac_array_netlist.v"
set sdc_file "taalas_3b6b_wired_mac_array.sdc"
set die_area {0 0 75.60 75.60}
set core_area {2.16 2.16 73.44 73.44}
include -echo "custom_flow.tcl"
exit
