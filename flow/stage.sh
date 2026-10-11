#!/usr/bin/env bash
# One stage of one arm of the 3D CTS chain.
#   usage: stage.sh <stage> <arm_dir> <platform> <design> <placement_dir> <case>
#   <arm_dir>/<stage>/ holds the stage outputs (results/<platform>/<design>/openroad/...), <arm_dir>/../../logs the logs.
#   Per-case recipe in the environment (set by policy.sh): NID BAL_BASE BAL_FULL; EARLY_CLOCK_PLAN / EARLY_CLOCK_LEGAL
#   for the ON chain; THREADS (default 16).
#
# Stages
#   P   Phase 1: balanced 3D tree on the placed design + propagated-clock reference state (phase1.odb/sdc/metrics,
#       leaf bounds, base latency, leaf groups)
#   G   sequential-graph extraction: 16 processes x 1 thread over a deterministic launch partition (partition 0 weight
#       50 %), integrity check, deterministic merge into the single-process row order; single-process fallback.
#       Native admission BLOCKED (unsupported checks: latch / gated-clock paths) marks the arm as STA-guarded.
#   GB  STA-guarded arms only: guard endpoints + baseline guard STA on phase1 + guard manifest
#   D   LP + delivery tree + repair + legalization (12 threads); LP target check in the background
#   GA  STA-guarded arms only: guard admission of the D checkpoint (the chain fails if rejected)
#   R   STA-guided refinement of the D checkpoint (14 threads)
#   J   join: the LP target check of D must have passed
#   Q   far clock-buffer relocation on the R checkpoint
#   F   final checkpoint of the arm: links to the Q files, sha256, metrics of the relocated circuit
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
stage=$1; arm=$2; platform=$3; design=$4; src=$5; c=$6
TH=${THREADS:-16}; K=16; P0W=50
D_TH=$(( TH < 12 ? TH : 12 )); R_TH=$(( TH < 14 ? TH : 14 ))
sub=results/$platform/$design/openroad
P=$arm/P/$sub; G=$arm/G; D=$arm/D/$sub; GD=$arm/guard; R=$arm/R/$sub; Q=$arm/Q/$sub
logs=$(cd "$arm/../.." && pwd)/logs; mkdir -p "$logs"; an=$(basename "$arm")
guarded() { [[ -e $arm/.guarded ]]; }
trim() { [[ ${CTS3D_KEEP_INTERMEDIATES:-0} == 1 ]] || rm -rf "$@" 2>/dev/null; return 0; }   # consumed stage data
recipe_p1() { echo "CTS_NO_INSERTION_DELAY=$NID"; }
recipe_d() {
  echo "CTS_NO_INSERTION_DELAY=$NID"
  [[ $BAL_BASE == 1 ]] && echo "CTS_BALANCER_BASE_RESTORE=1"
  [[ $BAL_FULL == 1 ]] && echo "CTS_BALANCER_FULL_TRAVERSE=1"
  return 0
}

stage_P() {
  rm -rf "$arm/P"; mkdir -p "$P"
  env $(recipe_p1) bash "$FLOW/cts_session.sh" "$arm/P" "$platform" "$design" "$src" phase1 "$TH" > "$logs/${an}_P.log" 2>&1
  echo "P session_rc=$?"
  # macros.txt may be empty (design without macros); every other file must be non-empty
  for f in phase1.odb phase1.sdc phase1.metrics pre_cts_leaf_bounds.csv cts_base_latency.csv phase1_leaf_groups.csv macros.txt; do
    [[ ( -s $P/$f || ( $f == macros.txt && -e $P/$f ) ) && $P/$f -nt $arm/.start ]] || { echo "P missing or stale $f"; return 1; }
  done
}

extract_proc() {  # <k|single> <workdir> <threads>
  local k=$1 work=$2 th=$3
  (
    if [[ $k == single ]]; then export EXTRACT_PARTITION=0/1 EXTRACT_WRITE_METRICS=1
    else export EXTRACT_PARTITION=$k/$K EXTRACT_PARTITION_P0_WEIGHT=$P0W; [[ $k -ne $((K-1)) ]] || export EXTRACT_WRITE_METRICS=1; fi
    export EXTRACT_MODE=sta_validated CTS_HOLD_POLICY=nonregression EXTRACT_REUSE_FF_PO=1 EXTRACT_FUSE_MINMAX=1
    OPENROAD_RUN_KEEP=1 bash "$FLOW/openroad_run.sh" "$work" "$platform" "$design" "$odb" "$sdc" placement "$FLOW/tcl/extract_graph.tcl" "$th"
    echo $? > "$work/RC"
  ) > "$work/run.out" 2>&1
}

stage_G() {
  rm -rf "$G"; mkdir -p "$G/parts" "$G/reports"
  odb=$(readlink -f "$P/phase1.odb"); sdc=$(readlink -f "$P/phase1.sdc")
  sha256sum "$CTS3D_OPENROAD" "$odb" "$sdc" "$FLOW/tcl/extract_graph.tcl" > "$G/INPUTS.sha256"
  { echo "run=$(date +%s%N).$$ host=$(hostname -s) K=$K threads=1 p0_weight=$P0W reuse=1 fuse=1"; cat "$G/INPUTS.sha256"; } > "$G/RUN_TOKEN"
  local pids=() k ok=1
  for ((k = 0; k < K; k++)); do
    mkdir -p "$G/parts/p$k"; { cat "$G/RUN_TOKEN"; echo "partition=$k/$K"; } > "$G/parts/p$k/RUN_TOKEN"
    extract_proc $k "$G/parts/p$k" 1 & pids+=($!)
  done
  for pid in "${pids[@]}"; do wait "$pid"; done
  "$NATIVE/cts_partitions" check "$G" $K "$G/RUN_TOKEN" > "$G/parts_check.log" 2>&1 || ok=0
  if [[ $ok == 1 ]]; then
    "$NATIVE/cts_partitions" merge "$G/parts" $K "$G/results" > "$G/merge.log" 2>&1 || ok=0
    [[ $ok == 0 ]] || cp "$G/parts/p$((K-1))/reports/metrics.csv" "$G/reports/metrics.csv" || ok=0
  fi
  [[ $ok == 0 ]] || trim "$G/parts"   # merged into G/results; the per-partition logs are not read again
  if [[ $ok == 0 ]]; then   # safety path: one process over all launches (same binary and options)
    echo "G_fallback=single_process"; rm -rf "$G/results" "$G/single"; mkdir -p "$G/single"
    extract_proc single "$G/single" "$TH"
    [[ $(cat "$G/single/RC" 2>/dev/null) == 0 ]] || { echo "G single-process fallback failed"; return 1; }
    mv "$G/single/results" "$G/results"; cp "$G/single/reports/metrics.csv" "$G/reports/metrics.csv"
  fi
  for f in pre_cts_ff_timing_graph.csv pre_cts_io_timing_edges.csv ff_admission.status io_admission.status ff_admission_events.csv io_admission_events.csv; do
    [[ -s $G/results/$f ]] || { echo "G missing $f"; return 1; }
  done
  # the STA-guarded path is chosen from the data: BLOCKED native admission (unsupported checks present)
  if grep -q '^BLOCKED' "$G/results/ff_admission.status" "$G/results/io_admission.status"; then touch "$arm/.guarded"; echo "G admission BLOCKED -> guarded path"; fi
  [[ -s $G/reports/metrics.csv ]]
}

stage_GB() {
  rm -rf "$GD"; mkdir -p "$GD/inputs/$c" "$GD/probes"; cp "$FLOW/guard_policy.json" "$GD/GUARD_POLICY.json"
  "$NATIVE/cts_checks" guard-endpoints "$G" "$GD/endpoints.tsv" || return 1
  GUARD_ENDPOINTS_TSV="$GD/endpoints.tsv" bash "$FLOW/openroad_run.sh" "$GD/probes/baseline" "$platform" "$design" \
    "$(readlink -f "$P/phase1.odb")" "$(readlink -f "$P/phase1.sdc")" placement "$FLOW/tcl/guard_paths.tcl" "$TH" || { echo "GB baseline guard probe failed"; return 1; }
  "$NATIVE/cts_checks" guard-manifest "$c" "$G" "$(dirname "$(readlink -f "$P/phase1.odb")")" "$GD/probes/baseline/reports" "$GD"
}

stage_D() {
  rm -rf "$arm/D"; mkdir -p "$D"
  # LP increment bounds: members of an early group stay on their early leaf (bound 0); a register that is not a
  # Phase-1 leaf sink (behind a per-register gated-clock inverter clone) and every macro cannot be reached by a delay
  # chain (bound 0); every other node keeps the standard bound
  "$NATIVE/cts_checks" lp-bounds "${EARLY_CLOCK_PLAN:-}" "$G/results/pre_cts_ff_timing_graph.csv" "$G/results/pre_cts_io_timing_edges.csv" "$D/lp_bounds.csv" "$P" || return 1
  local dd=$D
  if guarded; then
    for f in pre_cts_ff_timing_graph.csv pre_cts_io_timing_edges.csv ff_admission.status io_admission.status pre_cts_leaf_bounds.csv \
             cts_base_latency.csv phase1.odb phase1.sdc phase1_leaf_groups.csv phase1.metrics; do
      [[ ! -e $GD/inputs/$c/$f ]] || ln -sfn "$GD/inputs/$c/$f" "$dd/$f"
    done
    export CTS_STA_GUARD_MANIFEST="$GD/inputs/$c/guard_manifest.json"
  else
    for f in pre_cts_ff_timing_graph.csv pre_cts_io_timing_edges.csv ff_admission.status io_admission.status; do ln -sfn "$G/results/$f" "$dd/$f"; done
    for f in phase1.odb phase1.sdc; do ln -sfn "$(readlink -f "$P/$f")" "$dd/$f"; done
    for f in phase1.metrics pre_cts_leaf_bounds.csv cts_base_latency.csv phase1_leaf_groups.csv; do cp -L "$P/$f" "$dd/$f"; done
  fi
  env $(recipe_d) CTS_LOAD_AWARE_TAPS=1 CTS_HOLD_POLICY=nonregression CTS_HOLD_RESIDUAL_WEIGHT=1 EXTRACT_MODE=sta_validated \
    CTS_LP_INCREMENTAL_BOUNDS_CSV="$D/lp_bounds.csv" \
    bash "$FLOW/cts_session.sh" "$arm/D" "$platform" "$design" "$src" delivery "$D_TH" > "$logs/${an}_D.log" 2>&1
  local rc=$?; echo "D session_rc=$rc"
  [[ $rc == 0 && -s $D/4_cts.odb && -s $D/4_cts.def && -s $D/pre_cts_skew_targets.csv ]]
}

stage_GA() {
  GUARD_ENDPOINTS_TSV="$GD/inputs/$c/guard_endpoints.tsv" bash "$FLOW/openroad_run.sh" "$GD/probes/D_guard_placement" "$platform" "$design" \
    "$D/4_cts.odb" "$D/4_cts.sdc" placement "$FLOW/tcl/guard_paths.tcl" "$TH" || { echo "GA guard probe failed"; return 1; }
  "$NATIVE/cts_checks" guard-eval "$GD/probes/baseline/reports" "$GD/probes/D_guard_placement/reports" "$GD/GUARD_POLICY.json" \
    "$GD/probes/D_guard_placement/reports/GUARD_EVAL.json" > "$GD/D_guard_eval.log" 2>&1
}

stage_R() {
  rm -rf "$arm/R"
  # dont-use list of the platform (both tiers), as the resize candidates must follow the flow's library restrictions
  local du
  du=$(grep -E '^export DONT_USE_CELLS_(UPPER|BOTTOM) +\?=' "$FLOW_HOME_DIR/platforms/$platform/config.mk" | sed -E 's/^[^=]*= *//' | tr '\n' ' ')
  [[ -n "$du" ]] || { echo "no dont-use list for $platform"; return 1; }
  local w=$arm/R; mkdir -p "$R" "$w/session/results"
  cp -fL "$D/pre_cts_skew_targets.csv" "$w/session/results/pre_cts_skew_targets.csv"
  (
    export CTS_REFINE_DONT_USE="$du" CTS_REFINE_KINDS=bypass,sink,resize CTS_REFINE_SINK_SETUP_MARGIN_PS=25 \
      CTS_REFINE_RESIZE_RADIUS_UM=3 CTS_REFINE_MAX_SETUP_PER_HOLD=2 CTS_REFINE_HOLD_WNS_VS_CURRENT=1 \
      CTS_REFINE_MAX_CAND=60 CTS_REFINE_MAX_SEC=2400
    guarded && export CTS_GUARD_ENDPOINTS_TSV="$GD/inputs/$c/guard_endpoints.tsv"
    OPENROAD_RUN_KEEP=1 bash "$FLOW/openroad_run.sh" "$w/session" "$platform" "$design" "$D/4_cts.odb" "$D/4_cts.sdc" placement "$FLOW/tcl/clock_refinement.tcl" "$R_TH"
  ) > "$logs/${an}_R.log" 2>&1 || { cat "$logs/${an}_R.log"; return 1; }
  mv "$w/session/results/"* "$R/"
  mkdir -p "$w/reports"; cp "$w/session/reports/metrics.csv" "$w/session/reports/electrical.csv" "$w/reports/"
  # the refined checkpoint keeps the delivery SDC byte for byte (write_sdc only reformats it)
  cp -fL "$D/4_cts.sdc" "$R/4_cts.sdc"
  [[ -s $R/4_cts.odb && -s $R/4_cts.def ]] || return 1
  trim "$D/4_cts.odb" "$D/4_cts.def" "$D/4_cts.v"   # the refined checkpoint supersedes the delivery checkpoint
}

stage_J() {
  local t=0
  while [[ ! -s $D/verify_targets.rc && $t -lt 3600 ]]; do sleep 1; t=$((t+1)); done
  [[ $(cat "$D/verify_targets.rc" 2>/dev/null) == 0 && -s $D/TARGET_VERIFICATION.json ]]
}

stage_Q() {
  rm -rf "$arm/Q"; mkdir -p "$Q"
  local t0 w=$arm/Q/session; t0=$(date +%s)
  bash "$FLOW/openroad_run.sh" "$w" "$platform" "$design" "$R/4_cts.odb" "$R/4_cts.sdc" placement "$FLOW/tcl/buffer_relocation.tcl" 8 \
    > "$arm/Q/relocation.log" 2>&1 || return 1
  local r=$w/reports keep
  cp "$r/reloc.csv" "$r/metrics_before.csv" "$r/metrics_after.csv" "$arm/Q/"
  keep=$(grep -c ",KEEP$" "$r/reloc.csv")
  if [[ $keep -gt 0 ]]; then
    cp -L "$R/4_cts.sdc" "$Q/"; cp -L "$R/pre_cts_skew_targets.csv" "$Q/" 2>/dev/null
    CKPT_DIR=$Q bash "$FLOW/openroad_run.sh" "$arm/Q/checkpoint" "$platform" "$design" "$r/edited.odb" "$R/4_cts.sdc" placement \
      "$FLOW/tcl/write_checkpoint.tcl" 4 > "$arm/Q/checkpoint.log" 2>&1 || return 1
  else
    for f in 4_cts.odb 4_cts.def 4_cts.v 4_cts.sdc pre_cts_skew_targets.csv; do ln -sfn "$(readlink -f "$R/$f")" "$Q/$f"; done
  fi
  echo "Q keep=$keep candidates=$(($(wc -l < "$r/reloc.csv")-1)) wall_s=$(( $(date +%s)-t0 )) before=$(tail -1 "$r/metrics_before.csv") after=$(tail -1 "$r/metrics_after.csv")" | tee "$arm/Q/Q_SUMMARY.txt"
  trim "$r/edited.odb"
  [[ -L $Q/4_cts.odb ]] || trim "$R/4_cts.odb" "$R/4_cts.def" "$R/4_cts.v"   # Q holds its own checkpoint
}

stage_F() {
  rm -rf "$arm/final"; mkdir -p "$arm/final"
  for f in 4_cts.odb 4_cts.def 4_cts.v 4_cts.sdc pre_cts_skew_targets.csv; do ln -s "../Q/$sub/$f" "$arm/final/$f"; done
  ( cd "$arm/final" && sha256sum -L 4_cts.odb 4_cts.def 4_cts.v 4_cts.sdc pre_cts_skew_targets.csv > FINAL.sha256 2>/dev/null || \
      sha256sum 4_cts.odb 4_cts.def 4_cts.v 4_cts.sdc pre_cts_skew_targets.csv > FINAL.sha256 )
  cp "$arm/Q/metrics_after.csv" "$arm/final/metrics.csv"
}

case $stage in P|G|GB|D|GA|R|J|Q|F) "stage_$stage";; *) echo "unknown stage $stage"; exit 2;; esac
