# Early-clock decision on the Phase-1 reference database of the OFF arm, in one OpenROAD session:
#   1. clock-tree dump (dump/reports: tree.csv, sinks.csv) and clock-net dump (nets/reports/nets_base.txt, report_net of
#      every clock-tree net: driver, loads, pin and wire capacitance, for the hybrid-bond delay term);
#   2. scoped view, shift calibration (structures, probe, least-squares fit) and early-group selection;
#   3. only when no tier has a valid shift model: single-root hub candidates (generate, probe, measure, select)
#      and the multi-hub prefixes of the measured candidates.
# The C++ steps are cts::early_* commands; the probes run in separate sessions (early_probe.tcl).  The database is only
# read here (every probe candidate is applied to its own copy of the session and undone).
#   env EARLY_DEC (decision dir), EARLY_REF_ARM (OFF arm dir), EARLY_CASE, EARLY_SETRC (setRC tcl of the platform),
#       EARLY_RUN (run dir), PLATFORM, DESIGN_NICKNAME, PROBE_INPUT_ODB / PROBE_INPUT_SDC (phase1), SET_RC_TCL
#   out EARLY_DEC/{dump,nets,view,calibration,early_groups,hub}, EARLY_DEC/DECISION.txt (root=..., early_groups_status=...,
#       hub_cid=... when step 3 ran), EARLY_RUN/multi_hub (plan_k<k>.tsv, prefixes.json)
source $::env(FLOW_HOME)/common/read_liberty.tcl
source $::env(OPENROAD_SCRIPTS_DIR)/cts_commands.tcl
read_db $::env(PROBE_INPUT_ODB)
read_sdc $::env(PROBE_INPUT_SDC)
source $::env(SET_RC_TCL)
set_propagated_clock [all_clocks]
estimate_parasitics -placement
sta::worst_slack_cmd max
source $::env(OPENROAD_SCRIPTS_DIR)/early_clock.tcl
source $::env(OPENROAD_SCRIPTS_DIR)/early_probe.tcl

# ---- 1. dumps
# tree.csv: every instance reached from the clock source through buffers (BUF in master name), its input/output net,
# master, tier (master suffix), location and the instance driving its input net; sinks.csv: register clock pins reached
proc dump_tier_of {m} { if {[string match *_upper $m]} {return 1}; if {[string match *_bottom $m]} {return 0}; return -1 }
proc dump_clock_tree {block out} {
  file mkdir $out
  set ft [open $out/tree.csv w]; puts $ft "inst,master,tier,x,y,w,h,in_net,out_net,driver,kind,fanout"
  set fs [open $out/sinks.csv w]; puts $fs "inst,pin,master,tier,x,y,net,driver"
  set queue {}
  foreach clk [all_clocks] {
    foreach src [get_property $clk sources] {
      set nm [get_full_name $src]
      set bt [$block findBTerm $nm]
      if {$bt ne "NULL"} { lappend queue [list [$bt getNet] PORT:$nm] }
    }
  }
  set seen [dict create]
  while {[llength $queue]} {
    lassign [lindex $queue 0] net drv; set queue [lrange $queue 1 end]
    if {$net eq "NULL" || [dict exists $seen [$net getName]]} continue
    dict set seen [$net getName] 1
    foreach it [$net getITerms] {
      if {![$it isInputSignal]} continue
      set inst [$it getInst]; set m [[$inst getMaster] getName]
      lassign [$inst getLocation] x y
      set bb [$inst getBBox]; set w [expr {[$bb xMax]-[$bb xMin]}]; set h [expr {[$bb yMax]-[$bb yMin]}]
      set outnet NULL; set nout 0
      foreach o [$inst getITerms] { if {[$o isOutputSignal] && [$o getNet] ne "NULL"} { set outnet [$o getNet]; incr nout } }
      set pin [[$it getMTerm] getName]
      if {[regexp -nocase {BUF} $m] && $nout == 1} {
        set fo [llength [$outnet getITerms]]
        puts $ft "[$inst getName],$m,[dump_tier_of $m],$x,$y,$w,$h,[$net getName],[$outnet getName],$drv,buffer,[expr {$fo-1}]"
        lappend queue [list $outnet [$inst getName]]
      } elseif {[regexp -nocase {DFF|SDF|DHL|DLL|LATCH} $m]} {
        puts $fs "[$inst getName],$pin,$m,[dump_tier_of $m],$x,$y,[$net getName],$drv"
      } else {
        set on [expr {$outnet eq "NULL" ? "NULL" : [$outnet getName]}]
        puts $ft "[$inst getName],$m,[dump_tier_of $m],$x,$y,$w,$h,[$net getName],$on,$drv,other,0"
      }
    }
  }
  close $ft; close $fs
  puts "CLOCK_TREE_DUMP done"
}

# register clock-pin nets and the buffer / inverter nets above them
proc clock_tree_nets {} {
  set todo [get_nets -of_objects [all_registers -clock_pins]]
  set seen [dict create]; set out {}
  while {[llength $todo]} {
    set n [lindex $todo 0]; set todo [lrange $todo 1 end]
    set nm [get_full_name $n]
    if {[dict exists $seen $nm]} continue
    dict set seen $nm 1; lappend out $nm
    foreach d [get_pins -quiet -of_objects $n -filter "direction==output"] {
      set inst [get_cells -of_objects $d]
      set ref [get_property $inst ref_name]
      if {[regexp {^(BUF|INV|CKINV|HB)} $ref]} {
        foreach ip [get_pins -quiet -of_objects $inst -filter "direction==input"] {
          set pn [get_nets -quiet -of_objects $ip]
          if {$pn ne ""} { lappend todo $pn }
        }
      }
    }
  }
  return $out
}
proc dump_clock_nets {out} {
  file mkdir $out
  set nets [clock_tree_nets]
  sta::redirect_file_begin $out/nets_base.txt
  puts "CAP_UNIT [sta::unit_scale capacitance]"
  foreach nm $nets { report_net -digits 5 $nm }
  sta::redirect_file_end
}
set t0 [clock milliseconds]
dump_clock_tree [ord::get_db_block] $::env(EARLY_DEC)/dump/reports
dump_clock_nets $::env(EARLY_DEC)/nets/reports
puts "EARLY_DECISION dumps elapsed_ms=[expr {[clock milliseconds]-$t0}]"

# ---- 2. calibration + early groups
set dec $::env(EARLY_DEC); set plat $::env(PLATFORM); set des $::env(DESIGN_NICKNAME)
set dump $dec/dump/reports; set nets $dec/nets/reports/nets_base.txt; set view $dec/view
set t0 [clock milliseconds]
set root [cts::early_scope $::env(EARLY_REF_ARM) $plat $des $dump $view]
puts "EARLY_DECIDE scope root=$root elapsed_ms=[expr {[clock milliseconds]-$t0}]"
set cal $dec/calibration; file mkdir $cal
set t0 [clock milliseconds]
cts::early_calibrate_structures $view $plat $des $dump $cal $root
probe_candidates_sharded $cal/cands $cal/probe/reports
cts::early_calibrate_fit $view $plat $des $dump $cal $root $cal/probe/reports
puts "EARLY_DECIDE calibration elapsed_ms=[expr {[clock milliseconds]-$t0}]"
set t0 [clock milliseconds]
set status [cts::early_groups $view $plat $des $dump $cal/calib.json $dec/early_groups $view/fixed_regs.txt $nets $::env(EARLY_SETRC)]
puts "EARLY_DECIDE early_groups status=$status elapsed_ms=[expr {[clock milliseconds]-$t0}]"
set fo [open $dec/DECISION.txt w]
puts $fo "root=$root"
puts $fo "early_groups_status=$status"
close $fo

# ---- 3. hub candidates (no valid shift model)
if {$status eq "model_invalid"} {
  set case $::env(EARLY_CASE); set H $dec/hub
  set t0 [clock milliseconds]
  cts::early_hub_generate $case $plat $des $view $dump $cal $H $nets $::env(EARLY_SETRC)
  probe_candidates_sharded $H/cands $H/probe/reports
  cts::early_hub_measure $case $plat $des $view $dump $cal $H $nets $::env(EARLY_SETRC) $H/probe/reports
  set cid [cts::early_hub_select $H/measured.csv $H/cands $H/plan]
  if {$cid ne ""} { cts::early_hub_multi $H/measured.csv $H/cands $::env(EARLY_RUN)/multi_hub 3 }
  puts "EARLY_HUB cid=$cid elapsed_ms=[expr {[clock milliseconds]-$t0}]"
  set fo [open $dec/DECISION.txt a]
  puts $fo "hub_cid=$cid"
  close $fo
}
