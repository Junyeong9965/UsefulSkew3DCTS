# Timing report of the CTS output (same reload as timing_metrics.tcl: ODB + SDC, placement parasitics, propagated clocks).
# Writes REPORTS_DIR/metrics.csv (setup / hold TNS / WNS, ps) and REPORTS_DIR/paths.rpt (worst setup and hold paths per
# path group, times in ps on every platform).
source $::env(FLOW_HOME)/common/read_liberty.tcl
read_db $::env(PROBE_INPUT_ODB)
read_sdc $::env(PROBE_INPUT_SDC)
source $::env(SET_RC_TCL)
set_propagated_clock [all_clocks]
estimate_parasitics -placement
proc ps {x} {expr {$x*1e12}}
set f [open $::env(REPORTS_DIR)/metrics.csv w]
puts $f "setup_tns_ps,setup_wns_ps,hold_tns_ps,hold_wns_ps"
puts $f [join [list [ps [sta::total_negative_slack_cmd max]] [ps [sta::worst_slack_cmd max]] [ps [sta::total_negative_slack_cmd min]] [ps [sta::worst_slack_cmd min]]] ,]
close $f
set_cmd_units -time ps
set n $::env(REPORT_PATH_COUNT)
set rpt $::env(REPORTS_DIR)/paths.rpt
set f [open $rpt w]; puts $f "Worst setup paths ($n per path group)\n"; close $f
report_checks -path_delay max -group_path_count $n -digits 2 >> $rpt
set f [open $rpt a]; puts $f "\nWorst hold paths ($n per path group)\n"; close $f
report_checks -path_delay min -group_path_count $n -digits 2 >> $rpt
