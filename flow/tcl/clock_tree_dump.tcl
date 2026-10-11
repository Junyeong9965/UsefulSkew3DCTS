# Decision input: clock network of the Phase-1 reference checkpoint (placement parasitics).
#   tree.csv  : every instance reached from the clock source through buffers (BUF in master name), its input/
#               output net, master, tier (master suffix), location, and the instance driving its input net.
#   sinks.csv : register clock pins (CLK) reached, with the driving instance.
source $::env(OPENROAD_SCRIPTS_DIR)/read_liberty.tcl
read_db $::env(PROBE_INPUT_ODB)
read_sdc $::env(PROBE_INPUT_SDC)
source $::env(SET_RC_TCL)
set_propagated_clock [all_clocks]
estimate_parasitics -placement
set block [ord::get_db_block]
proc tier_of {m} { if {[string match *_upper $m]} {return 1}; if {[string match *_bottom $m]} {return 0}; return -1 }
set out $::env(REPORTS_DIR)
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
      puts $ft "[$inst getName],$m,[tier_of $m],$x,$y,$w,$h,[$net getName],[$outnet getName],$drv,buffer,[expr {$fo-1}]"
      lappend queue [list $outnet [$inst getName]]
    } elseif {[regexp -nocase {DFF|SDF|DHL|DLL|LATCH} $m]} {
      puts $fs "[$inst getName],$pin,$m,[tier_of $m],$x,$y,[$net getName],$drv"
    } else {
      set on [expr {$outnet eq "NULL" ? "NULL" : [$outnet getName]}]
      puts $ft "[$inst getName],$m,[tier_of $m],$x,$y,$w,$h,[$net getName],$on,$drv,other,0"
    }
  }
}
close $ft; close $fs
puts "CLOCK_TREE_DUMP done"
