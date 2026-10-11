# STA guard of the unsupported endpoints (stages GB / GA): every PathEnd at each endpoint of GUARD_ENDPOINTS_TSV,
# both check modes, written to guard_paths.csv / guard_queries.csv, plus the design metrics.
source $::env(OPENROAD_SCRIPTS_DIR)/read_liberty.tcl
read_db $::env(PROBE_INPUT_ODB)
read_sdc $::env(PROBE_INPUT_SDC)
source $::env(SET_RC_TCL)
set_propagated_clock [all_clocks]
if {$::env(PROBE_MODE) eq "route"} {
  read_spef $::env(PROBE_INPUT_SPEF)
} else {
  estimate_parasitics -placement
}
set out $::env(REPORTS_DIR)
set f [open "$out/guard_paths.csv" w]
puts $f "endpoint,mode,startpoint,role,slack_ps,data_ps,required_ps,capture_ps,margin_ps,crpr_ps,borrow_ps"
set q [open "$out/guard_queries.csv" w]
puts $q "endpoint,mode,path_count,saturated"
set input [open $::env(GUARD_ENDPOINTS_TSV) r]
set header [gets $input]
if {$header ne "endpoint	mode"} {error "Bad guard endpoint header"}
set cells {}
set source_cells {}
while {[gets $input line] >= 0} {
  if {$line eq ""} {continue}
  lassign [split $line "	"] endpoint mode
  set pin [get_pins -quiet $endpoint]
  if {[llength $pin] != 1} {error "Unsupported endpoint missing or ambiguous: $endpoint"}
  # a saturated query (more paths than the limit) is repeated with 10x / 40x the limit
  foreach limit {5000 50000 200000} {
    set paths [find_timing_paths -to $pin -path_delay $mode -sort_by_slack -group_path_count $limit -endpoint_path_count $limit -slack_max 1e9]
    set n [llength $paths]
    if {$n < $limit} break
  }
  puts $q [join [list $endpoint $mode $n [expr {$n >= $limit}]] ","]
  if {$n == 0 || $n >= $limit} {error "Guard path query missing/saturated: $endpoint $mode $n"}
  foreach path $paths {
    if {![$path is_check] && ![$path is_latch_check] && ![$path is_gated_clock]} {
      error "Guard endpoint has a non-check PathEnd: $endpoint $mode"
    }
    set role [$path check_role]
    set sp [get_full_name [get_property $path startpoint]]
    set borrow "NA"
    if {![catch {$path borrow} bv]} {set borrow [expr {$bv * 1e12}]}
    set row [list $endpoint $mode $sp $role]
    foreach method {slack data_arrival_time data_required_time target_clk_arrival margin check_crpr} {
      lappend row [expr {[$path $method] * 1e12}]
    }
    lappend row $borrow
    puts $f [join $row ","]
    if {[string first "/" $sp] >= 0} {
      lappend source_cells [join [lrange [split $sp "/"] 0 end-1] "/"]
    }
  }
  set cell [join [lrange [split $endpoint "/"] 0 end-1] "/"]
  lappend cells $cell
  report_checks -to $pin -path_delay $mode -sort_by_slack -group_path_count 3 -endpoint_path_count 3 -format full_clock_expanded -fields {slew cap input_pins} -digits 6 > "$out/guard_[string map {/ _ $ .} $endpoint]_$mode.rpt"
}
close $input
close $f
close $q
set ap [open "$out/guard_arrivals.rpt" w]
foreach cell [lsort -unique [concat $cells $source_cells]] {
  set pins [get_pins -quiet -of_objects [get_cells -quiet $cell]]
  foreach pin $pins {
    set name [get_full_name $pin]
    puts $ap "PIN $name"
    if {[catch {with_output_to_variable msg [list report_arrival $pin]} err]} {
      puts $ap "UNAVAILABLE $err"
    } elseif {$err ne ""} {
      puts $ap "UNAVAILABLE $err"
    } else {
      puts $ap $msg
    }
  }
}
close $ap
set m [open "$out/metrics.csv" w]
puts $m "setup_tns_ps,setup_wns_ps,hold_tns_ps,hold_wns_ps"
puts $m [join [list [expr {[sta::total_negative_slack_cmd max]*1e12}] [expr {[sta::worst_slack_cmd max]*1e12}] [expr {[sta::total_negative_slack_cmd min]*1e12}] [expr {[sta::worst_slack_cmd min]*1e12}]] ","]
close $m
exit
