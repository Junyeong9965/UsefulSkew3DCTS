# Design configuration of the routing sessions (both tiers placeable; the CTS session uses config_bottom_cover.mk).
export DESIGN_NICKNAME = jpeg
export DESIGN_NAME = jpeg_encoder
export PLATFORM    = asap7_nangate45_3D

export GLOBAL_ROUTE_ARGS = -verbose -congestion_iterations 30
export DETAILED_ROUTE_END_ITERATION = 10
