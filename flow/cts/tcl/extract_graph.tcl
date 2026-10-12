# Stage G, one extraction process: sequential timing graph (FF->FF checks) and IO edges (PI->FF, FF->PO) of the
# Phase-1 reference state, propagated clocks, placement parasitics.  EXTRACT_PARTITION=k/K selects the launches of
# this process (the partitions are merged by flow/cts/native cts_partitions into the single-process row order); with
# EXTRACT_QUEUE=<counter file> the K processes take chunks of launches from that shared counter (the input-port side
# of the IO pass is one more work item, computed by the extract_ff_timing_graph_odb call of the process that takes it
# and written by its extract_io_timing_edges_odb call).
# EXTRACT_WRITE_METRICS=1 (last partition): also write reports/metrics.csv (reload check of stage D).
source $::env(FLOW_HOME)/common/read_liberty.tcl
read_db $::env(PROBE_INPUT_ODB)
read_sdc $::env(PROBE_INPUT_SDC)
source $::env(SET_RC_TCL)
set_propagated_clock [all_clocks]
estimate_parasitics -placement
set t [clock milliseconds]
cts::extract_ff_timing_graph_odb "$::env(RESULTS_DIR)/pre_cts_ff_timing_graph.csv"
puts "EXTRACT_FF_SECONDS [expr {([clock milliseconds]-$t)/1000.0}]"
set t [clock milliseconds]
cts::extract_io_timing_edges_odb "$::env(RESULTS_DIR)/pre_cts_io_timing_edges.csv"
puts "EXTRACT_IO_SECONDS [expr {([clock milliseconds]-$t)/1000.0}]"
if {[info exists ::env(EXTRACT_WRITE_METRICS)] && $::env(EXTRACT_WRITE_METRICS)} {
  set f [open "$::env(REPORTS_DIR)/metrics.csv" w]
  puts $f "setup_tns_ps,setup_wns_ps,hold_tns_ps,hold_wns_ps"
  puts $f [join [list [expr {[sta::total_negative_slack_cmd max]*1e12}] [expr {[sta::worst_slack_cmd max]*1e12}] [expr {[sta::total_negative_slack_cmd min]*1e12}] [expr {[sta::worst_slack_cmd min]*1e12}]] ,]
  close $f
}
puts "EXTRACT_DONE [clock milliseconds]"
exit
