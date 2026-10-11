# Platform configuration: asap7_nangate45_3D (two-tier face-to-face stack, ASAP7 upper tier, NanGate45 bottom tier).
# Only the variables read by the CTS and routing flow are defined here; see README.md in this directory for the origin of the files.
export PROCESS ?= 45
export PLATFORM = asap7_nangate45_3D

# -------- Technology LEF and wire RC --------
ifeq ($(USE_FLOW),openroad)
  export TECH_LEF   ?= $(PLATFORM_DIR)/lef/asap7_nangate45_2A6M10M.lef
  export SET_RC_TCL ?= $(PLATFORM_DIR)/setRC_2A6M10M.tcl
  export RCX_RULES  ?= $(PLATFORM_DIR)/asap7_nangate45_2A6M10M.rcx_patterns.rules
  export MIN_ROUTING_LAYER ?= M2
  export MAX_ROUTING_LAYER ?= M3_add
endif
export TECH_LEF   ?= $(PLATFORM_DIR)/lef/asap7_nangate45_6M10M.lef
export SET_RC_TCL ?= $(PLATFORM_DIR)/setRC_6M10M.tcl

# -------- Standard-cell LEF (per tier) --------
export SC_LEF    ?= \
  $(PLATFORM_DIR)/lef_bottom/NangateOpenCellLibrary.macro.mod.bottom.processed.lef \
  $(PLATFORM_DIR)/lef_upper/asap7sc7p5t_28_R_1x_220121a.upper.processed.lef

# -------- Timing libraries (per tier) --------
export SC_LIB_UPPER   ?= \
  $(PLATFORM_DIR)/lib_upper/NLDM/asap7sc7p5t_AO_RVT_FF_nldm_211120.upper.processed.lib \
  $(PLATFORM_DIR)/lib_upper/NLDM/asap7sc7p5t_INVBUF_RVT_FF_nldm_220122.upper.processed.lib \
  $(PLATFORM_DIR)/lib_upper/NLDM/asap7sc7p5t_OA_RVT_FF_nldm_211120.upper.processed.lib \
  $(PLATFORM_DIR)/lib_upper/NLDM/asap7sc7p5t_SIMPLE_RVT_FF_nldm_211120.upper.processed.lib \
  $(PLATFORM_DIR)/lib_upper/NLDM/asap7sc7p5t_SEQ_RVT_FF_nldm_220123.upper.processed.lib
export SC_LIB_BOTTOM  ?= \
  $(PLATFORM_DIR)/lib_bottom/NangateOpenCellLibrary_typical.bottom.processed.lib
export SC_LIB    ?= $(SC_LIB_BOTTOM) $(SC_LIB_UPPER)

# -------- Lists handed to the OpenROAD session --------
export LEF_FILES = $(TECH_LEF) $(SC_LEF) $(ADDITIONAL_LEFS)
export LIB_FILES = $(SC_LIB) $(ADDITIONAL_LIBS)

# -------- Placement --------
export PLACE_SITE  = FreePDK45_38x28_10R_NP_162NW_34O
export UPPER_SITE  = asap7sc7p5t
export BOTTOM_SITE = FreePDK45_38x28_10R_NP_162NW_34O
export CELL_PAD_IN_SITES_DETAIL_PLACEMENT ?= 0

# -------- Cells excluded from sizing (per tier) --------
export DONT_USE_CELLS_UPPER  ?= *x1p*_ASAP7*_upper *xp*_ASAP7*_upper SDF*_upper ICG*_upper
export DONT_USE_CELLS_BOTTOM ?= TAPCELL_X1_bottom FILLCELL_X1_bottom AOI211_X1_bottom OAI211_X1_bottom
export DONT_USE_CELLS = $(DONT_USE_CELLS_UPPER) $(DONT_USE_CELLS_BOTTOM)

# -------- Clock buffers (per tier); the clock tree is built on the upper (ASAP7) tier --------
export CTS_LAYER ?= upper
ifeq ($(CTS_LAYER),upper)
  export CTS_BUF_CELL ?= BUF_X4_upper
endif
export CTS_BUF_CELL   ?= BUF_X4_bottom
export CTS_BUF_UPPER  ?= BUF_X4_upper
export CTS_BUF_BOTTOM ?= BUF_X4_bottom

# -------- Routing and extraction --------
export MIN_CLK_ROUTING_LAYER ?= M2
export FASTROUTE_TCL ?= $(PLATFORM_DIR)/fastroute.tcl
export LIB_DIR ?= $(dir $(firstword $(SC_LIB)))
export LEF_DIR ?= $(dir $(TECH_LEF))
