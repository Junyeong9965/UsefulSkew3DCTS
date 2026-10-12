# Shared Tcl helpers of the CTS sessions.  log_cmd and load_design are the OpenROAD-flow-scripts utilities of the
# route scripts (flow/route/openroad/util.tcl, load.tcl); the other procedures are specific to this flow.
source $::env(FLOW_HOME)/common/util.tcl
source $::env(FLOW_HOME)/common/load.tcl

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
