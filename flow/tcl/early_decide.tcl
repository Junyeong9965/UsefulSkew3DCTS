# Decision session A on the Phase-1 reference database: scoped view, shift calibration (structures, in-session probe,
# least-squares fit) and early-group selection.  One OpenROAD session; the C++ steps are cts::early_* commands.
#   env EARLY_DEC (decide dir with dump/ and nets/), EARLY_REF_ARM (OFF arm dir), EARLY_SETRC (setRC tcl of the platform),
#       PLATFORM, DESIGN_NICKNAME, PROBE_INPUT_ODB / PROBE_INPUT_SDC (phase1), SET_RC_TCL
#   out EARLY_DEC/view, EARLY_DEC/calibration (calib.json, calib_points.csv, cands/, probe/reports/),
#       EARLY_DEC/early_groups (plan.tsv, summary.json, ...), EARLY_DEC/DECISION.txt (root=..., early_groups_status=...)
source $::env(OPENROAD_SCRIPTS_DIR)/read_liberty.tcl
source $::env(OPENROAD_SCRIPTS_DIR)/cts_commands.tcl
read_db $::env(PROBE_INPUT_ODB)
read_sdc $::env(PROBE_INPUT_SDC)
source $::env(SET_RC_TCL)
set_propagated_clock [all_clocks]
estimate_parasitics -placement
sta::worst_slack_cmd max
source $::env(OPENROAD_SCRIPTS_DIR)/early_clock.tcl
source $::env(OPENROAD_SCRIPTS_DIR)/early_probe.tcl

set dec $::env(EARLY_DEC); set plat $::env(PLATFORM); set des $::env(DESIGN_NICKNAME)
set dump $dec/dump/reports; set nets $dec/nets/reports/nets_base.txt; set view $dec/view
set t0 [clock milliseconds]
set root [cts::early_scope $::env(EARLY_REF_ARM) $plat $des $dump $view]
puts "EARLY_DECIDE scope root=$root elapsed_ms=[expr {[clock milliseconds]-$t0}]"
set cal $dec/calibration; file mkdir $cal
set t0 [clock milliseconds]
cts::early_calibrate_structures $view $plat $des $dump $cal $root
probe_candidates $cal/cands $cal/probe/reports
cts::early_calibrate_fit $view $plat $des $dump $cal $root $cal/probe/reports
puts "EARLY_DECIDE calibration elapsed_ms=[expr {[clock milliseconds]-$t0}]"
set t0 [clock milliseconds]
set status [cts::early_groups $view $plat $des $dump $cal/calib.json $dec/early_groups $view/fixed_regs.txt $nets $::env(EARLY_SETRC)]
puts "EARLY_DECIDE early_groups status=$status elapsed_ms=[expr {[clock milliseconds]-$t0}]"
set fo [open $dec/DECISION.txt w]
puts $fo "root=$root"
puts $fo "early_groups_status=$status"
close $fo
