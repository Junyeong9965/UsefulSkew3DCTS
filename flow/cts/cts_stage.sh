#!/usr/bin/env bash
# One stage of one arm of the 3D CTS chain.
#   usage: cts_stage.sh <stage> <arm_dir> <platform> <design> <placement_dir> <case>
#   <arm_dir>/<stage>/ holds the stage outputs (results/<platform>/<design>/openroad/...), <arm_dir>/../../logs the logs.
#   Per-case recipe in the environment (set by cts_flow.sh): NID BAL_BASE BAL_FULL; EARLY_CLOCK_PLAN / EARLY_CLOCK_LEGAL
#   for the ON chain; THREADS (default 16).
#
# Stages
#   P   Phase 1: balanced 3D tree on the placed design + propagated-clock reference state (phase1.odb/sdc/metrics,
#       leaf bounds, base latency, leaf groups)
#   G   sequential-graph extraction: K processes x 1 thread that take chunks of launches (and, as item 0, the
#       input-port side) from one shared work counter, so a process that finishes early takes more work; integrity
#       check, merge into the single-process row order (identical files for every K); one process over all launches
#       if the check fails.  BLOCKED native admission (latch / gated-clock checks) marks the arm as
#       STA-guarded.
#   GB  STA-guarded arms only: guard endpoints + baseline guard STA on phase1 + guard manifest
#   D   LP + delivery tree + repair + legalization (12 threads); LP target check in the background
#   GA  STA-guarded arms only: guard admission of the D checkpoint (the chain fails if rejected)
#   R   STA-guided refinement of the D checkpoint (14 threads)
#   J   join: the LP target check of D must have passed
#   Q   far clock-buffer relocation on the R checkpoint
#   F   final checkpoint of the arm: links to the Q files, sha256, metrics
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
stage=$1; arm=$2; platform=$3; design=$4; src=$5; c=$6
# K = graph-extraction processes (1 thread each); the merged graph does not depend on K
TH=${THREADS:-16}; K=$(( TH > 1 ? TH : 2 ))
D_TH=$(( TH < 12 ? TH : 12 )); R_TH=$(( TH < 14 ? TH : 14 ))
# stage P: at most 16 threads (the Phase-1 outputs do not depend on the thread count)
P_TH=$(( TH < 16 ? TH : 16 ))
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
  env $(recipe_p1) bash "$CTS_DIR/cts_session.sh" "$arm/P" "$platform" "$design" "$src" phase1 "$P_TH" > "$logs/${an}_P.log" 2>&1
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
    else export EXTRACT_PARTITION=$k/$K EXTRACT_QUEUE=$gq; [[ $k -ne $((K-1)) ]] || export EXTRACT_WRITE_METRICS=1; fi
    OPENROAD_RUN_KEEP=1 bash "$CTS_DIR/openroad_run.sh" "$work" "$platform" "$design" "$odb" "$sdc" "$CTS_DIR/tcl/extract_graph.tcl" "$th"
    echo $? > "$work/RC"
  ) > "$work/run.out" 2>&1
}

stage_G() {
  rm -rf "$G"; mkdir -p "$G/parts" "$G/reports"
  odb=$(readlink -f "$P/phase1.odb"); sdc=$(readlink -f "$P/phase1.sdc")
  sha256sum "$CTS3D_OPENROAD" "$odb" "$sdc" "$CTS_DIR/tcl/extract_graph.tcl" > "$G/INPUTS.sha256"
  # work counter of the K processes: one file on node-local storage (all K processes run on this host; the claims
  # use fcntl locks); removed after the processes have finished
  local gq
  gq=$(mktemp -p /dev/shm cts3d_gq.XXXXXX 2>/dev/null || mktemp -p "${TMPDIR:-/tmp}" cts3d_gq.XXXXXX) || return 1
  { echo "run=$(date +%s%N).$$ host=$(hostname -s) K=$K threads=1 mode=queue"; cat "$G/INPUTS.sha256"; } > "$G/RUN_TOKEN"
  local pids=() k ok=1
  for ((k = 0; k < K; k++)); do
    mkdir -p "$G/parts/p$k"; { cat "$G/RUN_TOKEN"; echo "partition=$k/$K"; } > "$G/parts/p$k/RUN_TOKEN"
    extract_proc $k "$G/parts/p$k" 1 & pids+=($!)
  done
  for pid in "${pids[@]}"; do wait "$pid"; done
  rm -f "$gq"
  "$NATIVE/cts_partitions" check "$G" $K "$G/RUN_TOKEN" > "$G/parts_check.log" 2>&1 || ok=0
  if [[ $ok == 1 ]]; then
    "$NATIVE/cts_partitions" merge "$G/parts" $K "$G/results" > "$G/merge.log" 2>&1 || ok=0
    [[ $ok == 0 ]] || cp "$G/parts/p$((K-1))/reports/metrics.csv" "$G/reports/metrics.csv" || ok=0
  fi
  [[ $ok == 0 ]] || trim "$G/parts"   # merged into G/results; the per-partition logs are not read again
  if [[ $ok == 0 ]]; then   # fallback: one process over all launches
    echo "G_fallback=single_process"; rm -rf "$G/results" "$G/single"; mkdir -p "$G/single"
    extract_proc single "$G/single" "$TH"
    [[ $(cat "$G/single/RC" 2>/dev/null) == 0 ]] || { echo "G single-process fallback failed"; return 1; }
    mv "$G/single/results" "$G/results"; cp "$G/single/reports/metrics.csv" "$G/reports/metrics.csv"
  fi
  for f in pre_cts_ff_timing_graph.csv pre_cts_io_timing_edges.csv ff_admission.status io_admission.status ff_admission_events.csv io_admission_events.csv; do
    [[ -s $G/results/$f ]] || { echo "G missing $f"; return 1; }
  done
  # BLOCKED native admission (unsupported checks present) selects the STA-guarded path
  if grep -q '^BLOCKED' "$G/results/ff_admission.status" "$G/results/io_admission.status"; then touch "$arm/.guarded"; echo "G admission BLOCKED -> guarded path"; fi
  [[ -s $G/reports/metrics.csv ]]
}

stage_GB() {
  rm -rf "$GD"; mkdir -p "$GD/inputs/$c" "$GD/probes"; cp "$CTS_DIR/guard_policy.json" "$GD/GUARD_POLICY.json"
  "$NATIVE/cts_checks" guard-endpoints "$G" "$GD/endpoints.tsv" || return 1
  GUARD_ENDPOINTS_TSV="$GD/endpoints.tsv" bash "$CTS_DIR/openroad_run.sh" "$GD/probes/baseline" "$platform" "$design" \
    "$(readlink -f "$P/phase1.odb")" "$(readlink -f "$P/phase1.sdc")" "$CTS_DIR/tcl/guard_paths.tcl" "$TH" || { echo "GB baseline guard probe failed"; return 1; }
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
  env $(recipe_d) CTS_LP_INCREMENTAL_BOUNDS_CSV="$D/lp_bounds.csv" \
    bash "$CTS_DIR/cts_session.sh" "$arm/D" "$platform" "$design" "$src" delivery "$D_TH" > "$logs/${an}_D.log" 2>&1
  local rc=$?; echo "D session_rc=$rc"
  [[ $rc == 0 && -s $D/4_cts.odb && -s $D/pre_cts_skew_targets.csv ]]
}

stage_GA() {
  GUARD_ENDPOINTS_TSV="$GD/inputs/$c/guard_endpoints.tsv" bash "$CTS_DIR/openroad_run.sh" "$GD/probes/D_guard_placement" "$platform" "$design" \
    "$D/4_cts.odb" "$D/4_cts.sdc" "$CTS_DIR/tcl/guard_paths.tcl" "$TH" || { echo "GA guard probe failed"; return 1; }
  "$NATIVE/cts_checks" guard-eval "$GD/probes/baseline/reports" "$GD/probes/D_guard_placement/reports" "$GD/GUARD_POLICY.json" \
    "$GD/probes/D_guard_placement/reports/GUARD_EVAL.json" > "$GD/D_guard_eval.log" 2>&1
}

stage_R() {
  rm -rf "$arm/R"
  # dont-use list of the platform (both tiers) for the resize candidates
  local du
  du=$(grep -E '^export DONT_USE_CELLS_(UPPER|BOTTOM) +\?=' "$FLOW_HOME_DIR/platforms/$platform/config.mk" | sed -E 's/^[^=]*= *//' | tr '\n' ' ')
  [[ -n "$du" ]] || { echo "no dont-use list for $platform"; return 1; }
  local w=$arm/R; mkdir -p "$R" "$w/session/results"
  cp -fL "$D/pre_cts_skew_targets.csv" "$w/session/results/pre_cts_skew_targets.csv"
  (
    # the other CTS_REFINE_* options keep their defaults (ClockRefinement.cpp)
    export CTS_REFINE_DONT_USE="$du"
    guarded && export CTS_GUARD_ENDPOINTS_TSV="$GD/inputs/$c/guard_endpoints.tsv"
    OPENROAD_RUN_KEEP=1 bash "$CTS_DIR/openroad_run.sh" "$w/session" "$platform" "$design" "$D/4_cts.odb" "$D/4_cts.sdc" "$CTS_DIR/tcl/clock_refinement.tcl" "$R_TH"
  ) > "$logs/${an}_R.log" 2>&1 || { cat "$logs/${an}_R.log"; return 1; }
  mv "$w/session/results/"* "$R/"
  mkdir -p "$w/reports"; cp "$w/session/reports/metrics.csv" "$w/session/reports/electrical.csv" "$w/reports/"
  # the refined checkpoint keeps the delivery SDC byte for byte (write_sdc only reformats it)
  cp -fL "$D/4_cts.sdc" "$R/4_cts.sdc"
  [[ -s $R/4_cts.odb && -s $R/4_cts.def ]] || return 1
  trim "$D/4_cts.odb"   # the refined checkpoint supersedes the delivery checkpoint
}

stage_J() {
  local t=0
  while [[ ! -s $D/verify_targets.rc && $t -lt 3600 ]]; do sleep 1; t=$((t+1)); done
  [[ $(cat "$D/verify_targets.rc" 2>/dev/null) == 0 && -s $D/TARGET_VERIFICATION.json ]]
}

stage_Q() {
  rm -rf "$arm/Q"; mkdir -p "$Q"
  local t0 w=$arm/Q/session; t0=$(date +%s)
  bash "$CTS_DIR/openroad_run.sh" "$w" "$platform" "$design" "$R/4_cts.odb" "$R/4_cts.sdc" "$CTS_DIR/tcl/buffer_relocation.tcl" 8 \
    > "$arm/Q/relocation.log" 2>&1 || return 1
  local r=$w/reports keep
  cp "$r/reloc.csv" "$r/metrics_before.csv" "$r/metrics_after.csv" "$arm/Q/"
  keep=$(grep -c ",KEEP$" "$r/reloc.csv")
  if [[ $keep -gt 0 ]]; then
    cp -L "$R/4_cts.sdc" "$Q/"; cp -L "$R/pre_cts_skew_targets.csv" "$Q/" 2>/dev/null
    CKPT_DIR=$Q bash "$CTS_DIR/openroad_run.sh" "$arm/Q/checkpoint" "$platform" "$design" "$r/edited.odb" "$R/4_cts.sdc" \
      "$CTS_DIR/tcl/write_checkpoint.tcl" 4 > "$arm/Q/checkpoint.log" 2>&1 || return 1
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
