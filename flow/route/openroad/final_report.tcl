utl::set_metrics_stage "finish__{}"
source $::env(FLOW_HOME)/common/load.tcl
load_design 5_route.def 5_route.sdc "Starting final report"

set_propagated_clock [all_clocks]

puts "Starting global connection cleanup"

global_connect

# Delete routing obstructions for final DEF
source $::env(OPENROAD_SCRIPTS_DIR)/deleteRoutingObstructions.tcl
deleteRoutingObstructions

puts "Writing final design files"

write_db $::env(RESULTS_DIR)/6_final.odb
write_def $::env(RESULTS_DIR)/6_final.def
write_verilog $::env(RESULTS_DIR)/6_final.v
write_sdc $::env(RESULTS_DIR)/6_final.sdc
puts "Starting extraction"
# Run extraction and STA
if {[info exist ::env(RCX_RULES)]} {

  # RCX section
  define_process_corner -ext_model_index 0 X
  extract_parasitics -ext_model_file $::env(RCX_RULES)

  # Write Spef
  write_spef $::env(RESULTS_DIR)/6_final.spef
  file delete $::env(DESIGN_NAME).totCap

  # Read Spef for OpenSTA
  read_spef $::env(RESULTS_DIR)/6_final.spef

} else {
  puts "OpenRCX is not enabled for this platform."
}

source $::env(OPENROAD_SCRIPTS_DIR)/report_metrics.tcl
report_metrics 6 "finish"
puts "Final report metrics written to $::env(REPORTS_DIR)/6_finish.rpt"

# Images need the GUI; skip them when OpenROAD was built with BUILD_GUI=OFF.
if {[ord::openroad_gui_compiled]} {
  source $::env(OPENROAD_SCRIPTS_DIR)/save_images.tcl
}
# Save a final image if openroad is compiled with the gui
set VISUALIZE_FINAL [_get VISUALIZE_FINAL "0"]
if {$VISUALIZE_FINAL eq "1"} {
  puts "gui::pause"
  gui::show
  gui::pause
}

exit
