# Design configuration of the CTS sessions (bottom-tier standard cells as CLASS COVER; routing uses config.mk).
export DESIGN_NICKNAME = aes
export DESIGN_NAME = aes_cipher_top
export PLATFORM    = asap7_nangate45_3D

export SC_LEF ?= \
$(PLATFORM_DIR)/lef_bottom/NangateOpenCellLibrary.macro.mod.bottom.cover.processed.lef \
$(PLATFORM_DIR)/lef_upper/asap7sc7p5t_28_R_1x_220121a.upper.processed.lef 
