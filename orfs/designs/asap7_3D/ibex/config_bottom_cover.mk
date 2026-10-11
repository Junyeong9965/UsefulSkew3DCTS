export DESIGN_NICKNAME        = ibex
export DESIGN_NAME            = ibex_core
export PLATFORM    = asap7_3D

export SC_LEF    ?= \
  $(PLATFORM_DIR)/lef_bottom/asap7sc7p5t_28_R_1x_220121a.bottom.cover.lef \
  $(PLATFORM_DIR)/lef_upper/asap7sc7p5t_28_R_1x_220121a.upper.lef

export PLACE_DENSITY_LB_ADDON = 0.10
export TNS_END_PERCENT        = 100
export SKIP_GATE_CLONING   = 1
export CORE_MARGIN = 2
export CORE_UTILIZATION ?= 60
export OPEN_GUI ?= 1
export NUM_CORES  ?= 32

# -------- Design-specific CTS settings (read by flow/stage.sh; absent = 0) --------
# gated-clock domains: the delivery balancer restores the Phase-1 base latencies
DESIGN_CTS_BALANCER_BASE_RESTORE = 1
# gated-clock domains: the delivery balancer traverses into the leaf builders
DESIGN_CTS_BALANCER_FULL_TRAVERSE = 1
