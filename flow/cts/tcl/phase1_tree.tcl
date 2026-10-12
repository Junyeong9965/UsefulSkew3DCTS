# Phase-1 reference tree (child session of cts_3d.tcl, stage P).
#
# Balanced 3D clock tree on the placed design (clock_tree_synthesis -repair_clock_nets, no skew targets), the optional
# early-clock plan, the same tier-exact legalization and clock-buffer re-placement as the delivery session, then the
# propagated-clock reference state handed to the next stages:
#   phase1.odb, phase1.sdc, phase1.metrics   reference database and its STA summary
#   phase1_leaf_groups.csv                   first-level leaf groups (written by the CTS engine)
#   macros.txt                               macro instances (LP increment bound 0 in stage D: no chain reaches them)
#   pre_cts_leaf_bounds.csv                  per-register upper bound of the scheduled increment
#   cts_base_latency.csv                     per-register clock latency of the reference tree
#   clock_relegalize_P.csv                   clock buffers re-placed after legalization

set results $::env(RESULTS_DIR)
# first-level leaf audit written by the CTS engine (leaf tier = register-count majority)
set ::env(CTS_PHASE1_LEAF_AUDIT) "$results/phase1_leaf_groups.csv"
set f [open $::env(CTS_PHASE1_LEAF_AUDIT) w]
puts $f "clock,level,leaf,sink,tier,cap_ff,x,y,cx,cy,n0,n1,cap0_ff,cap1_ff,count_tier,cap_tier,chosen_tier"; close $f

source $::env(OPENROAD_SCRIPTS_DIR)/common.tcl
load_design 3_place.v 3_place.sdc "Phase 1: loading the placed design"

puts ">>> \[Phase 1\] balanced CTS (no skew targets)"
repair_clock_inverters

# characterization buffer list (same register-majority rule as the delivery session, without the heterogeneous rule)
set block [ord::get_db_block]
set n_bottom 0; set n_upper 0
foreach inst [$block getInsts] {
  set m [[$inst getMaster] getName]
  if {![regexp -nocase {DFF|SDFF} $m]} { continue }
  if {[string match "*bottom*" $m]} { incr n_bottom } elseif {[string match "*upper*" $m]} { incr n_upper }
}
set n [expr {$n_bottom + $n_upper}]
puts "Phase1 buf_list: bottom_ff=$n_bottom, upper_ff=$n_upper, total=$n"
if {$n > 0 && double($n_bottom) / $n < 0.5} {
  set buf_list "$::env(CTS_BUF_UPPER)"
  puts "Phase1 buf_list = upper-only ($buf_list)"
} else {
  set buf_list "$::env(CTS_BUF_BOTTOM) $::env(CTS_BUF_UPPER)"
  puts "Phase1 buf_list = both ($buf_list)"
}
set cts_args [list -sink_clustering_enable -repair_clock_nets -root_buf $::env(CTS_BUF_CELL) -buf_list $buf_list]
if {[info exists ::env(CTS_NO_INSERTION_DELAY)] && $::env(CTS_NO_INSERTION_DELAY)} {
  lappend cts_args -no_insertion_delay
  puts ">>> \[Phase 1\] CTS_NO_INSERTION_DELAY=1: latency balancer disabled"
}

# macro instances: no delay chain is built for a macro clock pin, so stage D gives them LP increment bound 0
set f [open "$results/macros.txt" w]
foreach inst [$block getInsts] { if {[[$inst getMaster] isBlock]} { puts $f [$inst getName] } }
close $f
# instances before CTS (they stay FIRM in the legalization below)
set pre_cts [dict create]
foreach inst [$block getInsts] { dict set pre_cts [$inst getName] 1 }

clock_tree_synthesis {*}$cts_args
if {[info exists ::env(EARLY_CLOCK_PLAN)] && $::env(EARLY_CLOCK_PLAN) ne ""} {
  source $::env(OPENROAD_SCRIPTS_DIR)/early_clock.tcl
  apply_early_clock_plan [ord::get_db_block] $::env(EARLY_CLOCK_PLAN) phase1
}

# legalize the reference tree with the delivery rules, so the base latencies, the graph and the LP see clock-buffer
# positions that the delivery tree can realize
source $::env(OPENROAD_SCRIPTS_DIR)/tier_legalize.tcl
source $::env(OPENROAD_SCRIPTS_DIR)/early_clock.tcl
source $::env(OPENROAD_SCRIPTS_DIR)/clock_relegalize.tcl
set block [ord::get_db_block]
set snap [clock_buffer_snapshot $block]
set n_moved [legalize_new_cells_by_tier $block $pre_cts "phase1"]
puts ">>> \[Phase 1\] legalization: $n_moved cells moved (see TIER_LEGAL phase1 lines)"
relegalize_clock_buffers $block $snap phase1 "$results/clock_relegalize_P.csv"

estimate_parasitics -placement
set_propagated_clock [all_clocks]
write_db "$results/phase1.odb"
write_sdc "$results/phase1.sdc"
set f [open "$results/phase1.metrics" w]
puts $f "[expr {[sta::total_negative_slack_cmd max]*1e12}] [expr {[sta::worst_slack_cmd max]*1e12}] [expr {[sta::total_negative_slack_cmd min]*1e12}] [expr {[sta::worst_slack_cmd min]*1e12}] [sta::max_slew_violation_count] [sta::max_capacitance_violation_count]"
close $f

# per-register bound of the scheduled increment (max_skew = 0.05 ns, the LP bound of stage D)
set bounds_csv "$results/pre_cts_leaf_bounds.csv"
if {[catch {cts::estimate_leaf_latencies $bounds_csv 0.05} err]} {
  puts "WARNING: \[Phase 1\] estimate_leaf_latencies failed: $err"
} else {
  puts ">>> \[Phase 1\] Leaf bounds written to $bounds_csv"
}

# per-register clock latency of the reference tree (cts_base_latency.csv): read only by the delivery balancer with
# CTS_BALANCER_BASE_RESTORE=1 (BAL_BASE=1, the ibex designs). Other cases (BAL_BASE=0 from cts_flow.sh) get a header-only
# file and skip the two path enumerations; with BAL_BASE unset (stand-alone run) the file is always written.
if {[info exists ::env(BAL_BASE)] && $::env(BAL_BASE) == 0} {
  set fp [open "$results/cts_base_latency.csv" w]
  puts $fp "ff_name,base_latency_ps"
  close $fp
  puts ">>> \[Phase 1\] Base latency not needed (BAL_BASE=0): header-only file"
} else {
  # per-register clock latency of the reference tree: capture clock delay of the worst setup / hold paths, then the
  # launch clock latency of their startpoints (first value per register wins)
  set num_paths 10000
  array set lat {}
  if {[catch {
    foreach path_end [find_timing_paths -sort_by_slack -path_delay max -group_path_count $num_paths] {
      set ff [regsub {/[^/]+$} [get_full_name [$path_end pin]] ""]
      if {![info exists lat($ff)]} { set lat($ff) [expr {[$path_end target_clk_delay] * 1e12}] }
      set pins [[$path_end path] pins]
      if {[llength $pins] > 0} {
        set lff [regsub {/[^/]+$} [get_full_name [lindex $pins end]] ""]
        if {![info exists lat($lff)]} { set lat($lff) [expr {[$path_end source_clk_latency] * 1e12}] }
      }
    }
  } err]} {
    puts "WARNING: \[Phase 1\] Setup path extraction: $err"
  }
  puts ">>> \[Phase 1\] Pass 1 (setup): [array size lat] FFs covered"
  if {[catch {
    foreach path_end [find_timing_paths -sort_by_slack -path_delay min -group_path_count $num_paths] {
      set ff [regsub {/[^/]+$} [get_full_name [$path_end pin]] ""]
      if {![info exists lat($ff)]} { set lat($ff) [expr {[$path_end target_clk_delay] * 1e12}] }
      set pins [[$path_end path] pins]
      if {[llength $pins] > 0} {
        set lff [regsub {/[^/]+$} [get_full_name [lindex $pins end]] ""]
        if {![info exists lat($lff)]} { set lat($lff) [expr {[$path_end source_clk_latency] * 1e12}] }
      }
    }
  } err]} {
    puts "WARNING: \[Phase 1\] Hold path extraction: $err"
  }
  puts ">>> \[Phase 1\] Pass 2 (hold):  [array size lat] FFs covered total"
  set fp [open "$results/cts_base_latency.csv" w]
  puts $fp "ff_name,base_latency_ps"
  foreach ff [lsort [array names lat]] { puts $fp "$ff,[format %.3f $lat($ff)]" }
  close $fp
  puts ">>> \[Phase 1\] Base latency written ([array size lat] FFs)"
}
exit
