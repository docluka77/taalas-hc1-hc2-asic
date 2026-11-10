source "helpers.tcl"
source "flow_helpers.tcl"
source "asap7/asap7.vars"
set design "taalas_token_pipe_noc_router"
set top_module "taalas_token_pipe_noc_router"
set synth_verilog "taalas_token_pipe_noc_router_netlist.v"
set sdc_file "taalas_token_pipe_noc_router.sdc"
set die_area {0 0 136.08 136.08}
set core_area {2.16 2.16 133.92 133.92}
include -echo "custom_flow.tcl"
exit
