# Platform configuration: asap7_3D (two-tier face-to-face stack, ASAP7 on both tiers; RVT, NLDM, FF corner).
# Only the variables read by the CTS and routing flow are defined here; see README.md in this directory for the origin of the files.
export PROCESS ?= 7

# -------- Technology LEF and wire RC --------
ifeq ($(USE_FLOW),openroad)
  export TECH_LEF   ?= $(PLATFORM_DIR)/lef/asap7_tech_1x_2A6M7M.lef
  export SET_RC_TCL ?= $(PLATFORM_DIR)/setRC_2A6M7M.tcl
  export RCX_RULES  ?= $(PLATFORM_DIR)/asap7_tech_1x_2A6M7M.rcx_patterns.rules
  export MIN_ROUTING_LAYER ?= M2
  export MAX_ROUTING_LAYER ?= M3_add
endif
export TECH_LEF   ?= $(PLATFORM_DIR)/lef/asap7_tech_1x_6M7M.lef
export SET_RC_TCL ?= $(PLATFORM_DIR)/setRC_6M7M.tcl

# -------- Standard-cell LEF (per tier) --------
export SC_LEF    ?= \
  $(PLATFORM_DIR)/lef_bottom/asap7sc7p5t_28_R_1x_220121a.bottom.lef \
  $(PLATFORM_DIR)/lef_upper/asap7sc7p5t_28_R_1x_220121a.upper.lef

# -------- Timing libraries (per tier) --------
export SC_LIB_UPPER ?= \
  $(PLATFORM_DIR)/lib_upper/NLDM/asap7sc7p5t_AO_RVT_FF_nldm_211120.upper.lib \
  $(PLATFORM_DIR)/lib_upper/NLDM/asap7sc7p5t_INVBUF_RVT_FF_nldm_220122.upper.lib \
  $(PLATFORM_DIR)/lib_upper/NLDM/asap7sc7p5t_OA_RVT_FF_nldm_211120.upper.lib \
  $(PLATFORM_DIR)/lib_upper/NLDM/asap7sc7p5t_SIMPLE_RVT_FF_nldm_211120.upper.lib \
  $(PLATFORM_DIR)/lib_upper/NLDM/asap7sc7p5t_SEQ_RVT_FF_nldm_220123.upper.lib
export SC_LIB_BOTTOM ?= \
  $(PLATFORM_DIR)/lib_bottom/NLDM/asap7sc7p5t_AO_RVT_FF_nldm_211120.bottom.lib \
  $(PLATFORM_DIR)/lib_bottom/NLDM/asap7sc7p5t_INVBUF_RVT_FF_nldm_220122.bottom.lib \
  $(PLATFORM_DIR)/lib_bottom/NLDM/asap7sc7p5t_OA_RVT_FF_nldm_211120.bottom.lib \
  $(PLATFORM_DIR)/lib_bottom/NLDM/asap7sc7p5t_SIMPLE_RVT_FF_nldm_211120.bottom.lib \
  $(PLATFORM_DIR)/lib_bottom/NLDM/asap7sc7p5t_SEQ_RVT_FF_nldm_220123.bottom.lib
export SC_LIB    ?= $(SC_LIB_BOTTOM) $(SC_LIB_UPPER)

# -------- Lists handed to the OpenROAD session --------
export LEF_FILES = $(TECH_LEF) $(SC_LEF) $(ADDITIONAL_LEFS)
export LIB_FILES = $(SC_LIB) $(ADDITIONAL_LIBS)

# -------- Placement --------
export PLACE_SITE = asap7sc7p5t
export CELL_PAD_IN_SITES_DETAIL_PLACEMENT ?= 0

# -------- Cells excluded from sizing (per tier) --------
export DONT_USE_CELLS_UPPER  ?= *x1p*_ASAP7*_upper *xp*_ASAP7*_upper SDF*_upper ICG*_upper
export DONT_USE_CELLS_BOTTOM ?= *x1p*_ASAP7*_bottom *xp*_ASAP7*_bottom SDF*_bottom ICG*_bottom
export DONT_USE_CELLS = $(DONT_USE_CELLS_UPPER) $(DONT_USE_CELLS_BOTTOM)

# -------- Clock buffers (per tier) --------
export CTS_BUF_CELL   ?= BUFx8_ASAP7_75t_R_bottom
export CTS_BUF_BOTTOM ?= BUFx4_ASAP7_75t_R_bottom BUFx8_ASAP7_75t_R_bottom
export CTS_BUF_UPPER  ?= BUFx4_ASAP7_75t_R_upper  BUFx8_ASAP7_75t_R_upper

# -------- Routing and extraction --------
export MIN_CLK_ROUTING_LAYER ?= M2
export FASTROUTE_TCL ?= $(PLATFORM_DIR)/fastroute.tcl
export LIB_DIR ?= $(dir $(firstword $(SC_LIB)))
export LEF_DIR ?= $(dir $(TECH_LEF))
