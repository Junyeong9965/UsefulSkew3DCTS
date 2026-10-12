# Route-input preparation: minimum-displacement legalization of a saved CTS checkpoint that has same-tier overlaps
# (run only when flow/cts/native cts_select overlap reports real overlaps).
#   env REC_ODB (input 4_cts.odb), REC_PRE (file with the pre-CTS instance names), REC_OUT (output directory)
# Per tier: every standard cell (master with a SITE; COVER macros without a site stay obstacles) may move,
# detailed_placement with DPL_TIER_ONLY=t; if the default DPL search window fails, every position of the tier is
# restored and the pass is repeated with a 300 x 150 um window.  NanGate45 rows for the bottom tier of the
# heterogeneous stack as in tier_legalize.tcl.
source [file join [file dirname [info script]] tier_legalize.tcl]

proc rl_is_stdcell {m} {
  set st [$m getSite]
  return [expr {$st ne "" && $st ne "NULL"}]
}
proc rl_dpl {maxdisp} {
  if {$maxdisp ne ""} { return [catch {detailed_placement -max_displacement [split [string map {, " "} $maxdisp]]} ::rl_err] }
  return [catch {detailed_placement} ::rl_err]
}
proc legalize_recover_by_tier {block pre_dict label} {
  set hetero [expr {[info exists ::env(HETEROGENEOUS_3D)] && $::env(HETEROGENEOUS_3D)}]
  set status [dict create]
  foreach i [$block getInsts] { dict set status [$i getName] [$i getPlacementStatus] }
  set moved_total 0
  set rowy [dict create]; set rowx 0; set rowsw 1
  foreach r [$block getRows] { lassign [$r getOrigin] ox oy; dict set rowy $oy 1; set rowx $ox; set rowsw [[$r getSite] getWidth] }
  foreach tier {0 1} {
    set movable {}; set others {}
    set hb [expr {$hetero && $tier == 0}]
    foreach i [$block getInsts] {
      if {[tl_tier_of [[$i getMaster] getName]] != $tier} { continue }
      lassign [$i getLocation] x y
      set offgrid 0
      if {[dict exists $pre_dict [$i getName]] && ![$i isFixed] && [rl_is_stdcell [$i getMaster]]} {
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
    foreach o $others { if {[rl_is_stdcell [[lindex $o 0] getMaster]]} { [lindex $o 0] setPlacementStatus PLACED } }
    if {$hb} { set saved [tl_rows_to_ng45 $block] }
    set ::env(DPL_TIER_ONLY) $tier
    set rc [rl_dpl ""]; set err $::rl_err
    if {$rc} {
      foreach m [concat $movable $others] { lassign $m i x y; $i setLocation $x $y }
      puts "RECOVER_LEGAL $label tier=$tier failed with the default window ($err) -> retry with 300x150 um"
      set rc [rl_dpl 300,150]; set err $::rl_err
    }
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
    puts "RECOVER_LEGAL $label tier=$tier post_cts=[llength $movable] moved=$moved(movable) max_disp_dbu=$dmax(movable) pre_cts_moved=$moved(others) dpl_rc=$rc check_rc=$crc [expr {$rc ? $err : ""}] [expr {$crc ? $cerr : ""}]"
  }
  dict for {n s} $status { set i [$block findInst $n]; if {[$i getPlacementStatus] ne $s} { $i setPlacementStatus $s } }
  return $moved_total
}

read_db $::env(REC_ODB)
set block [ord::get_db_block]
set pre [dict create]
set fh [open $::env(REC_PRE)]; while {[gets $fh l] >= 0} { if {$l ne ""} { dict set pre $l 1 } }; close $fh
set moved [legalize_recover_by_tier $block $pre "recover"]
puts "RECOVER moved=$moved"
write_db $::env(REC_OUT)/4_cts.odb
write_def $::env(REC_OUT)/4_cts.def
write_verilog $::env(REC_OUT)/4_cts.v
