source "helpers.tcl"
source "flow_helpers.tcl"
source "asap7/asap7.vars"
set design "taalas_dvfs_pvt_controller"
set top_module "taalas_dvfs_pvt_controller"
set synth_verilog "taalas_dvfs_pvt_controller_netlist.v"
set sdc_file "taalas_dvfs_pvt_controller.sdc"
set die_area {0 0 58.32 58.32}
set core_area {2.16 2.16 56.16 56.16}
include -echo "custom_flow.tcl"
exit
