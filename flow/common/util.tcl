proc log_cmd { cmd args } {
  # log the command, escape arguments with spaces
  set log_cmd "$cmd[join [lmap arg $args { format " %s" [expr { [string match {* *} $arg] ? "\"$arg\"" : "$arg" }] }] ""]" ;# tclint-disable-line line-length
  puts $log_cmd
  set start [clock seconds]
  set result [uplevel 1 [list $cmd {*}$args]]
  set time [expr { [clock seconds] - $start }]
  if { $time >= 5 } {
    # Ideally we'd use a single line, but the command can output text
    # and we don't want to mix it with the log, so output the time it took afterwards.
    puts "Took $time seconds: $log_cmd"
  }
  return $result
}

proc env_var_equals { env_var value } {
  return [expr { [info exists ::env($env_var)] && $::env($env_var) == $value }]
}

proc env_var_exists_and_non_empty { env_var } {
  return [expr { [info exists ::env($env_var)] && ![string equal $::env($env_var) ""] }]
}

proc append_env_var { list_name var_name prefix has_arg } {
  upvar $list_name list
  if {
    (!$has_arg && [env_var_equals $var_name 1]) ||
    ($has_arg && [env_var_exists_and_non_empty $var_name])
  } {
    lappend list $prefix
    if { $has_arg } {
      lappend list $::env($var_name)
    }
  }
}

set global_route_congestion_report $::env(REPORTS_DIR)/congestion.rpt

proc source_env_var_if_exists { env_var } {
  if { [env_var_exists_and_non_empty $env_var] } {
    log_cmd source $::env($env_var)
  }
}
