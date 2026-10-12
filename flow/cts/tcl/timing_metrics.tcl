# Independent reload of a CTS checkpoint (ODB + SDC, placement parasitics).  Writes REPORTS_DIR/metrics.csv
# (setup / hold TNS / WNS, ps), electrical.csv (max slew / cap / fanout violation counts) and electrical.rpt (violators).
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
set f [open $::env(REPORTS_DIR)/electrical.csv w]
puts $f "max_slew_violations,max_cap_violations,max_fanout_violations"
puts $f [join [list [sta::max_slew_violation_count] [sta::max_capacitance_violation_count] [sta::max_fanout_violation_count]] ,]
close $f
report_check_types -max_slew -max_capacitance -max_fanout -violators > $::env(REPORTS_DIR)/electrical.rpt
