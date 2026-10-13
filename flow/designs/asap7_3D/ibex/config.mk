# Design configuration of the routing sessions (both tiers placeable; the CTS session uses config_cts.mk).
export DESIGN_NICKNAME = ibex
export DESIGN_NAME = ibex_core
export PLATFORM    = asap7_3D

export GLOBAL_ROUTE_ARGS = -verbose -congestion_iterations 30
export DETAILED_ROUTE_END_ITERATION = 0
