# Stage Q: write a relocated database (PROBE_INPUT_ODB) as a CTS checkpoint 4_cts.{odb,def,v} in CKPT_DIR.
source $::env(FLOW_HOME)/common/read_liberty.tcl
read_db $::env(PROBE_INPUT_ODB)
set d $::env(CKPT_DIR)
write_db $d/4_cts.odb
write_def $d/4_cts.def
write_verilog $d/4_cts.v
