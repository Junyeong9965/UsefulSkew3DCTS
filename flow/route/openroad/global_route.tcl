utl::set_metrics_stage "globalroute__{}"
source $::env(FLOW_HOME)/common/load.tcl
source $::env(FLOW_HOME)/common/util.tcl
load_design 4_cts.def 4_cts.sdc "Start global route"

# This proc is here to allow us to use 'return' to return early from this
# file which is sourced
proc global_route_helper { } {
  source $::env(OPENROAD_SCRIPTS_DIR)/deleteRoutingObstructions.tcl
  deleteRoutingObstructions
  source_env_var_if_exists PRE_GLOBAL_ROUTE_TCL
  
  proc do_global_route { } {
    set all_args [concat [list \
      -congestion_report_file $::global_route_congestion_report] \
      $::env(GLOBAL_ROUTE_ARGS)]

    log_cmd global_route {*}$all_args
  }
  source $::env(FASTROUTE_TCL)
  pin_access

  set result [catch { do_global_route } errMsg]

  if { $result != 0 } {
    if { [env_var_exists_and_non_empty GENERATE_ARTIFACTS_ON_FAILURE] && !$::env(GENERATE_ARTIFACTS_ON_FAILURE) } {
      write_db $::env(RESULTS_DIR)/5_1_grt-failed.odb
      error $errMsg
    }
    write_sdc -no_timestamp $::env(RESULTS_DIR)/5_1_grt.sdc
    write_db $::env(RESULTS_DIR)/5_1_grt.odb
    return
  }

  set_placement_padding -global \
    -left $::env(CELL_PAD_IN_SITES_DETAIL_PLACEMENT) \
    -right $::env(CELL_PAD_IN_SITES_DETAIL_PLACEMENT)

  set_propagated_clock [all_clocks]
  estimate_parasitics -global_routing

  if { [env_var_exists_and_non_empty DONT_USE_CELLS] } {
    set_dont_use $::env(DONT_USE_CELLS)
  }

  puts "Estimate parasitics..."
  estimate_parasitics -global_routing

  # Writes updated_clks.sdc (clock period with slightly negative slack); the clock is redefined there and restored,
  # so 5_1_grt.sdc below keeps the original clock definition.
  source [file join $::env(OPENROAD_SCRIPTS_DIR) "write_ref_sdc.tcl"]
  write_guides $::env(RESULTS_DIR)/route.guide
  write_db $::env(RESULTS_DIR)/5_1_grt.odb
  write_sdc -no_timestamp $::env(RESULTS_DIR)/5_1_grt.sdc
}

global_route_helper

exit
