# Early-clock construction: apply an early-clock plan to a constructed clock tree.
#
# The plan is decided once per case (cts::early_* commands) on the Phase-1 reference tree.
# This file realizes it, identically in the Phase-1 session (right after clock_tree_synthesis) and in the delivery
# session (right after clock_tree_synthesis, before repair / legalization), so the LP sees the same early structure
# that is later delivered.  The decision probes (early_eval.tcl) use the same procedures for virtual edits.
#
# Plan file (TSV, header line, one row per early group):
#   gid  mode(new|reparent)  master  x  y  parent_driver  leaf  members
#     mode new      : create leaf buffer clkbuf_early_<gid> (master, at x,y DBU) driving net clknet_early_<gid>; the
#                     buffer input joins the output net of <parent_driver>; every member register clock pin
#                     (inst/pin, ';'-separated) moves from its leaf net to clknet_early_<gid>.
#     mode reparent : the group is exactly the register load of regular leaf <leaf>; that leaf buffer's input moves
#                     to the output net of <parent_driver> (no new cell).
#   parent_driver = hub:<A>:<tier>:<master>: the early leaf is fed by a per-tier hub buffer clkbuf_hub_<A>_t<tier>
#                     placed next to the existing clock buffer <A>, input on A's INPUT net, so the hub skips A's stage.
#                     All groups naming the same hub share one instance.
# A member whose clock pin is not driven by a regular leaf buffer (clkbuf_leaf_*) is left in place and counted
# (EARLY_APPLY skipped_members); the LP bound 0 of every member prevents that case.
# Env: EARLY_CLOCK_LEGAL=1 places every new cell on the nearest empty site of its own tier (ON chain);
#      EARLY_HUB_ANCHOR_FALLBACK=1 replaces a missing hub anchor by the regular root of this tree (multi-hub prefix
#      arms, whose plans were measured on the Phase-1 tree of the OFF arm).

proc clk_out_net {inst} {
  foreach it [$inst getITerms] {
    if {[$it isOutputSignal] && [$it getNet] ne "NULL"} { return [$it getNet] }
  }
  return "NULL"
}
proc clk_in_iterm {inst} {
  foreach it [$inst getITerms] {
    if {[$it isInputSignal] && [[$it getMTerm] getSigType] ni {POWER GROUND}} { return $it }
  }
  return "NULL"
}
proc clk_out_iterm {inst} {
  foreach it [$inst getITerms] {
    if {[$it isOutputSignal]} { return $it }
  }
  return "NULL"
}

# ---------------------------------------------------------------------------------------------------------------------
# Legal placement of one cell: the nearest EMPTY, site-aligned span of a row of the cell's own tier (same site as its
# master).  Cells of the other tier do not block (face-to-face stack).  Cost = |dx| + |dy| from the target location;
# search radius ::legal_site_radius_um (20 um; 150 um for clock-buffer re-placement and relocation).  Without a span
# within the radius the cell keeps its location and EARLY_LEGAL_FAIL is printed.
# Tier of a cell = master name containing "upper" (1) / "bottom" (0).
if {![info exists ::legal_site_radius_um]} { set ::legal_site_radius_um 20.0 }
proc early_tier_of {mname} {
  if {[string match -nocase "*upper*" $mname]} { return 1 }
  if {[string match -nocase "*bottom*" $mname]} { return 0 }
  return -1
}
# occupancy per (tier, site): list of rows {y0 y1 x0 x1 sitew orient intervals}, cached in ::site_occ_cache
proc site_occupancy {block tier site} {
  set key "${tier}:[$site getName]"
  if {[info exists ::site_occ_cache($key)]} { return $key }
  set rows {}
  foreach r [$block getRows] {
    if {[[$r getSite] getName] ne [$site getName]} continue
    set bb [$r getBBox]
    lappend rows [list [$bb yMin] [$bb yMax] [$bb xMin] [$bb xMax] [$site getWidth] [$r getOrient]]
  }
  set rows [lsort -integer -index 0 $rows]
  array set iv {}
  foreach inst [$block getInsts] {
    if {[$inst getPlacementStatus] eq "NONE" || [$inst getPlacementStatus] eq "UNPLACED"} continue
    set t [early_tier_of [[$inst getMaster] getName]]
    if {$t != $tier && $t != -1} continue
    # cells created by this file are added one by one as they are placed (site_occupancy_add)
    if {[string match "clkbuf_early_*" [$inst getName]] || [string match "clkbuf_hub_*" [$inst getName]]} continue
    set bb [$inst getBBox]; set ylo [$bb yMin]; set yhi [$bb yMax]
    set i 0
    foreach r $rows {
      if {[lindex $r 1] > $ylo && [lindex $r 0] < $yhi} { lappend iv($i) [list [$bb xMin] [$bb xMax]] }
      incr i
    }
  }
  set out {}; set i 0
  foreach r $rows {
    set l {}; if {[info exists iv($i)]} { set l [lsort -integer -index 0 $iv($i)] }
    lappend out [concat $r [list $l]]; incr i
  }
  set ::site_occ_cache($key) $out
  return $key
}
proc site_occupancy_add {key x0 y0 x1 y1} {
  set new {}
  foreach r $::site_occ_cache($key) {
    if {[lindex $r 1] > $y0 && [lindex $r 0] < $y1} {
      set l [lindex $r 6]; lappend l [list $x0 $x1]; set r [lreplace $r 6 6 [lsort -integer -index 0 $l]]
    }
    lappend new $r
  }
  set ::site_occ_cache($key) $new
}
# place inst at the nearest legal empty spot to (tx, ty) (lower-left, DBU); returns the displacement in DBU or -1
proc place_at_legal_site {block inst tx ty tag} {
  set m [$inst getMaster]; set site [$m getSite]
  set name [$inst getName]
  set tier [early_tier_of [$m getName]]
  set rad $::legal_site_radius_um
  set dbu [[ord::get_db_tech] getDbUnitsPerMicron]; set R [expr {int($rad * $dbu)}]
  if {$site eq "NULL" || $tier < 0} {
    puts "EARLY_LEGAL_FAIL $tag $name reason=no_site_or_tier master=[$m getName]"; return -1
  }
  set key [site_occupancy $block $tier $site]
  set w [$m getWidth]; set h [$m getHeight]
  set best -1; set bx 0; set by 0; set bo R0
  foreach r $::site_occ_cache($key) {
    lassign $r y0 y1 x0 x1 sw orient l
    if {$y1 - $y0 != $h} continue
    set dy [expr {abs($y0 - $ty)}]
    if {$dy > $R || ($best >= 0 && $dy >= $best)} continue
    # free gaps of this row segment: the interval list holds every cell overlapping the row's y range, also cells of
    # other segments at the same y (rows split by macros), so gaps are clipped to [x0, x1] of this segment
    set cur $x0; set gaps {}
    foreach seg $l {
      lassign $seg a b
      if {$a > $cur} { lappend gaps [list $cur [expr {min($a, $x1)}]] }
      if {$b > $cur} { set cur $b }
      if {$cur >= $x1} break
    }
    if {$cur < $x1} { lappend gaps [list $cur $x1] }
    foreach g $gaps {
      lassign $g gl gr
      if {$gr - $gl < $w} continue
      # site-aligned positions inside the gap closest to tx
      set lo [expr {$x0 + int(ceil(double($gl - $x0) / $sw)) * $sw}]
      set hi [expr {$x0 + int(floor(double($gr - $w - $x0) / $sw)) * $sw}]
      if {$hi < $lo} continue
      set xc [expr {$x0 + int(round(double($tx - $x0) / $sw)) * $sw}]
      if {$xc < $lo} { set xc $lo } elseif {$xc > $hi} { set xc $hi }
      set c [expr {abs($xc - $tx) + $dy}]
      if {$c <= $R && ($best < 0 || $c < $best)} { set best $c; set bx $xc; set by $y0; set bo $orient }
    }
  }
  if {$best < 0} { puts "EARLY_LEGAL_FAIL $tag $name reason=no_empty_span_within_${rad}um target=($tx,$ty)"; return -1 }
  # orientation before location (the location of a flipped cell is its lower-left after the flip)
  $inst setOrient $bo
  $inst setLocation $bx $by
  $inst setPlacementStatus PLACED
  site_occupancy_add $key $bx $by [expr {$bx + $w}] [expr {$by + $h}]
  puts [format "EARLY_LEGAL %s %s target=(%d,%d) placed=(%d,%d) orient=%s disp_um=%.3f" $tag $name $tx $ty $bx $by $bo [expr {double($best) / $dbu}]]
  return $best
}

# Regular root of this tree: the clock-port-driven buffer whose subtree holds the most register sinks under regular
# leaf buffers (clkbuf_leaf_*); ties go to the larger name.
proc regular_clock_root {block} {
  set best ""; set bestn -1
  foreach bt [$block getBTerms] {
    set n [$bt getNet]; if {$n eq "NULL" || [$n getSigType] ne "CLOCK"} continue
    foreach it [$n getITerms] {
      if {![$it isInputSignal]} continue
      set b [$it getInst]; set o [clk_out_net $b]; if {$o eq "NULL"} continue
      set cnt 0; set stack [list [list $b 0]]
      while {[llength $stack]} {
        lassign [lindex $stack end] x leafseen; set stack [lrange $stack 0 end-1]
        set on [clk_out_net $x]; if {$on eq "NULL"} continue
        set lf [expr {$leafseen || [string match "clkbuf_leaf*" [$x getName]]}]
        foreach l [$on getITerms] {
          if {![$l isInputSignal]} continue
          set li [$l getInst]
          if {[regexp -nocase {DFF|SDF|DLL|DLH|DHL} [[$li getMaster] getName]]} { if {$lf} { incr cnt } } \
          elseif {[clk_out_net $li] ne "NULL" && [[clk_out_net $li] getSigType] eq "CLOCK"} { lappend stack [list $li $lf] }
        }
      }
      if {$cnt > $bestn || ($cnt == $bestn && [$b getName] > $best)} { set bestn $cnt; set best [$b getName] }
    }
  }
  puts "EARLY_ROOT regular root of this tree = $best ($bestn register sinks under regular leaves)"
  return $best
}

# hub anchors of a plan that do not exist in this database
proc early_clock_missing_anchors {block planfile} {
  set missing {}
  set fh [open $planfile r]; gets $fh header
  while {[gets $fh line] >= 0} {
    set pd [lindex [split $line "\t"] 5]
    if {[string match "hub:*" $pd]} {
      set a [lindex [split $pd ":"] 1]
      if {[$block findInst $a] eq "NULL" && [lsearch $missing $a] < 0} { lappend missing $a }
    }
  }
  close $fh
  return $missing
}

# Apply a plan; returns an undo list (used by the virtual-edit evaluator); raises on any unresolved name.
proc apply_early_clock_plan {block planfile {tag apply}} {
  set db [ord::get_db]
  set fh [open $planfile r]; gets $fh header
  set undo {}; set n_new 0; set n_rep 0; set n_mem 0; set n_skip 0
  set legal [expr {[info exists ::env(EARLY_CLOCK_LEGAL)] && $::env(EARLY_CLOCK_LEGAL)}]
  if {$legal} { array unset ::site_occ_cache }
  while {[gets $fh line] >= 0} {
    if {[string trim $line] eq ""} continue
    lassign [split $line "\t"] gid mode master x y pdrv leaf members
    if {[string match "hub:*" $pdrv]} {
      lassign [split $pdrv ":"] - hA ht hm
      set hname "clkbuf_hub_${hA}_t${ht}"
      set hub [$block findInst $hname]
      if {$hub eq "NULL"} {
        set ai [$block findInst $hA]
        if {$ai eq "NULL" && [info exists ::env(EARLY_HUB_ANCHOR_FALLBACK)] && $::env(EARLY_HUB_ANCHOR_FALLBACK)} {
          set r [regular_clock_root $block]; puts "EARLY_ANCHOR_FALLBACK group $gid anchor $hA missing -> $r"
          if {$r ne ""} { set ai [$block findInst $r] }
        }
        if {$ai eq "NULL"} { error "early clock: hub anchor $hA not found (group $gid)" }
        set anet [[clk_in_iterm $ai] getNet]
        set hmm [$db findMaster $hm]
        if {$hmm eq "NULL"} { error "early clock: hub master $hm not found" }
        set hub [odb::dbInst_create $block $hmm $hname]
        lassign [$ai getLocation] ax ay
        $hub setLocation [expr {$ax + [[$ai getMaster] getWidth]}] $ay
        $hub setPlacementStatus PLACED
        if {$legal} { place_at_legal_site $block $hub [expr {$ax + [[$ai getMaster] getWidth]}] $ay $tag }
        set hn [odb::dbNet_create $block "clknet_hub_${hA}_t${ht}"]
        $hn setSigType CLOCK
        [clk_in_iterm $hub] connect $anet
        [clk_out_iterm $hub] connect $hn
        lappend undo [list hub $hub $hn]
      }
      set pnet [clk_out_net $hub]
    } else {
      set pinst [$block findInst $pdrv]
      if {$pinst eq "NULL"} { error "early clock: parent driver $pdrv not found (group $gid)" }
      set pnet [clk_out_net $pinst]
      if {$pnet eq "NULL"} { error "early clock: parent driver $pdrv has no output net (group $gid)" }
    }
    if {$mode eq "reparent"} {
      set li [$block findInst $leaf]
      if {$li eq "NULL"} { error "early clock: leaf $leaf not found (group $gid)" }
      # the leaf must drive exactly the listed register clock pins (latches count as registers)
      set want [lsort [split $members ";"]]; set have {}
      foreach o [[clk_out_net $li] getITerms] {
        if {[$o isInputSignal] && [regexp -nocase {DFF|SDF|DLL|DLH|DHL} [[[$o getInst] getMaster] getName]]} { lappend have "[[$o getInst] getName]/[[$o getMTerm] getName]" }
      }
      if {[lsort $have] ne $want} { error "early clock: leaf $leaf drives [llength $have] registers, plan lists [llength $want] (group $gid)" }
      set it [clk_in_iterm $li]; set old [$it getNet]
      $it disconnect; $it connect $pnet
      lappend undo [list reparent $it $old]
      incr n_rep
      continue
    }
    set m [$db findMaster $master]
    if {$m eq "NULL"} { error "early clock: master $master not found (group $gid)" }
    set bname "clkbuf_early_${gid}"; set nname "clknet_early_${gid}"
    set b [odb::dbInst_create $block $m $bname]
    $b setLocation [expr {int($x)}] [expr {int($y)}]
    $b setPlacementStatus PLACED
    if {$legal} { place_at_legal_site $block $b [expr {int($x)}] [expr {int($y)}] $tag }
    set n [odb::dbNet_create $block $nname]
    $n setSigType CLOCK
    [clk_in_iterm $b] connect $pnet
    [clk_out_iterm $b] connect $n
    set moved {}
    foreach mp [split $members ";"] {
      set slash [string last "/" $mp]
      set iname [string range $mp 0 [expr {$slash-1}]]; set pname [string range $mp [expr {$slash+1}] end]
      set ri [$block findInst $iname]
      if {$ri eq "NULL"} { error "early clock: member $iname not found (group $gid)" }
      set it [$ri findITerm $pname]
      set old [$it getNet]
      set drv ""
      if {$old ne "NULL"} { foreach o [$old getITerms] { if {[$o isOutputSignal]} { set drv [[$o getInst] getName] } } }
      if {![string match "clkbuf_leaf_*" $drv]} { incr n_skip; puts "EARLY_SKIP $tag $gid $mp driver=$drv"; continue }
      $it disconnect; $it connect $n
      lappend moved [list $it $old]; incr n_mem
    }
    lappend undo [list new $b $n $moved]
    incr n_new
  }
  close $fh
  puts "EARLY_APPLY $tag hubs=[llength [lsearch -all -index 0 $undo hub]] new_groups=$n_new reparented=$n_rep moved_members=$n_mem skipped_members=$n_skip"
  return $undo
}

proc undo_early_clock_plan {undo} {
  foreach u [lreverse $undo] {
    set kind [lindex $u 0]
    if {$kind eq "reparent"} {
      lassign $u - it old; $it disconnect; $it connect $old
    } elseif {$kind eq "hub"} {
      lassign $u - b n
      foreach it [$b getITerms] { if {[$it getNet] ne "NULL"} { $it disconnect } }
      odb::dbInst_destroy $b
      odb::dbNet_destroy $n
    } else {
      lassign $u - b n moved
      foreach mv $moved { lassign $mv it old; $it disconnect; $it connect $old }
      foreach it [$b getITerms] { if {[$it getNet] ne "NULL"} { $it disconnect } }
      odb::dbInst_destroy $b
      odb::dbNet_destroy $n
    }
  }
}
