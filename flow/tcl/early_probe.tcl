# Decision probe: virtual early-clock edits of the Phase-1 reference database, register clock arrivals predicted
# stage by stage (placement parasitics; boundary arrivals of non-buffer cells frozen to the unedited tree, except the
# loads of the clock-port-driven entry net, which are re-seeded from the edited net).  Sourced by the decision
# sessions (early_decide.tcl, early_hub.tcl) after the database is loaded; requires early_clock.tcl.
#   probe_candidates <cands_dir> <reports_dir>
#     <cands_dir>/list.txt (one cid per line) and <cid>.tsv plan fragments (early_clock.tcl format)
#     <reports_dir>/arr_<cid>.csv : register clock pin, mode (min|max), predicted rise arrival (ps)
#     <reports_dir>/arr_base.csv  : the same for the unedited tree; raw_base.csv = every predicted stage of it

proc snap_arrivals {out id} {
  set raw "$out/raw_$id.csv"
  predict_clock_arrivals $raw
  # keep register clock pins (kind sink), rise edge: pin,mode,pred_ps
  set fi [open $raw r]; set fo [open "$out/arr_$id.csv" w]; gets $fi; puts $fo "pin,mode,pred_ps"
  while {[gets $fi line] >= 0} {
    set c [split $line ,]
    if {[lindex $c 1] eq "sink" && [lindex $c 3] eq "rise"} { puts $fo "[lindex $c 0],[lindex $c 2],[lindex $c 6]" }
  }
  close $fi; close $fo
  if {$id ne "base"} { file delete $raw }
}
# input pins of the loads of every clock-port-driven net
proc port_load_pins {} {
  set out {}
  foreach clk [all_clocks] {
    foreach src [get_property $clk sources] {
      set bt [[ord::get_db_block] findBTerm [get_full_name $src]]
      if {$bt eq "NULL" || [$bt getNet] eq "NULL"} continue
      foreach it [[$bt getNet] getITerms] { lappend out "[[$it getInst] getName]/[[$it getMTerm] getName]" }
    }
  }
  return $out
}
# candidate snapshot with the entry-net loads re-seeded from the edited net (live boundaries)
proc snap_candidate {out id} {
  set frozen $::env(CTS_STAGE_BOUNDARY_CSV)
  unset ::env(CTS_STAGE_BOUNDARY_CSV)
  predict_clock_arrivals "$out/live_$id.csv"
  set live [dict create]
  set fi [open "$out/live_$id.csv.boundaries.csv" r]; gets $fi
  while {[gets $fi line] >= 0} { dict set live [lindex [split $line ,] 0] $line }
  close $fi
  set ports [port_load_pins]
  set fi [open $frozen r]; set fo [open "$out/bnd_$id.csv" w]; gets $fi hdr; puts $fo $hdr
  set done [dict create]
  while {[gets $fi line] >= 0} {
    set k [lindex [split $line ,] 0]; set pk [lindex [split $k |] 0]
    if {[lsearch -exact $ports $pk] >= 0 && [dict exists $live $k]} { puts $fo [dict get $live $k] } else { puts $fo $line }
    dict set done $k 1
  }
  close $fi
  dict for {k line} $live {
    if {![dict exists $done $k] && [lsearch -exact $ports [lindex [split $k |] 0]] >= 0} { puts $fo $line }
  }
  close $fo
  file delete "$out/live_$id.csv" "$out/live_$id.csv.boundaries.csv"
  set ::env(CTS_STAGE_BOUNDARY_CSV) "$out/bnd_$id.csv"
  snap_arrivals $out $id
  file delete "$out/bnd_$id.csv"
  set ::env(CTS_STAGE_BOUNDARY_CSV) $frozen
}

proc probe_candidates {cands out} {
  file mkdir $out
  set block [ord::get_db_block]
  set t0 [clock milliseconds]
  snap_arrivals $out base
  # A hub next to a buffer A whose input is a boundary pin (A on the port-driven entry net) introduces a new boundary
  # pin; it is seeded with A's own frozen input arrival / slew (same net, adjacent location).
  set fi [open "$out/raw_base.csv.boundaries.csv" r]; set fo [open "$out/boundaries_aug.csv" w]
  gets $fi hdr; puts $fo $hdr
  while {[gets $fi line] >= 0} {
    puts $fo $line
    set k [lindex [split $line ,] 0]; set rest [join [lrange [split $line ,] 1 end] ,]
    set kp [split $k |]; set pinpath [lindex $kp 0]; set slash [string last / $pinpath]
    if {$slash < 0} continue
    set inst [string range $pinpath 0 [expr {$slash-1}]]; set pn [string range $pinpath [expr {$slash+1}] end]
    foreach t {0 1} { puts $fo "clkbuf_hub_${inst}_t${t}/${pn}|[lindex $kp 1]|[lindex $kp 2],$rest" }
  }
  close $fi; close $fo
  set ::env(CTS_STAGE_BOUNDARY_CSV) "$out/boundaries_aug.csv"
  set lf [open "$cands/list.txt" r]
  set n 0
  while {[gets $lf cid] >= 0} {
    if {$cid eq ""} continue
    set undo [apply_early_clock_plan $block "$cands/$cid.tsv" $cid]
    estimate_parasitics -placement
    snap_candidate $out $cid
    undo_early_clock_plan $undo
    incr n
  }
  close $lf
  unset ::env(CTS_STAGE_BOUNDARY_CSV)
  estimate_parasitics -placement
  puts "EARLY_EVAL candidates=$n elapsed_ms=[expr {[clock milliseconds]-$t0}]"
}
