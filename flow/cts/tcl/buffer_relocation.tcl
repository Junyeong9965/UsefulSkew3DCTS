# Stage Q: far clock-buffer relocation (relocate_far_clock_buffers), standalone session on the stage-R checkpoint.
#
# Candidates: every buffer driving a CLOCK net whose location is outside the bounding box of its load pins by more
# than 30 um.  Move = the buffer goes to the nearest empty site-aligned span of its own tier around the centroid of its
# load pins (place_at_legal_site, radius 150 um); if after that its driver (a buffer on a clock net) is outside its own
# load box by more than 30 um, the driver is moved too, up to 3 levels (one bundle).  Candidates in decreasing
# out-of-box distance; greedy keep/rollback on the whole-design STA (placement parasitics):
#   keep iff setup TNS + hold TNS gain > 1 ps, setup WNS >= current - 0.5 ps, hold WNS >= current - 0.02 ps,
# otherwise every cell of the bundle returns to its location and orientation.  No connection or master change.
# The site occupancy is kept per (tier, site) and updated for every kept move, so a rollback restores it without a
# rebuild.  Output (REPORTS_DIR): reloc.csv (one line per bundle), metrics_before.csv, metrics_after.csv (metrics of
# the last kept state), edited.odb.
source $::env(FLOW_HOME)/common/read_liberty.tcl
read_db $::env(PROBE_INPUT_ODB)
read_sdc $::env(PROBE_INPUT_SDC)
source $::env(SET_RC_TCL)
source $::env(OPENROAD_SCRIPTS_DIR)/early_clock.tcl
set_propagated_clock [all_clocks]

# exact copy of the occupancy of every (tier, site) key, taken when the key is first built
rename site_occupancy site_occupancy_build
proc site_occupancy {block tier site} {
  set key "${tier}:[$site getName]"
  set built [expr {![info exists ::site_occ_cache($key)]}]
  set k [site_occupancy_build $block $tier $site]
  if {$built && ![info exists ::QX($k)]} { set ::QX($k) $::site_occ_cache($k); set ::QXT($k) $tier }
  return $k
}
proc qx_iv {key op y0 y1 x0 x1} {
  set new {}
  foreach r $::QX($key) {
    if {[lindex $r 1] > $y0 && [lindex $r 0] < $y1} {
      set l [lindex $r 6]
      if {$op eq "add"} { lappend l [list $x0 $x1] } else { set i [lsearch -exact $l [list $x0 $x1]]; if {$i >= 0} { set l [lreplace $l $i $i] } else { puts "RELOC_WARN missing interval $key $x0 $x1" } }
      set r [lreplace $r 6 6 [lsort -integer -index 0 $l]]
    }
    lappend new $r
  }
  set ::QX($key) $new
}
# kept move of inst from (ox,oy) to its current location: update every key of its tier (tier -1 cells are in every key)
proc qx_move {inst ox oy} {
  set nm [$inst getName]
  if {[string match "clkbuf_early_*" $nm] || [string match "clkbuf_hub_*" $nm]} return
  set m [$inst getMaster]; set w [$m getWidth]; set h [$m getHeight]; set t [early_tier_of [$m getName]]
  set bb [$inst getBBox]
  foreach key [array names ::QX] {
    if {$t != $::QXT($key) && $t != -1} continue
    qx_iv $key del $oy [expr {$oy + $h}] $ox [expr {$ox + $w}]
    qx_iv $key add [$bb yMin] [$bb yMax] [$bb xMin] [$bb xMax]
  }
}

set ::legal_site_radius_um 150
set minum 30
set block [ord::get_db_block]; set dbu [[ord::get_db_tech] getDbUnitsPerMicron]; set rd $::env(REPORTS_DIR)
# Metrics of the current state.  Default: incremental placement parasitics (cts::reloc_eval_metrics re-estimates only
# the nets on a pin of an instance moved or moved back since the previous call; the first call estimates the whole
# design).  CTS3D_Q_FULL_RC=1: whole-design estimate_parasitics for every candidate (reference path).
set ::q_full [expr {[info exists ::env(CTS3D_Q_FULL_RC)] && $::env(CTS3D_Q_FULL_RC) eq "1"}]
set ::q_mode 0; set ::q_moved {}
proc m4 {} {
  if {!$::q_full} {
    # values are returned with 17 significant digits; expr converts them to the same doubles as the whole-design path
    set r [lmap v [cts::reloc_eval_metrics [join $::q_moved " "] $::q_mode] {expr {double($v)}}]
    set ::q_mode 1; set ::q_moved {}
    return $r
  }
  estimate_parasitics -placement
  return [list [expr {[sta::total_negative_slack_cmd max]*1e12}] [expr {[sta::worst_slack_cmd max]*1e12}] [expr {[sta::total_negative_slack_cmd min]*1e12}] [expr {[sta::worst_slack_cmd min]*1e12}]]
}
proc is_cbuf {inst} {
  set m [$inst getMaster]; if {[$m isBlock]} { return 0 }
  set o [clk_out_net $inst]; if {$o eq "NULL" || [$o getSigType] ne "CLOCK"} { return 0 }
  set ni 0; foreach it [$inst getITerms] { if {[[$it getMTerm] getSigType] in {SIGNAL CLOCK} && [[$it getMTerm] getIoType] eq "INPUT"} { incr ni } }
  return [expr {$ni == 1}]
}
# out-of-box distance (DBU), load-pin centroid and load count of the output net of inst
proc loadinfo {inst} {
  set o [clk_out_net $inst]; set xs {}; set ys {}
  foreach it [$o getITerms] {
    if {[$it getInst] eq $inst} continue
    lassign [$it getAvgXY] ok x y
    if {!$ok} { lassign [[$it getInst] getLocation] x y }
    lappend xs $x; lappend ys $y
  }
  if {![llength $xs]} { return {} }
  set x0 [tcl::mathfunc::min {*}$xs]; set x1 [tcl::mathfunc::max {*}$xs]; set y0 [tcl::mathfunc::min {*}$ys]; set y1 [tcl::mathfunc::max {*}$ys]
  lassign [$inst getLocation] dx dy
  set out [expr {max(0, $x0 - $dx, $dx - $x1) + max(0, $y0 - $dy, $dy - $y1)}]
  set cx [expr {int([::tcl::mathop::+ {*}$xs] / [llength $xs])}]
  set cy [expr {int([::tcl::mathop::+ {*}$ys] / [llength $ys])}]
  return [list $out $cx $cy [llength $xs]]
}
proc driver_buf {inst} {
  set it [clk_in_iterm $inst]; if {$it eq "NULL"} { return "" }
  set n [$it getNet]; if {$n eq "NULL"} { return "" }
  foreach d [$n getITerms] { if {[[$d getMTerm] getIoType] eq "OUTPUT" && [is_cbuf [$d getInst]]} { return [$d getInst] } }
  return ""
}

proc relocate_far_clock_buffers {block minum dbu rd} {
  set cands {}
  foreach inst [$block getInsts] {
    if {![is_cbuf $inst]} continue
    set li [loadinfo $inst]; if {![llength $li]} continue
    if {[lindex $li 0] > $minum * $dbu} { lappend cands [list [lindex $li 0] [$inst getName]] }
  }
  set cands [lsort -real -decreasing -index 0 $cands]
  set cur [m4]; set f [open $rd/metrics_before.csv w]; puts $f "setup_tns_ps,setup_wns_ps,hold_tns_ps,hold_wns_ps"; puts $f [join $cur ,]; close $f
  # dist_to_target_um = distance from the placed site to the target (load centroid); moved_um = distance moved (Manhattan)
  set log [open $rd/reloc.csv w]
  puts $log "step,cells,out_of_box_um,dist_to_target_um,moved_um,setup_tns,setup_wns,hold_tns,hold_wns,verdict"
  puts "RELOC candidates [llength $cands] (min $minum um)"
  set k 0
  foreach c $cands {
    set inst [$block findInst [lindex $c 1]]; set li [loadinfo $inst]
    if {[lindex $li 0] <= $minum * $dbu} continue
    set bundle {}; set disp {}; set mv {}; set b $inst
    for {set lev 0} {$lev < 4 && $b ne ""} {incr lev} {
      set li [loadinfo $b]; if {$lev > 0 && [lindex $li 0] <= $minum * $dbu} break
      lappend bundle [list $b [$b getLocation] [$b getOrient]]
      set d [place_at_legal_site $block $b [lindex $li 1] [lindex $li 2] reloc]
      if {$d < 0} { break }
      lappend disp [format %.1f [expr {double($d) / $dbu}]]
      lassign [lindex $bundle end 1] ox oy; lassign [$b getLocation] nx ny
      lappend mv [format %.1f [expr {(abs($nx - $ox) + abs($ny - $oy)) / double($dbu)}]]
      set b [driver_buf $b]
    }
    foreach e $bundle { lappend ::q_moved [[lindex $e 0] getName] }
    set new [m4]
    set g [expr {([lindex $new 0] - [lindex $cur 0]) + ([lindex $new 2] - [lindex $cur 2])}]
    set ok [expr {$g > 1.0 && [lindex $new 1] >= [lindex $cur 1] - 0.5 && [lindex $new 3] >= [lindex $cur 3] - 0.02}]
    set names {}; foreach e $bundle { lappend names [[lindex $e 0] getName] }
    puts $log [join [list [incr k] [join $names ";"] [format %.1f [expr {[lindex $c 0] / double($dbu)}]] [join $disp ";"] [join $mv ";"] {*}[lmap v $new {format %.1f $v}] [expr {$ok ? "KEEP" : "ROLLBACK"}]] ,]; flush $log
    if {$ok} { set cur $new; foreach e $bundle { lassign $e bi loc ori; qx_move $bi {*}$loc } } else {
      foreach e [lreverse $bundle] { lassign $e bi loc ori; $bi setOrient $ori; $bi setLocation {*}$loc; lappend ::q_moved [$bi getName] }
      array unset ::site_occ_cache
      foreach key [array names ::QX] { set ::site_occ_cache($key) $::QX($key) }
    }
  }
  close $log
  set f [open $rd/metrics_after.csv w]; puts $f "setup_tns_ps,setup_wns_ps,hold_tns_ps,hold_wns_ps"; puts $f [join $cur ,]; close $f
}

relocate_far_clock_buffers $block $minum $dbu $rd
if {!$::q_full} { cts::reloc_eval_metrics "" 2 }
write_db $rd/edited.odb
