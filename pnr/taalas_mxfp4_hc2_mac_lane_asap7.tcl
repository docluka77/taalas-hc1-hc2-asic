source "helpers.tcl"
source "flow_helpers.tcl"
source "asap7/asap7.vars"
set design "taalas_mxfp4_hc2_mac_lane"
set top_module "taalas_mxfp4_hc2_mac_lane"
set synth_verilog "taalas_mxfp4_hc2_mac_lane_netlist.v"
set sdc_file "taalas_mxfp4_hc2_mac_lane.sdc"
set die_area {0 0 69.12 69.12}
set core_area {2.16 2.16 66.96 66.96}
include -echo "custom_flow.tcl"
exit
