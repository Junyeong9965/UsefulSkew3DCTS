# Stage R: STA-guided refinement of the delivery checkpoint (standalone session).
#   in : PROBE_INPUT_ODB / PROBE_INPUT_SDC (stage-D checkpoint)
#   out: RESULTS_DIR/4_cts.{odb,def,v,sdc}, REPORTS_DIR/metrics.csv and electrical.csv of the refined circuit
# The refinement re-estimates the parasitics and re-times the design before its first measurement and ends with a
# whole-design estimate of its final circuit, so the metrics below are read from that state.
source $::env(FLOW_HOME)/common/read_liberty.tcl
source $::env(OPENROAD_SCRIPTS_DIR)/cts_commands.tcl
read_db $::env(PROBE_INPUT_ODB)
read_sdc $::env(PROBE_INPUT_SDC)
source $::env(SET_RC_TCL)
set_propagated_clock [all_clocks]
proc ps {x} {expr {$x*1e12}}
set t0 [clock milliseconds]
run_clock_refinement
puts "REFINE_WALL_S [expr {([clock milliseconds]-$t0)/1000.0}]"
set f [open $::env(REPORTS_DIR)/metrics.csv w]
puts $f "setup_tns_ps,setup_wns_ps,hold_tns_ps,hold_wns_ps"
puts $f [join [list [ps [sta::total_negative_slack_cmd max]] [ps [sta::worst_slack_cmd max]] [ps [sta::total_negative_slack_cmd min]] [ps [sta::worst_slack_cmd min]]] ,]
close $f
set f [open $::env(REPORTS_DIR)/electrical.csv w]
puts $f "max_slew_violations,max_cap_violations,max_fanout_violations"
puts $f [join [list [sta::max_slew_violation_count] [sta::max_capacitance_violation_count] [sta::max_fanout_violation_count]] ,]
close $f
write_db $::env(RESULTS_DIR)/4_cts.odb
write_def $::env(RESULTS_DIR)/4_cts.def
write_verilog $::env(RESULTS_DIR)/4_cts.v
write_sdc $::env(RESULTS_DIR)/4_cts.sdc
