# Entry points of the CTS engine used by the flow scripts.  Every script calls the engine through these procedures,
# so an interface change of the binary is adapted in this file only.

# STA-guided refinement of the constructed clock tree (stage R): buffer bypass / sink advance / buffer resize
# candidates, each kept only if the whole-design STA accepts it.  Options: CTS_REFINE_* (see flow/stage.sh) and
# CTS_GUARD_ENDPOINTS_TSV (STA-guarded cases).
proc run_clock_refinement {} {
  cts::run_clock_refinement
}

# Clock arrivals of every register clock pin predicted stage by stage on the current tree (placement parasitics);
# boundary arrivals of non-buffer cells are read from CTS_STAGE_BOUNDARY_CSV when set.  Writes <csv> and
# <csv>.boundaries.csv.
proc predict_clock_arrivals {csv} {
  cts::predict_clock_arrivals $csv
}
