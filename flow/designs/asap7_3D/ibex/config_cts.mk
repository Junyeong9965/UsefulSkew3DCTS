# Design configuration of the CTS sessions (bottom-tier standard cells as CLASS COVER; routing uses config.mk).
export DESIGN_NICKNAME        = ibex
export DESIGN_NAME            = ibex_core
export PLATFORM    = asap7_3D

export SC_LEF    ?= \
  $(PLATFORM_DIR)/lef_bottom/asap7sc7p5t_28_R_1x_220121a.bottom.cover.lef \
  $(PLATFORM_DIR)/lef_upper/asap7sc7p5t_28_R_1x_220121a.upper.lef

# -------- Design-specific CTS settings (read by flow/cts/common.sh, case_info; absent = 0) --------
# gated-clock domains: the delivery balancer restores the Phase-1 base latencies
DESIGN_CTS_BALANCER_BASE_RESTORE = 1
# gated-clock domains: the delivery balancer traverses into the leaf builders
DESIGN_CTS_BALANCER_FULL_TRAVERSE = 1
