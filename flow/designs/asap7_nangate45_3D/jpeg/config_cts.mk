# Design configuration of the CTS sessions (bottom-tier standard cells as CLASS COVER; routing uses config.mk).
export DESIGN_NICKNAME = jpeg
export DESIGN_NAME = jpeg_encoder
export PLATFORM    = asap7_nangate45_3D

export SC_LEF ?= \
$(PLATFORM_DIR)/lef_upper/asap7sc7p5t_28_R_1x_220121a.upper.processed.lef \
$(PLATFORM_DIR)/lef_bottom/NangateOpenCellLibrary.macro.mod.bottom.cover.processed.lef
