# Load-centred re-placement of clock buffers that tier-exact legalization pushed away from their loads.
#
# Tier-exact legalization (tier_legalize.tcl) moves an illegal post-CTS cell to the NEAREST legal site of its tier;
# a clock buffer that clock_tree_synthesis / repair_clock_nets dropped on top of a macro therefore lands on the macro
# edge, possibly on the side away from its loads.  For every clock buffer (one signal input, output on a CLOCK net,
# not a macro) whose legalization displacement is > 10 um AND whose distance outside the bounding box of its load pins
# grew during legalization, this file places it at the nearest EMPTY site-aligned span of its own tier around the
# centroid of its load pins (place_at_legal_site, radius 150 um).  The new position is kept only if it is strictly
# closer to the load box than the legalized one; otherwise the legalized position is restored.  No connection, master
# or tier change; no STA; deterministic (instances visited in name order).  Cells on a tier without rows of their
# site (bottom NanGate45 tier of asap7_nangate45_3D) keep their legalized position (reported as no_site).
#   usage: set snap [clock_buffer_snapshot $block]                  (before legalization)
#          relegalize_clock_buffers $block $snap <label> <csv>      (after legalization)
# Requires early_clock.tcl (clk_out_net, place_at_legal_site, site occupancy cache).

proc is_clock_buffer {inst} {
  set m [$inst getMaster]; if {[$m isBlock]} { return 0 }
  set o [clk_out_net $inst]; if {$o eq "NULL" || [$o getSigType] ne "CLOCK"} { return 0 }
  set ni 0
  foreach it [$inst getITerms] {
    if {[[$it getMTerm] getSigType] in {SIGNAL CLOCK} && [[$it getMTerm] getIoType] eq "INPUT"} { incr ni }
  }
  return [expr {$ni == 1}]
}
# {out_of_box_dbu cx cy nloads} of the load pins of inst at location (x,y); {} if no load
proc clock_load_box {inst x y} {
  set o [clk_out_net $inst]; set xs {}; set ys {}
  foreach it [$o getITerms] {
    if {[$it getInst] eq $inst} continue
    lassign [$it getAvgXY] ok px py
    if {!$ok} { lassign [[$it getInst] getLocation] px py }
    lappend xs $px; lappend ys $py
  }
  foreach bt [$o getBTerms] { lassign [$bt getFirstPinLocation] ok px py; if {$ok} { lappend xs $px; lappend ys $py } }
  if {![llength $xs]} { return {} }
  set x0 [tcl::mathfunc::min {*}$xs]; set x1 [tcl::mathfunc::max {*}$xs]
  set y0 [tcl::mathfunc::min {*}$ys]; set y1 [tcl::mathfunc::max {*}$ys]
  set out [expr {max(0, $x0 - $x, $x - $x1) + max(0, $y0 - $y, $y - $y1)}]
  return [list $out [expr {int([::tcl::mathop::+ {*}$xs] / [llength $xs])}] [expr {int([::tcl::mathop::+ {*}$ys] / [llength $ys])}] [llength $xs]]
}
proc clock_buffer_snapshot {block} {
  set s [dict create]
  foreach inst [$block getInsts] {
    if {[is_clock_buffer $inst]} { dict set s [$inst getName] [$inst getLocation] }
  }
  return $s
}
proc relegalize_clock_buffers {block snap label csv} {
  set dbu [[ord::get_db_tech] getDbUnitsPerMicron]
  set minum 10
  set ::legal_site_radius_um 150
  array unset ::site_occ_cache          ;# occupancy of the legalized placement
  set f [open $csv w]
  puts $f "cell,master,legal_disp_um,out_box_before_um,out_box_legal_um,out_box_new_um,move_um,result"
  set n 0; set kept 0
  foreach name [lsort [dict keys $snap]] {
    set inst [$block findInst $name]; if {$inst eq "NULL" || ![is_clock_buffer $inst]} continue
    lassign [dict get $snap $name] bx by; lassign [$inst getLocation] lx ly
    set d [expr {abs($lx - $bx) + abs($ly - $by)}]
    if {$d <= $minum * $dbu} continue
    set lb0 [clock_load_box $inst $bx $by]; set lb1 [clock_load_box $inst $lx $ly]
    if {![llength $lb1] || [lindex $lb1 0] <= [lindex $lb0 0]} continue
    incr n
    set lo [$inst getOrient]
    set r [place_at_legal_site $block $inst [lindex $lb1 1] [lindex $lb1 2] relegal_$label]
    set res no_site; set onew -; set mv 0
    if {$r >= 0} {
      lassign [$inst getLocation] nx ny; set lb2 [clock_load_box $inst $nx $ny]
      set onew [format %.2f [expr {[lindex $lb2 0] / double($dbu)}]]
      if {[lindex $lb2 0] < [lindex $lb1 0]} {
        set res moved; incr kept; set mv [expr {abs($nx - $lx) + abs($ny - $ly)}]
      } else {
        $inst setOrient $lo; $inst setLocation $lx $ly; set res not_closer
      }
    }
    puts $f [join [list $name [[$inst getMaster] getName] [format %.2f [expr {$d / double($dbu)}]] \
      [format %.2f [expr {[lindex $lb0 0] / double($dbu)}]] [format %.2f [expr {[lindex $lb1 0] / double($dbu)}]] $onew \
      [format %.2f [expr {$mv / double($dbu)}]] $res] ,]
  }
  close $f
  puts "CLOCK_RELEGAL $label candidates=$n moved=$kept min_um=$minum radius_um=$::legal_site_radius_um csv=$csv"
  return $kept
}
