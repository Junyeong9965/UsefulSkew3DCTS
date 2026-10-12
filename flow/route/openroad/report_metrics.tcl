source $::env(FLOW_HOME)/common/util.tcl

proc report_puts { out } {
  upvar 1 when when
  upvar 1 filename filename
  set fileId [open $filename a]
  puts $fileId $out
  close $fileId
}

# report_metrics <stage> <when>: timing, power and area report of the final design in REPORTS_DIR/<stage>_<when>.rpt
proc report_metrics { stage when } {
  puts "Report metrics stage $stage, $when..."
  set filename $::env(REPORTS_DIR)/${stage}_[string map {" " "_"} $when].rpt
  set fileId [open $filename w]
  close $fileId
  report_puts "\n=========================================================================="
  report_puts "$when report_tns"
  report_puts "--------------------------------------------------------------------------"
  report_tns >> $filename
  report_tns -min >> $filename
  report_tns_metric
  report_tns_metric -hold

  # print timing information to terminal
  puts -nonewline "$when report_tns"
  report_tns
  puts -nonewline "$when report_wns"
  report_wns
  puts -nonewline "$when report_ecp"
  report_clock_min_period -include_port_paths

  report_puts "\n=========================================================================="
  report_puts "$when report_wns"
  report_puts "--------------------------------------------------------------------------"
  report_wns >> $filename
  report_wns -min >> $filename

  # Hold TNS/WNS in explicit key format (setup_tns ... hold_wns lines read by result scripts)
  report_puts "\n=========================================================================="
  report_puts "$when hold timing"
  report_puts "--------------------------------------------------------------------------"
  set _hold_tns [sta::format_time [sta::total_negative_slack_cmd "min"] 4]
  set _hold_wns [sta::format_time [sta::worst_slack_cmd "min"] 4]
  set _setup_tns [sta::format_time [sta::total_negative_slack_cmd "max"] 4]
  set _setup_wns [sta::format_time [sta::worst_slack_cmd "max"] 4]
  report_puts "setup_tns ${_setup_tns}"
  report_puts "setup_wns ${_setup_wns}"
  report_puts "hold_tns ${_hold_tns}"
  report_puts "hold_wns ${_hold_wns}"

  report_puts "\n=========================================================================="
  report_puts "$when report_worst_slack"
  report_puts "--------------------------------------------------------------------------"
  report_worst_slack >> $filename
  report_worst_slack_metric
  report_worst_slack_metric -hold

  report_puts "\n=========================================================================="
  report_puts "$when report_clock_min_period"
  report_puts "--------------------------------------------------------------------------"
  report_clock_min_period -include_port_paths >> $filename
  report_fmax_metric

  report_puts "\n=========================================================================="
  report_puts "$when report_checks -path_delay min"
  report_puts "--------------------------------------------------------------------------"
  report_checks -path_delay min -fields {slew cap input net fanout} \
    -format full_clock_expanded >> $filename

  report_puts "\n=========================================================================="
  report_puts "$when report_checks -path_delay max"
  report_puts "--------------------------------------------------------------------------"
  report_checks -path_delay max -fields {slew cap input net fanout} \
    -format full_clock_expanded >> $filename

  report_puts "\n=========================================================================="
  report_puts "$when report_checks -unconstrained"
  report_puts "--------------------------------------------------------------------------"
  report_checks -unconstrained -fields {slew cap input net fanout} \
    -format full_clock_expanded >> $filename

  report_puts "\n=========================================================================="
  report_puts "$when report_power"
  report_puts "--------------------------------------------------------------------------"
  report_power >> $filename
  report_power_metric

  # report_design_area prints to stdout only (the area line of 6_report.log)
  puts "\n=========================================================================="
  puts "$when report_design_area"
  puts "--------------------------------------------------------------------------"
  report_design_area
  report_design_area_metrics
}
