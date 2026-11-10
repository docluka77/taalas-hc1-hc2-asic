source "helpers.tcl"
source "flow_helpers.tcl"
source "sky130hd/sky130hd.vars"
set design "taalas_token_pipe_noc_router"
set top_module "taalas_token_pipe_noc_router"
set synth_verilog "taalas_token_pipe_noc_router_netlist.v"
set sdc_file "taalas_token_pipe_noc_router.sdc"
set die_area {0 0 1080 1080}
set core_area {20 20 1060 1060}
include -echo "custom_flow.tcl"
exit
