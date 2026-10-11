# Decision session B (only when no tier has a valid shift model): single-root hub candidates on the Phase-1 reference
# database: generate -> in-session probe -> measure -> select; multi-hub prefixes of the measured candidates.
#   env EARLY_DEC, EARLY_CASE, EARLY_SETRC, EARLY_RUN (run dir), PLATFORM, DESIGN_NICKNAME, PROBE_INPUT_ODB / SDC, SET_RC_TCL
#   out EARLY_DEC/hub (cands/, gen.csv, probe/reports/, measured.csv, plan/{plan.tsv,cid,select.json}),
#       EARLY_RUN/multi_hub (plan_k<k>.tsv, prefixes.json), hub_cid=... appended to EARLY_DEC/DECISION.txt
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

set dec $::env(EARLY_DEC); set plat $::env(PLATFORM); set des $::env(DESIGN_NICKNAME); set case $::env(EARLY_CASE)
set dump $dec/dump/reports; set nets $dec/nets/reports/nets_base.txt; set view $dec/view; set cal $dec/calibration
set H $dec/hub
set t0 [clock milliseconds]
cts::early_hub_generate $case $plat $des $view $dump $cal $H $nets $::env(EARLY_SETRC)
probe_candidates $H/cands $H/probe/reports
cts::early_hub_measure $case $plat $des $view $dump $cal $H $nets $::env(EARLY_SETRC) $H/probe/reports
set cid [cts::early_hub_select $H/measured.csv $H/cands $H/plan]
if {$cid ne ""} { cts::early_hub_multi $H/measured.csv $H/cands $::env(EARLY_RUN)/multi_hub 3 }
puts "EARLY_HUB cid=$cid elapsed_ms=[expr {[clock milliseconds]-$t0}]"
set fo [open $dec/DECISION.txt a]
puts $fo "hub_cid=$cid"
close $fo
