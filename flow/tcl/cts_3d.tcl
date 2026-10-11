# 3D CTS session (one OpenROAD process, started by flow/cts_session.sh through `make ord-cts-3d`).
#
# CTS_STAGE=phase1   : stage P.  Runs phase1_tree.tcl in a child OpenROAD process (balanced 3D tree on the placed
#                      design, propagated-clock reference state) and exits.
# CTS_STAGE=delivery : stage D.  Reads the stage-G sequential graph, solves the useful-skew LP, builds the delivery
#                      tree (H-tree + shared delay chains), repairs and legalizes the new clock cells and writes
#                      4_cts.{odb,def,v,sdc}.  The LP target check (cts_checks targets) runs in the background and
#                      leaves verify_targets.rc in RESULTS_DIR (stage J waits for it).
# Optional: EARLY_CLOCK_PLAN = early-clock plan (decision output) applied right after clock_tree_synthesis in both
# stages, so the Phase-1 reference and the delivery tree carry the same early structure.

utl::set_metrics_stage "cts_3d__{}"
source $::env(OPENROAD_SCRIPTS_DIR)/common.tcl

set results $::env(RESULTS_DIR)
set ff_csv "$results/pre_cts_ff_timing_graph.csv"
set io_csv "$results/pre_cts_io_timing_edges.csv"
# the hold-budget loader of the CTS engine reads the graph through these two variables
set ::env(CTS_TIMING_GRAPH_CSV) $ff_csv
set ::env(CTS_IO_TIMING_CSV) $io_csv

# =====================================================================================================================
# Stage P: Phase-1 reference tree in a child session
# =====================================================================================================================
if {$::env(CTS_STAGE) eq "phase1"} {
  puts "\n========== Phase 1: balanced 3D tree (child session) =========="
  set t0 [clock seconds]
  set cmd [list $::env(OPENROAD_EXE) -no_init -threads $::env(NUM_CORES) -exit $::env(OPENROAD_SCRIPTS_DIR)/phase1_tree.tcl]
  puts ">>> $cmd"
  if {[catch {exec {*}$cmd} out]} {
    error "Phase 1 failed: $out"
  }
  puts $out
  puts ">>> Phase 1 elapsed: [expr {[clock seconds] - $t0}]s"
  exit
}
if {$::env(CTS_STAGE) ne "delivery"} { error "CTS_STAGE must be phase1 or delivery (got $::env(CTS_STAGE))" }

# =====================================================================================================================
# Stage D
# =====================================================================================================================
# first-level leaf audit of the delivery tree (leaf tier = register-count majority, as in Phase 1)
set ::env(CTS_PHASE1_LEAF_AUDIT) "$results/phase3_leaf_groups.csv"
set f [open $::env(CTS_PHASE1_LEAF_AUDIT) w]
puts $f "clock,level,leaf,sink,tier,cap_ff,x,y,cx,cy,n0,n1,cap0_ff,cap1_ff,count_tier,cap_tier,chosen_tier"; close $f

load_design 3_place.v 3_place.sdc "Starting 3D CTS..."

foreach f [list $ff_csv $io_csv] {
  if {![file exists $f]} { error "delivery needs the stage-G graph file $f" }
}

# ---------------------------------------------------------------------------------------------------------------------
# Useful-skew LP (OR-Tools GLOP): endpoint-TNS objective, two phases (WNS bound, then TNS), hold-safe targets
# a_i in [0, max_skew].  Parameters in ns.
# ---------------------------------------------------------------------------------------------------------------------
puts "\n========== Useful-skew LP =========="
set t0 [clock seconds]
set lp_sigma_local 0.001   ;# FF->FF hold safety margin
set lp_sigma_pi    0.045   ;# PI->FF hold safety margin
set lp_lambda_reg  0.01    ;# regularization weight of sum |a_i|
set lp_hold_margin 0.010   ;# hold margin
set lp_gamma_wns   10.0    ;# WNS weight (single-phase fallback of the solver)
set lp_weight_io   1.0     ;# weight of the IO (PI->FF / FF->PO) constraint penalties
set lp_max_skew    0.05    ;# upper bound of a scheduled arrival increment
set ::env(CTS_FF_TIMING_GRAPH_CSV) $ff_csv
set ::env(CTS_IO_TIMING_EDGES_CSV) $io_csv
set ::env(CTS_SKEW_TARGETS_CSV)    "$results/pre_cts_skew_targets.csv"
cts::solve_skew_lp $lp_sigma_local $lp_sigma_pi $lp_lambda_reg $lp_hold_margin $lp_gamma_wns $lp_weight_io $lp_max_skew
puts ">>> LP elapsed: [expr {[clock seconds] - $t0}]s"
# independent check of the LP targets against the graph (TARGET_VERIFICATION.json, exit code in verify_targets.rc)
set vt $::env(CTS3D_FLOW_DIR)/native/bin/cts_checks
exec sh -c "'$vt' targets '$results' > '$results/verify_targets.log' 2>&1; echo \$? > '$results/verify_targets.rc'" < /dev/null > /dev/null 2> /dev/null &

# ---------------------------------------------------------------------------------------------------------------------
# Delivery tree
# ---------------------------------------------------------------------------------------------------------------------
puts "\n========== Delivery tree =========="
set t0 [clock seconds]
set fix_layer [expr {$::env(CTS_LAYER) eq "bottom" ? "upper" : "bottom"}]
set hetero [expr {[info exists ::env(HETEROGENEOUS_3D)] && $::env(HETEROGENEOUS_3D)}]

repair_clock_inverters

# Characterization buffer list: the H-tree wire segment unit follows the highest-max-cap buffer of the list, so it
# must belong to the technology of the register majority (heterogeneous stack: always the upper ASAP7 tier).
proc delivery_buffer_list {hetero} {
  set n_bottom 0; set n_upper 0
  foreach inst [[ord::get_db_block] getInsts] {
    set m [[$inst getMaster] getName]
    if {![regexp -nocase {DFF|SDFF} $m]} { continue }
    if {[string match "*bottom*" $m]} { incr n_bottom } elseif {[string match "*upper*" $m]} { incr n_upper }
  }
  set n [expr {$n_bottom + $n_upper}]
  if {$hetero} {
    puts "  buf_list = upper-only (heterogeneous, $n_bottom bottom FFs)"
    return $::env(CTS_BUF_UPPER)
  } elseif {$n > 0 && double($n_bottom) / $n < 0.5} {
    puts "  buf_list = upper-only ($n_bottom/$n bottom FFs < 50%)"
    return $::env(CTS_BUF_UPPER)
  }
  puts "  buf_list = both-tier ($n_bottom/$n bottom FFs)"
  return "$::env(CTS_BUF_BOTTOM) $::env(CTS_BUF_UPPER)"
}
set cts_args [list -sink_clustering_enable -root_buf $::env(CTS_BUF_CELL) -buf_list [delivery_buffer_list $hetero]]
if {[info exists ::env(CTS_NO_INSERTION_DELAY)] && $::env(CTS_NO_INSERTION_DELAY)} {
  lappend cts_args -no_insertion_delay
  puts "  CTS_NO_INSERTION_DELAY=1: latency balancer disabled"
}

set block [ord::get_db_block]
set pre_cts [dict create]
foreach inst [$block getInsts] { dict set pre_cts [$inst getName] 1 }

log_cmd clock_tree_synthesis {*}$cts_args

# Early-clock plan.  A hub anchor that is a repair buffer of Phase 1 (Phase 1 builds with -repair_clock_nets) exists
# here only after repair_clock_nets below; then the whole plan is applied after that repair (same order as Phase 1).
set plan_deferred 0
if {[info exists ::env(EARLY_CLOCK_PLAN)] && $::env(EARLY_CLOCK_PLAN) ne ""} {
  source $::env(OPENROAD_SCRIPTS_DIR)/early_clock.tcl
  set missing [early_clock_missing_anchors $block $::env(EARLY_CLOCK_PLAN)]
  if {[llength $missing] > 0} {
    set plan_deferred 1
    puts "EARLY_CLOCK_DEFER hub anchors not present after CTS: $missing -> plan applied after repair_clock_nets"
  } else {
    apply_early_clock_plan $block $::env(EARLY_CLOCK_PLAN) delivery
  }
}

# new clock cells of this session, by tier
set cts_bottom_cells {}; set cts_upper_cells {}
foreach inst [$block getInsts] {
  set name [$inst getName]
  if {[dict exists $pre_cts $name]} { continue }
  if {[string match "*bottom*" [[$inst getMaster] getName]]} { lappend cts_bottom_cells $name } else { lappend cts_upper_cells $name }
}
puts "  New CTS cells: bottom=[llength $cts_bottom_cells]  upper=[llength $cts_upper_cells]"

set_placement_padding -global \
  -left $::env(CELL_PAD_IN_SITES_DETAIL_PLACEMENT) \
  -right $::env(CELL_PAD_IN_SITES_DETAIL_PLACEMENT)
puts ">>> Delivery tree elapsed: [expr {[clock seconds] - $t0}]s"

# ---------------------------------------------------------------------------------------------------------------------
# Repair, legalization
# ---------------------------------------------------------------------------------------------------------------------
puts "\n========== Tier-aware repair_clock_nets + legalization =========="
set t0 [clock seconds]
estimate_parasitics -placement
mark_insts_by_master "*${fix_layer}*" PLACED

set pre_repair [dict create]
foreach inst [$block getInsts] { dict set pre_repair [$inst getName] 1 }
puts ">>> repair_clock_nets (pre-count: [dict size $pre_repair])"
# heterogeneous stack: repair buffers from the upper (ASAP7) library only; a bottom NanGate45 buffer cannot be
# swapped to the tier of its loads by name
if {$hetero} { set_dont_use "*_bottom" }
# a failed repair leaves the tree as built; the result is still checked by the LP-target and timing gates
if {[catch {repair_clock_nets} err]} {
  puts "WARNING: repair_clock_nets failed: $err"
}
if {$hetero} { unset_dont_use "*_bottom" }

# a repair buffer takes the tier of the majority of its loads (same master family, other tier suffix)
set n_new 0; set n_swapped 0
set db [ord::get_db]
foreach inst [$block getInsts] {
  if {[dict exists $pre_repair [$inst getName]]} { continue }
  incr n_new
  set master [[$inst getMaster] getName]
  set n_bottom 0; set n_upper 0
  foreach iterm [$inst getITerms] {
    set net [$iterm getNet]
    if {$net == "NULL" || [$iterm isOutputSignal] == 0} { continue }
    foreach sink [$net getITerms] {
      set sinst [$sink getInst]
      if {$sinst == $inst} { continue }
      set sm [[$sinst getMaster] getName]
      if {[string match "*bottom*" $sm]} { incr n_bottom }
      if {[string match "*upper*" $sm]}  { incr n_upper }
    }
  }
  set tier [expr {$n_bottom > $n_upper ? 0 : 1}]
  set swap ""
  if {$tier == 0 && [string match "*_upper*" $master]} {
    set swap [string map {_upper _bottom} $master]
  } elseif {$tier == 1 && [string match "*_bottom*" $master]} {
    set swap [string map {_bottom _upper} $master]
  }
  if {$swap ne ""} {
    set m [$db findMaster $swap]
    if {$m != "NULL"} { $inst swapMaster $m; incr n_swapped }
  }
}
puts "  Repair: $n_new new buffers, $n_swapped tier-swapped"

if {$plan_deferred} {
  set pre_plan [dict create]
  foreach inst [$block getInsts] { dict set pre_plan [$inst getName] 1 }
  apply_early_clock_plan $block $::env(EARLY_CLOCK_PLAN) delivery_deferred
  foreach inst [$block getInsts] {
    set name [$inst getName]
    if {[dict exists $pre_plan $name]} { continue }
    if {[string match "*bottom*" [[$inst getMaster] getName]]} { lappend cts_bottom_cells $name } else { lappend cts_upper_cells $name }
    puts "EARLY_CLOCK_DEFER new cell $name [[$inst getMaster] getName]"
  }
}

# Detailed placement of the post-CTS cells (pre-CTS cells FIRM).  Not on the heterogeneous stack: the merged DEF has
# no NanGate45 rows, the tier-exact legalization below handles both tiers.
if {!$hetero} {
  puts ">>> Post-repair DPL (pre-CTS cells FIRM)"
  set n_free 0
  foreach inst [$block getInsts] { $inst setPlacementStatus FIRM }
  foreach inst [$block getInsts] {
    if {![dict exists $pre_cts [$inst getName]]} { $inst setPlacementStatus PLACED; incr n_free }
  }
  puts "  FIRM: [dict size $pre_cts] pre-CTS cells, FREE: $n_free post-CTS cells"
  # a cell the legalizer cannot place keeps its position (tolerated: at most a few cells on the macro designs)
  if {[catch {detailed_placement} err]} {
    puts "WARNING: Post-repair DPL failed: $err"
  }
  foreach inst [$block getInsts] { $inst setPlacementStatus PLACED }
} else {
  puts ">>> Post-repair DPL: skipped (heterogeneous stack)"
}

# Snap the new clock cells to the site grid of their tier (upper: first row of the block; bottom on the heterogeneous
# stack: NanGate45 0.190 x 1.400 um grid of the placed bottom cells).  Separate collision sets per tier.
set row0 [lindex [$block getRows] 0]
set site_w [[$row0 getSite] getWidth]
set site_h [[$row0 getSite] getHeight]
set row_y0 [lindex [$row0 getOrigin] 1]
set bot_site_w $site_w; set bot_site_h $site_h; set bot_row_y0 0
if {$hetero} {
  set dbu [$block getDbUnitsPerMicron]
  set bot_site_w [expr {int(round(0.190 * $dbu))}]
  set bot_site_h [expr {int(round(1.400 * $dbu))}]
  foreach inst [$block getInsts] {
    if {[string match "*bottom*" [[$inst getMaster] getName]]} {
      set bot_row_y0 [expr {[lindex [$inst getOrigin] 1] % $bot_site_h}]
      break
    }
  }
  puts "  Grid: upper(ASAP7)=${site_w}x${site_h} dbu, bottom(NG45)=${bot_site_w}x${bot_site_h} dbu, y0=${bot_row_y0}"
}
set occ_upper [dict create]; set occ_bottom [dict create]
foreach inst [$block getInsts] {
  set m [[$inst getMaster] getName]; set name [$inst getName]
  if {[string match "clkbuf_*" $name] || [string match "clkload*" $name] || [string match "*repair*" $name]} { continue }
  set key "[lindex [$inst getOrigin] 0],[lindex [$inst getOrigin] 1]"
  if {[string match "*upper*" $m]} { dict set occ_upper $key 1 } elseif {[string match "*bottom*" $m]} { dict set occ_bottom $key 1 }
}
proc snap_cells_to_grid {cells block sw sh y0 occ_var} {
  upvar $occ_var occ
  set cnt 0
  foreach name $cells {
    set inst [$block findInst $name]
    if {$inst eq "" || $inst eq "NULL"} { continue }
    set ox [lindex [$inst getOrigin] 0]
    set oy [lindex [$inst getOrigin] 1]
    set sx [expr {int(round(double($ox) / $sw)) * $sw}]
    set sy [expr {$y0 + int(round(double($oy - $y0) / $sh)) * $sh}]
    if {[dict exists $occ "${sx},${sy}"]} {
      set found 0
      for {set r 1} {$r <= 10 && !$found} {incr r} {
        foreach dy [list 0 $r [expr {-$r}]] {
          foreach dx [list 0 $r [expr {-$r}]] {
            if {$dx == 0 && $dy == 0} { continue }
            set tx [expr {$sx + $dx * $sw}]
            set ty [expr {$sy + $dy * $sh}]
            if {![dict exists $occ "${tx},${ty}"]} { set sx $tx; set sy $ty; set found 1; break }
          }
          if {$found} { break }
        }
      }
    }
    $inst setOrigin $sx $sy
    dict set occ "${sx},${sy}" 1
    incr cnt
  }
  return $cnt
}
set n_snap [expr {[snap_cells_to_grid $cts_upper_cells $block $site_w $site_h $row_y0 occ_upper] + \
                  [snap_cells_to_grid $cts_bottom_cells $block $bot_site_w $bot_site_h $bot_row_y0 occ_bottom]}]
puts "  Grid-snapped $n_snap CTS buffers"

# Tier-exact legalization of every post-CTS cell (pre-CTS cells FIRM), then the load-centred re-placement of clock
# buffers that legalization pushed away from their loads.
source $::env(OPENROAD_SCRIPTS_DIR)/tier_legalize.tcl
source $::env(OPENROAD_SCRIPTS_DIR)/early_clock.tcl
source $::env(OPENROAD_SCRIPTS_DIR)/clock_relegalize.tcl
set snap [clock_buffer_snapshot $block]
set n_moved [legalize_new_cells_by_tier $block $pre_cts "phase4"]
puts ">>> Tier-exact legalization: $n_moved cells moved (see TIER_LEGAL lines)"
relegalize_clock_buffers $block $snap phase4 "$results/clock_relegalize_D.csv"
puts ">>> Repair + legalization elapsed: [expr {[clock seconds] - $t0}]s"

write_db $results/4_cts.odb
write_def $results/4_cts.def
write_verilog $results/4_cts.v
write_sdc $results/4_cts.sdc
puts ">>> 4_cts.{odb,def,v,sdc} written"
exit
