# log_cmd and load_design follow the OpenROAD-flow-scripts utilities (BSD-3-Clause, The Regents of the University of
# California); the other procedures are specific to this flow.
# Shared Tcl helpers of the CTS sessions (ORFS conventions).

# Run a command and print it (with its runtime when it took 5 s or more).
proc log_cmd { cmd args } {
  set log_cmd "$cmd[join [lmap arg $args { format " %s" [expr { [string match {* *} $arg] ? "\"$arg\"" : "$arg" }] }] ""]"
  puts $log_cmd
  set start [clock seconds]
  set result [uplevel 1 [list $cmd {*}$args]]
  set time [expr { [clock seconds] - $start }]
  if { $time >= 5 } {
    puts "Took $time seconds: $log_cmd"
  }
  return $result
}

# Read Liberty, LEF and the placed design (Verilog netlist + DEF placement) from RESULTS_DIR, then the SDC and the
# platform RC settings.
proc load_design {design_file sdc_file msg} {
  puts "Reading liberty files..."
  source $::env(OPENROAD_SCRIPTS_DIR)/read_liberty.tcl
  if {[info exist ::env(LEF_FILES)]} {
    foreach lef $::env(LEF_FILES) {
      read_lef $lef
    }
  }
  read_verilog $::env(RESULTS_DIR)/$design_file
  puts "Linking design $::env(DESIGN_NAME)..."
  link_design $::env(DESIGN_NAME)
  set def_file [file rootname $::env(RESULTS_DIR)/$design_file].def
  if {[file exists $def_file]} {
    read_def -floorplan_initialize $def_file
  }
  read_sdc $::env(RESULTS_DIR)/$sdc_file
  source $::env(SET_RC_TCL)
}

# 1 if the master is bound to a SITE (standard cell), cached per master name.
proc master_has_site_by_name {mname} {
  if {[info exists ::_MASTER_HAS_SITE_CACHE($mname)]} {
    return $::_MASTER_HAS_SITE_CACHE($mname)
  }
  set v 0
  foreach lib [::odb::dbDatabase_getLibs [ord::get_db]] {
    foreach m [::odb::dbLib_getMasters $lib] {
      if {[$m getName] eq $mname} {
        if {![catch {set s [::odb::dbMaster_getSite $m]}] && $s ne "" && $s ne "NULL"} { set v 1 }
        break
      }
    }
    if {$v} break
  }
  set ::_MASTER_HAS_SITE_CACHE($mname) $v
  return $v
}

# Set the placement status of every standard-cell instance whose master name matches pattern (case-insensitive).
proc mark_insts_by_master {pattern status} {
  set block [[ord::get_db] getChip]
  set block [$block getBlock]
  set cnt 0
  foreach inst [$block getInsts] {
    set mname [[$inst getMaster] getName]
    if {[master_has_site_by_name $mname] && [string match -nocase $pattern $mname]} {
      if {[catch {$inst setPlacementStatus $status} err]} {
        puts "WARN: fail to set $status for [$inst getName]($mname): $err"
      } else {
        incr cnt
      }
    }
  }
  puts "INFO: Marked $cnt insts to '$status' by master pattern '$pattern'."
  return $cnt
}
