# Tier-exact legalization of post-CTS cells (stages P and D).
#
# For each tier t: every non-fixed standard cell of t is movable, detailed_placement runs with DPL_TIER_ONLY=t (only
# tier t is in the placement grid: same XY as a cell of the other tier is legal, a same-tier overlap is not), and a
# per-tier check_placement is logged.  Cells that are already legal keep their sites unless a post-CTS cell needs
# them.  The bottom tier of asap7_nangate45_3D has no NanGate45 rows in the merged DEF: the ASAP7 rows are saved,
# replaced by temporary NanGate45 rows on the 0.190 x 1.400 um grid of the placed bottom cells for that pass, and
# restored exactly afterwards (same row order and core area).  Placement statuses are restored at the end.
# A pre-CTS cell that is off its site grid was moved by the CTS step (e.g. a clock gater) and counts as post-CTS.
#   usage: legalize_new_cells_by_tier <block> <dict of pre-CTS instance names> <log label>  -> number of moved cells

proc tl_tier_of {mname} {
  if {[string first bottom $mname] >= 0} { return 0 }
  if {[string first upper $mname] >= 0} { return 1 }
  return -1
}

# replace all rows by NanGate45 rows covering the same core; returns the saved row specs and core area
proc tl_rows_to_ng45 {block} {
  set saved {}
  set xmin 1e18; set ymin 1e18; set xmax -1e18; set ymax -1e18
  foreach r [$block getRows] {
    lassign [$r getOrigin] ox oy
    set b [$r getBBox]
    lappend saved [list [$r getName] [[$r getSite] getName] $ox $oy [$r getOrient] [$r getDirection] [$r getSiteCount] [$r getSpacing]]
    set xmin [expr {min($xmin, [$b xMin])}]; set ymin [expr {min($ymin, [$b yMin])}]
    set xmax [expr {max($xmax, [$b xMax])}]; set ymax [expr {max($ymax, [$b yMax])}]
  }
  set site ""
  foreach lib [[ord::get_db] getLibs] {
    foreach s [$lib getSites] { if {[string match FreePDK45* [$s getName]]} { set site $s } }
  }
  if {$site eq ""} { error "tier legalization: no NanGate45 site found for the bottom-tier rows" }
  set sw [$site getWidth]; set sh [$site getHeight]
  # row orientation by row parity, taken from the placed bottom cells (grid origin 0,0 as in the placed design)
  set par(0) {}; set par(1) {}
  foreach i [$block getInsts] {
    if {[tl_tier_of [[$i getMaster] getName]] != 0} { continue }
    lassign [$i getLocation] x y
    if {$y % $sh} { continue }
    lappend par([expr {($y / $sh) % 2}]) [$i getOrient]
  }
  foreach p {0 1} {
    set best R0; set n 0
    foreach o [lsort -unique $par($p)] { set c [llength [lsearch -all $par($p) $o]]; if {$c > $n} { set n $c; set best $o } }
    set orient($p) $best
  }
  foreach r [$block getRows] { odb::dbRow_destroy $r }
  set x0 [expr {int(ceil(double($xmin) / $sw)) * $sw}]
  set y0 [expr {int(ceil(double($ymin) / $sh)) * $sh}]
  set ns [expr {int(($xmax - $x0) / $sw)}]
  set k 0
  for {set y $y0} {$y + $sh <= $ymax} {incr y $sh} {
    odb::dbRow_create $block NG45_TMP_ROW_$k $site $x0 $y $orient([expr {($y / $sh) % 2}]) HORIZONTAL $ns $sw
    incr k
  }
  # DPL measures the site grid from the core lower-left corner: align the core with the NanGate45 grid of the placed
  # bottom cells for this pass (restored afterwards)
  set c [$block getCoreArea]
  set core_saved [list [$c xMin] [$c yMin] [$c xMax] [$c yMax]]
  set nc [odb::Rect]
  $nc init $x0 $y0 [expr {$x0 + $ns * $sw}] [expr {$y0 + $k * $sh}]
  $block setCoreArea $nc
  puts "TIER_LEGAL temporary NG45 rows: $k rows x $ns sites, site [$site getName] ${sw}x${sh}, orient even=$orient(0) odd=$orient(1), core $x0 $y0"
  return [list $saved $core_saved]
}

proc tl_restore_rows {block saved_all} {
  lassign $saved_all saved core_saved
  foreach r [$block getRows] { odb::dbRow_destroy $r }
  set tech_sites [dict create]
  foreach lib [[ord::get_db] getLibs] { foreach s [$lib getSites] { dict set tech_sites [$s getName] $s } }
  # the block lists rows in reverse creation order: recreate in reverse so the row order (and the DEF) is unchanged
  foreach spec [lreverse $saved] {
    lassign $spec name sname ox oy orient dir cnt sp
    odb::dbRow_create $block $name [dict get $tech_sites $sname] $ox $oy $orient $dir $cnt $sp
  }
  set nc [odb::Rect]
  $nc init {*}$core_saved
  $block setCoreArea $nc
}

proc legalize_new_cells_by_tier {block pre_dict label} {
  set hetero [expr {[info exists ::env(HETEROGENEOUS_3D)] && $::env(HETEROGENEOUS_3D)}]
  set status [dict create]
  foreach i [$block getInsts] { dict set status [$i getName] [$i getPlacementStatus] }
  set moved_total 0
  # row origins and site pitch of the block rows (off-grid test of pre-CTS cells)
  set rowy [dict create]; set rowx 0; set rowsw 1
  foreach r [$block getRows] { lassign [$r getOrigin] ox oy; dict set rowy $oy 1; set rowx $ox; set rowsw [[$r getSite] getWidth] }
  foreach tier {0 1} {
    set movable {}; set others {}
    set hb [expr {$hetero && $tier == 0}]
    foreach i [$block getInsts] {
      if {[tl_tier_of [[$i getMaster] getName]] != $tier} { continue }
      lassign [$i getLocation] x y
      set offgrid 0
      if {[dict exists $pre_dict [$i getName]] && ![$i isFixed] && [[$i getMaster] getType] in {CORE COVER}} {
        if {$hb} { set offgrid [expr {($x % 190) || ($y % 1400)}] } else { set offgrid [expr {![dict exists $rowy $y] || (($x - $rowx) % $rowsw)}] }
      }
      if {[dict exists $pre_dict [$i getName]] && !$offgrid} {
        if {![$i isFixed]} { $i setPlacementStatus FIRM; lappend others [list $i $x $y] }
      } else {
        $i setPlacementStatus PLACED
        lappend movable [list $i $x $y]
      }
    }
    if {[llength $movable] == 0} { continue }
    # every standard cell of the tier may move (cells that are already legal keep their sites unless needed)
    foreach o $others { if {[[[lindex $o 0] getMaster] isCore] || [[[lindex $o 0] getMaster] getType] eq "COVER"} { [lindex $o 0] setPlacementStatus PLACED } }
    if {$hb} { set saved [tl_rows_to_ng45 $block] }
    set ::env(DPL_TIER_ONLY) $tier
    set rc [catch {detailed_placement} err]
    set crc [catch {check_placement -verbose} cerr]
    unset ::env(DPL_TIER_ONLY)
    if {$hb} { tl_restore_rows $block $saved }
    foreach grp {movable others} {
      set moved($grp) 0; set dmax($grp) 0; set dsum($grp) 0
      foreach m [set $grp] {
        lassign $m i x y
        lassign [$i getLocation] nx ny
        set d [expr {abs($nx - $x) + abs($ny - $y)}]
        if {$d} { incr moved($grp); set dsum($grp) [expr {$dsum($grp) + $d}]; set dmax($grp) [expr {max($dmax($grp), $d)}] }
      }
    }
    incr moved_total [expr {$moved(movable) + $moved(others)}]
    puts "TIER_LEGAL $label tier=$tier post_cts=[llength $movable] moved=$moved(movable) max_disp_dbu=$dmax(movable) sum_disp_dbu=$dsum(movable) pre_cts_moved=$moved(others) pre_max_disp_dbu=$dmax(others) pre_sum_disp_dbu=$dsum(others) dpl_rc=$rc check_rc=$crc [expr {$rc ? $err : ""}] [expr {$crc ? $cerr : ""}]"
  }
  dict for {n s} $status { set i [$block findInst $n]; if {[$i getPlacementStatus] ne $s} { $i setPlacementStatus $s } }
  return $moved_total
}
