# Design configuration of the CTS session (macro design): includes the placement settings of config.mk and the
# per-tier cover LEF variants used by the Makefile.
include $(dir $(lastword $(MAKEFILE_LIST)))config.mk

# Defaults for a session that does not select a cover variant through CTS_LAYER (the CTS session does: the
# Makefile loads SC_LEF_<other tier>_COVER and ADDITIONAL_LEFS_<other tier>_COVER for the CTS_LAYER of the platform).
export SC_LEF = $(SC_LEF_BOTTOM_COVER)
export ADDITIONAL_LEFS = $(ADDITIONAL_LEFS_BOTTOM_COVER)

# -------- Design-specific CTS settings (read by flow/stage.sh; absent = 0) --------
# macro design: Phase-1 and delivery trees without the latency balancer
DESIGN_CTS_NO_INSERTION_DELAY = 1
