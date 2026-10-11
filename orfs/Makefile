# =========================================
# Flow-home Makefile of the 3D CTS flow.  Derived from the TaiWei-Pin-3D flow Makefile (BSD-3-Clause, CODA-Team) and
# the conventions of OpenROAD-flow-scripts (BSD-3-Clause, The Regents of the University of California).
# It resolves the platform / design configuration into the environment of one OpenROAD session:
#   make DESIGN_CONFIG=<designs/.../config*.mk> ord-cts-3d                  CTS session ($(OPENROAD_SCRIPTS_DIR)/cts_3d.tcl)
#   make DESIGN_CONFIG=<...> OPENROAD_SCRIPT=<script.tcl> openroad-script  read-only analysis session
#   make DESIGN_CONFIG=<designs/.../config.mk> ord-route ord-final          OpenROAD routing, extraction, final STA
#   make DESIGN_CONFIG=<...> cds-route cds-restore ord-final                Innovus routing (ariane133), final STA in OpenROAD
# Logs are written to a temporary file first and then moved to the final log path.
# =========================================

# ---------------- Common paths ----------------
export FLOW_HOME     ?= $(shell pwd)
export PLATFORM_HOME ?= $(FLOW_HOME)/platforms
export WORK_HOME     ?= .

# Script directories: CTS sessions use the Tcl scripts of this repository (flow/tcl, set by the flow scripts);
# routing sessions use scripts_openroad/ (OpenROAD) and scripts_cadence/ (Innovus).
export OPENROAD_SCRIPTS_DIR ?= $(FLOW_HOME)/../flow/tcl
export ROUTE_SCRIPTS_DIR    ?= $(FLOW_HOME)/scripts_openroad
export CADENCE_SCRIPTS_DIR  ?= $(FLOW_HOME)/scripts_cadence

# ---------------- Design config ----------------
# DESIGN_CONFIG = designs/<platform>/<design>/config_bottom_cover.mk (CTS sessions)
include $(DESIGN_CONFIG)

# ---------------- Platform resolve ----------------
ifneq ($(wildcard $(PLATFORM_HOME)/$(PLATFORM)),)
  export PLATFORM_DIR = $(PLATFORM_HOME)/$(PLATFORM)
else
  $(error [ERROR][FLOW] Platform '$(PLATFORM)' not found under $(PLATFORM_HOME).)
endif

ifeq ($(MAKELEVEL),0)
$(info [INFO][FLOW] Using platform directory $(PLATFORM_DIR))
endif

include $(PLATFORM_DIR)/config.mk

# ---------------- Work dirs ----------------
export DESIGN_NICKNAME ?= $(DESIGN_NAME)
export FLOW_VARIANT    ?= openroad

export LOG_DIR     ?= $(WORK_HOME)/logs/$(PLATFORM)/$(DESIGN_NICKNAME)/$(FLOW_VARIANT)
export OBJECTS_DIR ?= $(WORK_HOME)/objects/$(PLATFORM)/$(DESIGN_NICKNAME)/$(FLOW_VARIANT)
export REPORTS_DIR ?= $(WORK_HOME)/reports/$(PLATFORM)/$(DESIGN_NICKNAME)/$(FLOW_VARIANT)
export RESULTS_DIR ?= $(WORK_HOME)/results/$(PLATFORM)/$(DESIGN_NICKNAME)/$(FLOW_VARIANT)

# ---------------- Shell / time ----------------
SHELL       := /usr/bin/env bash
.SHELLFLAGS := -o pipefail -c
TIME_CMD    = /usr/bin/time -f 'Elapsed: %E  CPU: user %U sys %S (%P)  Peak: %M KB'
TIME_TEST   = $(shell $(TIME_CMD) echo foo 2>/dev/null)
ifeq (, $(strip $(TIME_TEST)))
  TIME_CMD = /usr/bin/time
endif

# Detect CPU core count (portable fallbacks)
ifndef NUM_CORES
	NPROC := $(shell nproc 2>/dev/null)

	ifeq (, $(strip $(NPROC)))
		# Linux (generic)
		NPROC := $(shell grep -c ^processor /proc/cpuinfo 2>/dev/null)
	endif
	ifeq (, $(strip $(NPROC)))
		# BSD / macOS
		NPROC := $(shell sysctl -n hw.ncpu 2>/dev/null)
	endif
	ifeq (, $(strip $(NPROC)))
		# Fallback
		NPROC := 1
	endif
endif
export NUM_CORES

# ---------------- Tools ----------------
export OPENROAD_EXE ?= $(shell which openroad)
OPENROAD_ARGS = -no_init -threads ${NUM_CORES} -exit
OPENROAD_CMD  = $(OPENROAD_EXE) $(OPENROAD_ARGS)
export INNOVUS_EXE ?= $(shell which innovus 2>/dev/null)
INNOVUS_CMD = $(INNOVUS_EXE) -64 -abort_on_error

# ---------------- Helpers ----------------
define _mkstdirs
	mkdir -p $(RESULTS_DIR) $(LOG_DIR) $(REPORTS_DIR) $(OBJECTS_DIR)
endef

# Unified log runner:
# - write to a temporary log first
# - atomically replace the final log with mv
# - preserve the real command exit status under pipefail + tee
define _run_with_tmp_log
	@tmp_log="$(1).tmp"; \
	rm -f "$$tmp_log"; \
	{ $(2); } 2>&1 | tee "$$tmp_log"; \
	cmd_status=$${PIPESTATUS[0]}; \
	mv -f "$$tmp_log" "$(1)"; \
	exit $$cmd_status
endef

# ---------------- CTS settings ----------------
# CTS_LAYER names the tier whose standard cells stay placeable during the CTS session; the cells of the other tier
# are loaded as CLASS COVER (blockages) through the *_COVER LEF variants.  Platform default: bottom (asap7_3D);
# asap7_nangate45_3D sets upper in its config.mk.  The design configuration may define SC_LEF_UPPER_COVER /
# SC_LEF_BOTTOM_COVER (macro designs); otherwise its SC_LEF (already a cover variant) is used for both.
# The effective LEF list of every design is printed by `make -n`.
export CTS_LAYER ?= bottom

SC_LEF_UPPER_COVER ?= $(SC_LEF)
SC_LEF_BOTTOM_COVER ?= $(SC_LEF)
ADDITIONAL_LEFS_UPPER_COVER ?=
ADDITIONAL_LEFS_BOTTOM_COVER ?=
ADDITIONAL_LEFS_CTS ?=

ifeq ($(CTS_LAYER),upper)
  SC_LEF_CTS ?= $(SC_LEF_BOTTOM_COVER)
  LEF_FILES_CTS ?= $(TECH_LEF) $(SC_LEF_CTS) $(ADDITIONAL_LEFS_CTS) $(ADDITIONAL_LEFS_BOTTOM_COVER)
else ifeq ($(CTS_LAYER),bottom)
  SC_LEF_CTS ?= $(SC_LEF_UPPER_COVER)
  LEF_FILES_CTS ?= $(TECH_LEF) $(SC_LEF_CTS) $(ADDITIONAL_LEFS_CTS) $(ADDITIONAL_LEFS_UPPER_COVER)
else
  SC_LEF_CTS ?= $(SC_LEF)
  LEF_FILES_CTS ?= $(TECH_LEF) $(SC_LEF_CTS) $(ADDITIONAL_LEFS_CTS)
endif

# =========================================
# ================ Targets ================
# =========================================
.PHONY: ord-cts-3d
ord-cts-3d:
	@$(call _mkstdirs)
	@echo "[ORD] 3D CTS"
	$(call _run_with_tmp_log,$(LOG_DIR)/4_1_cts_3d.log,SC_LEF="$(SC_LEF_CTS)" LEF_FILES="$(LEF_FILES_CTS)" ADDITIONAL_LEFS="$(ADDITIONAL_LEFS_CTS)" $(TIME_CMD) $(OPENROAD_CMD) $(OPENROAD_SCRIPTS_DIR)/cts_3d.tcl)

# One OpenROAD session that runs $(OPENROAD_SCRIPT) (stage scripts that read a saved database).
.PHONY: openroad-script
openroad-script:
	$(OPENROAD_EXE) -no_init -threads $(NUM_CORES) -exit $(OPENROAD_SCRIPT)

# =========================================
# ============ Routing targets ============
# =========================================
# Inputs: $(RESULTS_DIR)/4_cts.{def,sdc,v} (the CTS checkpoint).  Outputs: 5_route.{def,v,sdc}, 6_final.{def,v,sdc,spef},
# $(REPORTS_DIR)/6_finish.rpt (post-route timing, power, area and wire length).
define _or
$(call _run_with_tmp_log,$(2),OPENROAD_SCRIPTS_DIR=$(ROUTE_SCRIPTS_DIR) $(TIME_CMD) $(OPENROAD_CMD) $(1))
endef
define _cad
$(call _run_with_tmp_log,$(2),$(TIME_CMD) $(1))
endef

.PHONY: ord-route
ord-route:
	@$(call _mkstdirs)
	$(call _or,$(ROUTE_SCRIPTS_DIR)/global_route.tcl,$(LOG_DIR)/5_1_grt.log)
	$(call _or,$(ROUTE_SCRIPTS_DIR)/detail_route.tcl,$(LOG_DIR)/5_2_route.log)
	@cp -f $(RESULTS_DIR)/4_cts.sdc $(RESULTS_DIR)/5_route.sdc
	@cp -f $(RESULTS_DIR)/5_2_route.odb $(RESULTS_DIR)/5_route.odb 2>/dev/null || true

.PHONY: ord-final
ord-final:
	@$(call _mkstdirs)
	$(call _or,$(ROUTE_SCRIPTS_DIR)/final_report.tcl,$(LOG_DIR)/6_report.log)

.PHONY: cds-route
cds-route:
	@$(call _mkstdirs)
	$(call _cad,$(INNOVUS_CMD) -overwrite -log $(LOG_DIR)/cadence_innovus_3d_route.log -files $(CADENCE_SCRIPTS_DIR)/innovus_3d_route.tcl,$(LOG_DIR)/5_route.log)
	@cp -f $(RESULTS_DIR)/4_cts.sdc $(RESULTS_DIR)/5_route.sdc

.PHONY: cds-restore
cds-restore:
	@$(call _mkstdirs)
	$(call _cad,$(INNOVUS_CMD) -overwrite -log $(LOG_DIR)/cadence_innovus_3d_final-re.log -files $(CADENCE_SCRIPTS_DIR)/innovus_3d_final-re.tcl,$(LOG_DIR)/6_final-re.log)

# print-<VAR>: value of a configuration variable (used by flow/stage.sh and run_cts.sh --list)
print-%:
	@echo $($*)
