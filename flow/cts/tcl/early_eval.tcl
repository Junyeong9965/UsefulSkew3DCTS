# Stand-alone decision probe: the candidates of EARLY_CANDS (list.txt + <cid>.tsv) evaluated on the loaded database,
# reports in REPORTS_DIR (see early_probe.tcl; the decision sessions call probe_candidates directly).
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
probe_candidates $::env(EARLY_CANDS) $::env(REPORTS_DIR)
