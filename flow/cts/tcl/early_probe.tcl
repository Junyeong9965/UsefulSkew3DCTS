# Decision probe: virtual early-clock edits of the Phase-1 reference database, register clock arrivals predicted
# stage by stage (placement parasitics; boundary arrivals of non-buffer cells frozen to the unedited tree, except the
# loads of the clock-port-driven entry net, which are re-seeded from the edited net).  Sourced by the decision
# session (early_decision.tcl) after the database is loaded; requires early_clock.tcl.
#   probe_candidates <cands_dir> <reports_dir>
#     <cands_dir>/list.txt (one cid per line) and <cid>.tsv plan fragments (early_clock.tcl format)
#     <reports_dir>/arr_<cid>.csv : register clock pin, mode (min|max), predicted rise arrival (ps)
#     <reports_dir>/arr_base.csv  : the same for the unedited tree; raw_base.csv = every predicted stage of it
#   env CTS3D_PROBE_FAST (default 1): fast candidate passes (snap_candidate_fast); 0 = snap_candidate

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
# fast candidate snapshot (cts::probe_fast_init done): one predictor pass with the frozen boundaries, the entry-net loads
# re-seeded in C++ (Sta::vertexSlew + clock-port arrival + derated wire delay, proven bit-exact against STA at init)
# and the nets of the plan edits re-estimated incrementally; writes the same arr_<id>.csv and raw_<id>.csv.boundaries.csv
# as snap_candidate without the whole-design parasitics, delay calculation and arrival search of the live pass.
proc snap_candidate_fast {out id} {
  set pf "$out/ports_$id.txt"; set fo [open $pf w]
  foreach p [port_load_pins] { puts $fo $p }
  close $fo
  set ::env(CTS_STAGE_PORT_SEED_PINS) $pf; set ::env(CTS_STAGE_NO_ROWS) 1; set ::env(CTS_STAGE_ARR_CSV) "$out/arr_$id.csv"
  predict_clock_arrivals "$out/raw_$id.csv"
  unset ::env(CTS_STAGE_PORT_SEED_PINS) ::env(CTS_STAGE_NO_ROWS) ::env(CTS_STAGE_ARR_CSV)
  file delete $pf
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
  # fast candidate passes (default); CTS3D_PROBE_FAST=0 = whole-design parasitics + live pass per candidate
  set fast [expr {![info exists ::env(CTS3D_PROBE_FAST)] || $::env(CTS3D_PROBE_FAST) ne "0"}]
  # fail-closed: if the port-load arrival check of the init fails, every candidate takes the whole-design path
  if {$fast && ![cts::probe_fast_init]} {
    puts "EARLY_EVAL fast probe init check failed: whole-design path for every candidate"
    set fast 0
  }
  set lf [open "$cands/list.txt" r]
  set n 0
  while {[gets $lf cid] >= 0} {
    if {$cid eq ""} continue
    set undo [apply_early_clock_plan $block "$cands/$cid.tsv" $cid]
    if {$fast} {
      snap_candidate_fast $out $cid
    } else {
      estimate_parasitics -placement
      snap_candidate $out $cid
    }
    undo_early_clock_plan $undo
    incr n
  }
  close $lf
  unset ::env(CTS_STAGE_BOUNDARY_CSV)
  # restore the parasitics of the unedited tree for the rest of the session (fast: only the nets of the last undo are
  # re-estimated); a shard session (early_eval.tcl) exits right after the probe, so it skips the restore
  if {![info exists ::early_probe_shard]} {
    if {$fast} { cts::probe_fast_end } else { estimate_parasitics -placement }
  }
  puts "EARLY_EVAL candidates=$n fast=$fast elapsed_ms=[expr {[clock milliseconds]-$t0}]"
}

# probe_candidates_sharded <cands> <out>: the same probe as probe_candidates, with the candidate list split round-robin
# over EARLY_PROBE_SHARDS (default min(THREADS, 16)) separate 1-thread OpenROAD sessions (early_eval.tcl) that run at
# the same time.  Every candidate is applied to the unedited reference database and undone, so its report does not
# depend on the other candidates of its session; the shared base files (raw_base.csv, its boundaries, boundaries_aug.csv, arr_base.csv)
# must be byte-identical in every shard, otherwise the probe fails.  With 1 shard (or fewer candidates than 2) the
# candidates are probed in this session (probe_candidates).
proc probe_candidates_sharded {cands out} {
  set ids {}
  set lf [open "$cands/list.txt" r]
  while {[gets $lf cid] >= 0} { if {$cid ne ""} { lappend ids $cid } }
  close $lf
  set th [expr {[info exists ::env(THREADS)] ? $::env(THREADS) : 16}]
  set k [expr {[info exists ::env(EARLY_PROBE_SHARDS)] ? $::env(EARLY_PROBE_SHARDS) : min($th, 16)}]
  if {$k > [llength $ids]} { set k [llength $ids] }
  if {$k < 2} { probe_candidates $cands $out; return }
  set t0 [clock milliseconds]
  file mkdir $out
  set sh "$out/../shards"; file delete -force $sh
  for {set s 0} {$s < $k} {incr s} {
    file mkdir "$sh/c$s"
    set fo [open "$sh/c$s/list.txt" w]
    for {set i $s} {$i < [llength $ids]} {incr i $k} {
      set cid [lindex $ids $i]; puts $fo $cid
      file link -symbolic "$sh/c$s/$cid.tsv" [file normalize "$cands/$cid.tsv"]
    }
    close $fo
  }
  # one shell starts the shard sessions and waits for all of them; each shard writes its reports to $sh/s<s>/reports
  set cmd ""
  for {set s 0} {$s < $k} {incr s} {
    append cmd "EARLY_CANDS='$sh/c$s' bash '$::env(OPENROAD_SCRIPTS_DIR)/../openroad_run.sh' '$sh/s$s' '$::env(PLATFORM)' "
    append cmd "'$::env(DESIGN_NICKNAME)' '$::env(PROBE_INPUT_ODB)' '$::env(PROBE_INPUT_SDC)' "
    append cmd "'$::env(OPENROAD_SCRIPTS_DIR)/early_eval.tcl' 1 & pids=\"\$pids \$!\"; "
  }
  append cmd "rc=0; for p in \$pids; do wait \$p || rc=1; done; exit \$rc"
  if {[catch {exec bash -c $cmd} err]} { error "EARLY_EVAL sharded probe failed: $err" }
  set shared {raw_base.csv raw_base.csv.boundaries.csv boundaries_aug.csv arr_base.csv}
  foreach f [glob -nocomplain -tails -directory "$sh/s0/reports" *] { file copy -force "$sh/s0/reports/$f" "$out/$f" }
  for {set s 1} {$s < $k} {incr s} {
    foreach f [glob -nocomplain -tails -directory "$sh/s$s/reports" *] {
      if {[lsearch -exact $shared $f] >= 0} {
        set a [open "$out/$f" r]; set b [open "$sh/s$s/reports/$f" r]
        fconfigure $a -translation binary; fconfigure $b -translation binary
        set same [expr {[read $a] eq [read $b]}]; close $a; close $b
        if {!$same} { error "EARLY_EVAL sharded probe: $f differs between shard 0 and shard $s" }
      } else { file copy -force "$sh/s$s/reports/$f" "$out/$f" }
    }
  }
  if {![info exists ::env(CTS3D_KEEP_INTERMEDIATES)] || $::env(CTS3D_KEEP_INTERMEDIATES) != 1} { file delete -force $sh }
  puts "EARLY_EVAL candidates=[llength $ids] shards=$k elapsed_ms=[expr {[clock milliseconds]-$t0}]"
}
