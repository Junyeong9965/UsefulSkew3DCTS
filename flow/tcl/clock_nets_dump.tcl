# Decision input: report_net dump of every clock-tree net of the Phase-1 reference checkpoint (placement parasitics):
# driver, loads (master, pin capacitance, location) and estimated wire capacitance, for the hybrid-bond delay term.
#   -> REPORTS_DIR/nets_base.txt
source $::env(OPENROAD_SCRIPTS_DIR)/read_liberty.tcl
read_db $::env(PROBE_INPUT_ODB)
read_sdc $::env(PROBE_INPUT_SDC)
source $::env(SET_RC_TCL)
set_propagated_clock [all_clocks]
estimate_parasitics -placement

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
set nets [clock_tree_nets]
sta::redirect_file_begin $::env(REPORTS_DIR)/nets_base.txt
puts "CAP_UNIT [sta::unit_scale capacitance]"
foreach nm $nets { report_net -digits 5 $nm }
sta::redirect_file_end
