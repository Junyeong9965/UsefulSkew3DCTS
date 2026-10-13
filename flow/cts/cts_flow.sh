#!/usr/bin/env bash
# 3D CTS of one case, from the placed design to the selected CTS checkpoint.
#   usage: cts_flow.sh <case> <placement_dir> <run_dir>
#
#   OFF chain   P -> G -> [GB] -> D -> [GA] -> R -> J -> Q -> F   (arms/off; stages in cts_stage.sh)
#               (the decision starts as soon as D has written its LP targets)
#   decision    one session (early_decision.tcl) on the OFF phase1.odb: early-group selection or, when no tier has a
#               valid shift model, single-root hub candidates; result in decide/DECISION.txt and a plan.tsv
#   ON chain    the same chain with the early-clock plan, only when the decision returned a plan and (by default,
#               CTS3D_ON_GATE=1) the ON-benefit check of the decision predictions passes                (arms/on)
#   selection   route-input preparation and independent STA reload of both arms, plan check; cts_select output
#               selects ON if it accepts the ON arm, else OFF
#   multi-hub   after a hub decision only: prefixes k = 2..3 of the measured hub candidates are built as ON chains
#               (multi_hub/k<k>) and judged by the same rule; the accepted prefix with the largest setup + hold TNS
#               gain is the output (k = 1 is the ON arm)
#   CTS3D_PARALLEL_ARMS=1 (default) runs the arms after the decision concurrently, 0 one after another.
# Output: <run_dir>/results/4_cts.{odb,def,v,sdc} (CTS checkpoint) and <run_dir>/reports/4_cts_timing.rpt; stdout is
# the run log.  Stage data, step logs and step times are in <run_dir>/tmp/, deleted after a successful run (kept on
# failure and with CTS3D_KEEP_INTERMEDIATES=1).
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
c=$1; src=$(cd "$2" && pwd); W=$3
case_info "$c" || exit 2
export NID BAL_BASE BAL_FULL THREADS=${THREADS:-16}
plat=$PLATFORM; des=$DESIGN; sub=results/$plat/$des/openroad
mkdir -p "$W"; W=$(cd "$W" && pwd); RUN=$W/tmp   # stage data; the user-facing result is $W/results and $W/reports
rm -rf "$RUN" "$W/results" "$W/reports"
mkdir -p "$RUN/arms" "$RUN/logs" "$RUN/out"
T=$RUN/out/times.txt
T0=$(date +%s.%N)
{ echo "RUN case=$c platform=$plat design=$des host=$(hostname -s) date=$(date -Is) src=$src threads=$THREADS load=[$(cut -d' ' -f1-3 /proc/loadavg)]"
  echo "RUN binary=$CTS3D_OPENROAD sha256=$(sha256sum "$CTS3D_OPENROAD" | cut -c1-64)"; } > "$T"

# ---------------------------------------------------------------------------------------------- run log
# stdout is the run log: the initial-tree timing, the result and the total time.  Every step is timed in
# tmp/out/times.txt; the OpenROAD console of every step goes to tmp/logs/.
elapsed() { local s=$(( $(date +%s) - ${T0%.*} )); printf '%02d:%02d:%02d' $((s/3600)) $((s%3600/60)) $((s%60)); }
say() { printf '%s\n' "$*"; }
# die <record>: record a failure in the step times and stop (the intermediate data is kept)
die() { echo "FAILED $*" >> "$T"; say "FAILED (step logs and intermediate data kept in $RUN)"; exit 1; }
K_G=$(( THREADS > 1 ? THREADS : 2 ))   # graph-extraction processes (cts_stage.sh)
# fmt_metrics <metrics.csv>: setup/hold TNS/WNS of a metrics file (ps)
fmt_metrics() { [[ -s $1 ]] || return 0
  tail -1 "$1" | awk -F, '{printf "setup TNS %.1f WNS %.2f | hold TNS %.1f WNS %.2f ps", $1, $2, $3, $4}'; }
# log_step <step name> <rc>: the run log reports only the initial tree (after its timing analysis) and failures
log_step() { local n=$1 rc=$2
  [[ $rc == 0 ]] || die "stage=$n rc=$rc"
  if [[ $n == off_G ]]; then
    say "initial 3D clock tree     $(fmt_metrics "$RUN/arms/off/G/reports/metrics.csv")"
    say "useful-skew scheduling, clock construction and refinement ..."
  fi; }
# st <name> <cmd...>: run and time one step; abort the run on failure
st() { local n=$1; shift
  /usr/bin/time -f "$n wall_s=%e user_s=%U sys_s=%S peak_kb=%M" -a -o "$T" "$@" >> "$RUN/logs/stages.log" 2>&1; local rc=$?
  echo "$n rc=$rc load_end=[$(cut -d' ' -f1-3 /proc/loadavg)]" >> "$T"
  log_step "$n" $rc; }
STAGE="bash $CTS_DIR/cts_stage.sh"
# trim <files...>: delete stage databases once no later step reads them (kept with CTS3D_KEEP_INTERMEDIATES=1)
trim() { [[ ${CTS3D_KEEP_INTERMEDIATES:-0} == 1 ]] || rm -f "$@" 2>/dev/null; return 0; }
# chain <arm name> <arm dir> <run dir> <stage names...>: one arm (the arm's .start marks its start)
chain() { local a=$1 dir=$2 run=$3; shift 3; mkdir -p "$dir"; touch "$dir/.start"
  local s; for s in "$@"; do
    if [[ $s == GB || $s == GA ]] && [[ ! -e $dir/.guarded ]]; then continue; fi
    st "${a}_$s" $STAGE "$s" "$dir" "$plat" "$des" "$src" "$c"
  done; }
# the insertion-delay setting of Phase 1 and delivery must agree (the LP is solved on the tree that D builds)
nid_check() { local a=$1 run=$2 p d
  p=$(grep -c "^CTS_NO_INSERTION_DELAY=1$" "$run/arms/$a/P/run_manifest_${plat}_${des}.txt"); d=$(grep -c "^CTS_NO_INSERTION_DELAY=1$" "$run/arms/$a/D/run_manifest_${plat}_${des}.txt")
  echo "NID_CHECK arm=$a P=$p D=$d" >> "$T"
  [[ ($p -gt 0 && $d -gt 0) || ($p == 0 && $d == 0) ]] || die "Phase-1 / delivery insertion-delay mismatch arm=$a"; }
# route-input preparation + independent STA reload of one arm: <arm dir> <prep dir> <out dir of the selection>
prep_native() { local dir=$1 prep=$2 o=$3 tag=$4
  st "PREP_$tag" bash "$CTS_DIR/route_prep.sh" "$prep" "$dir/final" "$plat" "$des" "$src"
  st "NATIVE_$tag" bash "$CTS_DIR/openroad_run.sh" "$prep/native" "$plat" "$des" "$prep/$sub/4_cts.odb" "$prep/$sub/4_cts.sdc" \
     "$CTS_DIR/tcl/timing_metrics.tcl" 4
  cp "$prep/native/reports/metrics.csv" "$o/native_$tag.csv"; cp "$prep/native/reports/electrical.csv" "$o/native_elec_$tag.csv"; }

say "3D CTS  case $c  ($plat / $des, clock period ${src##*/T} ps)"
say "        host $(hostname -s), threads $THREADS"
say "        placement $src"
say "        OpenROAD $CTS3D_OPENROAD"

# ---------------------------------------------------------------------------------------------- OFF chain
# ---------------------------------------------------------------------------------------------- OFF refinement
# R J Q F of the OFF arm do not depend on the decision; with CTS3D_PARALLEL_ARMS=1 they run while the decision works.
# The decision reads three OFF-arm files: P/phase1_leaf_groups.csv, the stage-G graph and D/pre_cts_skew_targets.csv
# (the LP targets, written right after the LP and before the delivery tree; cts_3d.tcl then writes
# D/lp_targets.done).  In parallel mode with the decision enabled, the OFF arm continues from D in the background and
# the decision starts as soon as that marker exists, so it overlaps the rest of D as well as R..F.  The stage outputs
# do not depend on when the decision starts.
PAR=${CTS3D_PARALLEL_ARMS:-1}
off_pid=""
DEC_AT_LP=0
[[ $PAR == 1 && ${CTS3D_EARLY_CLOCK:-1} == 1 ]] && DEC_AT_LP=1
if [[ $DEC_AT_LP == 1 ]]; then
  chain off "$RUN/arms/off" "$RUN" P G GB
  ( chain off "$RUN/arms/off" "$RUN" D
    nid_check off "$RUN"
    [[ ! -e $RUN/arms/off/.guarded ]] || chain off "$RUN/arms/off" "$RUN" GA
    chain off "$RUN/arms/off" "$RUN" R J Q F ) & off_pid=$!
  dm=$RUN/arms/off/D/$sub/lp_targets.done
  while [[ ! -e $dm ]]; do kill -0 "$off_pid" 2>/dev/null || break; sleep 2; done
  if [[ ! -e $dm ]]; then wait "$off_pid"; die "arm=off (before the LP targets of D)"; fi
else
  chain off "$RUN/arms/off" "$RUN" P G GB D
  nid_check off "$RUN"
  [[ -e $RUN/arms/off/.guarded ]] && chain off "$RUN/arms/off" "$RUN" GA
  if [[ $PAR == 1 ]]; then ( chain off "$RUN/arms/off" "$RUN" R J Q F ) & off_pid=$!; fi
fi

# ---------------------------------------------------------------------------------------------- decision
# CTS3D_EARLY_CLOCK=0: no decision and no ON arm; the output is the OFF arm.
plan=""; reason="early-clock construction disabled (CTS3D_EARLY_CLOCK=0)"; kind=""
if [[ ${CTS3D_EARLY_CLOCK:-1} == 1 ]]; then
  DEC=$RUN/decide; mkdir -p "$DEC"
  P1=$RUN/arms/off/P/$sub
  setrc=$(platform_setrc "$plat")
  # clock-tree and clock-net dumps, calibration, early groups and, without a valid shift model, the hub candidates;
  # the session runs on 4 threads, the hub-candidate generation (thread-count independent result) on THREADS
  export EARLY_DEC=$DEC EARLY_REF_ARM=$RUN/arms/off EARLY_CASE=$c EARLY_SETRC=$setrc EARLY_RUN=$RUN EARLY_HUB_THREADS=$THREADS
  st DEC bash "$CTS_DIR/openroad_run.sh" "$DEC/session" "$plat" "$des" "$P1/phase1.odb" "$P1/phase1.sdc" "$CTS_DIR/tcl/early_decision.tcl" 4
  dget() { sed -n "s/^$1=//p" "$DEC/DECISION.txt" | tail -1; }
  status=$(dget early_groups_status)
  echo "DECISION early_groups_status=$status" >> "$T"
  plan=""; reason=""; kind=""
  if [[ $status == selected && $(tail -n +2 "$DEC/early_groups/plan.tsv" | grep -c .) -gt 0 ]]; then
    plan=$DEC/early_groups/plan.tsv; reason="early groups"; kind=groups
  elif [[ $status == model_invalid ]]; then
    H=$DEC/hub; cid=$(dget hub_cid)
    if [[ -n $cid && -s $H/plan/plan.tsv ]]; then plan=$H/plan/plan.tsv; reason="hub $cid"; kind=hub
    else reason="model_invalid; no valid hub candidate"; fi
  else reason=$status
  fi
fi
# ON-benefit gate (CTS3D_ON_GATE=1, default; 0 = no gate): from the decision's own predictions only (cts_select gate:
# predicted TNS gain relative to the Phase-1 TNS and predicted setup WNS change of the selected plan; no STA, no CTS),
# skip the ON arm and the multi-hub prefixes when ON is not expected to be worthwhile.  The decision files and
# out/gate.json are kept either way.
if [[ -n $plan && ${CTS3D_ON_GATE:-1} == 1 ]]; then
  g=$("$NATIVE/cts_select" gate "$c" "$DEC" "$RUN/out/gate.json") || die "stage=GATE"
  echo "GATE $g" >> "$T"   # recorded in tmp/out only (not in the run log)
  if [[ $(jget "$RUN/out/gate.json" decision) == skip ]]; then
    reason="ON-benefit gate skip: $(jget "$RUN/out/gate.json" reason) ($reason)"; plan=""; kind=""
  fi
fi
echo "DECISION plan=${plan:-none} reason=$reason" >> "$T"
# read by G, GB, D and the decision probes; nothing later (when D may still run, it is trimmed after the OFF arm)
[[ $DEC_AT_LP == 1 ]] || trim "$RUN/arms/off/P/$sub/phase1.odb"

# ---------------------------------------------------------------------------------------------- arms after the decision
# The OFF, ON and multi-hub prefix arms use separate directories and THREADS each; with CTS3D_PARALLEL_ARMS=0 they run
# in the order OFF, ON, k=2, k=3.  The selection starts after every arm has finished.
branch_pids=(); branch_names=()
branch() {   # branch <name> <function...>: run one arm in the background (or inline when PAR=0)
  local n=$1; shift
  if [[ $PAR == 1 ]]; then ( "$@" ) & branch_pids+=($!); branch_names+=("$n")
  else ( "$@" ) || die "arm=$n"; fi; }
branch_wait() { local i rc=0
  for i in "${!branch_pids[@]}"; do wait "${branch_pids[$i]}" || { echo "FAILED arm=${branch_names[$i]}" >> "$T"; rc=1; }; done
  branch_pids=(); branch_names=(); [[ $rc == 0 ]] || die "arms"; }

arm_off() {   # serial mode only: the OFF chain + its route-input preparation
  chain off "$RUN/arms/off" "$RUN" R J Q F
  [[ -z $plan ]] || prep_native "$RUN/arms/off" "$RUN/route_prep/off" "$RUN/out" off; }
arm_on() {
  export EARLY_CLOCK_PLAN=$plan EARLY_CLOCK_LEGAL=1
  chain on "$RUN/arms/on" "$RUN" P G GB D; nid_check on "$RUN"; trim "$RUN/arms/on/P/$sub/phase1.odb"
  chain on "$RUN/arms/on" "$RUN" GA R J Q F
  prep_native "$RUN/arms/on" "$RUN/route_prep/on" "$RUN/out" on; }
# one multi-hub prefix arm (plan_k<k>.tsv written by the decision session); a failed build marks the prefix as not built
arm_k() { local p=$1 k=$2 KR=$3
  export EARLY_CLOCK_PLAN=$p EARLY_CLOCK_LEGAL=1 EARLY_HUB_ANCHOR_FALLBACK=1
  chain_k() { local s; mkdir -p "$KR/arms/on"; touch "$KR/arms/on/.start"
    for s in "$@"; do
      if [[ $s == GB || $s == GA ]] && [[ ! -e $KR/arms/on/.guarded ]]; then continue; fi
      /usr/bin/time -f "K${k}_on_$s wall_s=%e user_s=%U sys_s=%S peak_kb=%M" -a -o "$T" $STAGE "$s" "$KR/arms/on" "$plat" "$des" "$src" "$c" \
        >> "$KR/logs/stages.log" 2>&1; local rc=$?
      [[ $rc == 0 ]] || { echo "K${k}_on_$s failed" >> "$T"; return 1; }
    done; }
  chain_k P G GB D || { echo "MULTI k=$k build failed" >> "$T"; return 0; }
  local p1n d1n
  p1n=$(grep -c "CTS_NO_INSERTION_DELAY=1" "$KR/logs/on_P.log"); d1n=$(grep -c "CTS_NO_INSERTION_DELAY=1" "$KR/logs/on_D.log")
  echo "NID_CHECK arm=k$k P_lines=$p1n D_lines=$d1n" >> "$T"
  [[ ($p1n -gt 0 && $d1n -gt 0) || ($p1n == 0 && $d1n == 0) ]] || { echo "MULTI k=$k build failed" >> "$T"; return 0; }
  trim "$KR/arms/on/P/$sub/phase1.odb"
  chain_k GA R J Q F || { echo "MULTI k=$k build failed" >> "$T"; return 0; }
  # every step after a successful build is checked; a failure aborts the run (as in the OFF / ON arms)
  st "K${k}_PREP" bash "$CTS_DIR/route_prep.sh" "$KR/route_prep/on" "$KR/arms/on/final" "$plat" "$des" "$src"
  st "K${k}_NATIVE" bash "$CTS_DIR/openroad_run.sh" "$KR/route_prep/on/native" "$plat" "$des" "$KR/route_prep/on/$sub/4_cts.odb" "$KR/route_prep/on/$sub/4_cts.sdc" \
    "$CTS_DIR/tcl/timing_metrics.tcl" 4
  cp "$KR/route_prep/on/native/reports/metrics.csv" "$KR/out/native_on.csv"
  cp "$KR/route_prep/on/native/reports/electrical.csv" "$KR/out/native_elec_on.csv"
  touch "$KR/.built"; }

MH=$RUN/multi_hub
[[ -n $off_pid ]] || branch off arm_off
if [[ -n $plan ]]; then branch on arm_on; fi
if [[ $kind == hub ]]; then
  for p in "$MH"/plan_k*.tsv; do [[ -e $p ]] || continue
    k=$(basename "$p" .tsv | sed 's/plan_k//'); KR=$MH/k$k; mkdir -p "$KR/arms" "$KR/logs" "$KR/out"
    branch "k$k" arm_k "$p" "$k" "$KR"
  done
fi
if [[ -n $off_pid ]]; then   # parallel mode: the OFF chain started before the decision; its preparation runs here
  wait "$off_pid" || { echo "FAILED arm=off" >> "$T"; branch_wait; die "arm=off"; }
  [[ $DEC_AT_LP != 1 ]] || trim "$RUN/arms/off/P/$sub/phase1.odb"
  [[ -z $plan ]] || prep_native "$RUN/arms/off" "$RUN/route_prep/off" "$RUN/out" off
fi
branch_wait

# ---------------------------------------------------------------------------------------------- selection
out_arm=off; why="no early structure: $reason"
if [[ -n $plan ]]; then
  st CHECK "$NATIVE/cts_select" plan "$c" "$RUN/route_prep/on/$sub/4_cts.def" "$RUN/route_prep/off/$sub/4_cts.def" "$plan" "$RUN/out/check_on.json"
  st SELECT "$NATIVE/cts_select" output "$c" "$RUN" "$RUN/route_prep/off" "$RUN/route_prep/on"
  d=$(jget "$RUN/out/select.json" decision)
  if [[ $d == accept ]]; then out_arm=on; fi
  why="select_output $d; $reason"
fi
echo "OUTPUT $out_arm ($why)" >> "$T"

# ---------------------------------------------------------------------------------------------- multi-hub prefixes
if [[ $kind == hub ]]; then
  res=("1 $RUN/out/select.json $RUN/arms/on")
  for p in "$MH"/plan_k*.tsv; do [[ -e $p ]] || continue
    k=$(basename "$p" .tsv | sed 's/plan_k//'); KR=$MH/k$k
    [[ -e $KR/.built ]] || continue
    cp "$RUN/out/native_off.csv" "$RUN/out/native_elec_off.csv" "$KR/out/"
    st "K${k}_CHECK" "$NATIVE/cts_select" plan "$c" "$KR/route_prep/on/$sub/4_cts.def" "$RUN/route_prep/off/$sub/4_cts.def" "$p" "$KR/out/check_on.json"
    "$NATIVE/cts_select" output "$c" "$KR" "$RUN/route_prep/off" "$KR/route_prep/on" > "$KR/out/SELECT.txt" || die "stage=K${k}_SELECT"
    res+=("$k $KR/out/select.json $KR/arms/on")
  done
  "$NATIVE/cts_select" multihub "$c" "$MH/multi_hub.json" "${res[@]}" > /dev/null || die "stage=MULTI_HUB"
  mk=$(jget "$MH/multi_hub.json" output)
  echo "MULTI_HUB $mk" >> "$T"
  if [[ $mk == "on k=1" ]]; then out_arm=on; why="multi-hub k=1 (select_output accept); $reason"
  elif [[ $mk == on* ]]; then out_arm=${mk#on }; why="multi-hub $mk (select_output accept, largest TNS gain); $reason"
  else out_arm=off; why="multi-hub: no prefix accepted; $reason"; fi
  echo "OUTPUT $out_arm ($why)" >> "$T"
fi

# ---------------------------------------------------------------------------------------------- output
case $out_arm in
  off) arm_dir=$RUN/arms/off; oplan="";;
  on)  arm_dir=$RUN/arms/on; oplan=$plan;;
  k=*) arm_dir=$RUN/multi_hub/k${out_arm#k=}/arms/on; oplan=$RUN/multi_hub/plan_k${out_arm#k=}.tsv;;
esac
echo "END case=$c end_to_end_wall_s=$(echo "$(date +%s.%N) - $T0" | bc) date=$(date -Is)" >> "$T"
"$NATIVE/cts_select" report "$RUN" "$c" "$out_arm" "$arm_dir" "$why" "${oplan:-}" > /dev/null || die "stage=REPORT"
mkdir -p "$W/results" "$W/reports"
for f in 4_cts.odb 4_cts.def 4_cts.v 4_cts.sdc; do cp -L "$arm_dir/final/$f" "$W/results/$f"; done
res=$(fmt_metrics "$arm_dir/final/metrics.csv")
tail -1 "$arm_dir/final/metrics.csv" | awk -F, -v c="$c" -v p="$plat" -v d="$des" -v t="${src##*/T}" '{
  printf "CTS result of %s (%s / %s, clock period %s ps)\n", c, p, d, t
  printf "STA of results/4_cts.odb with placement parasitics and propagated clocks (ps)\n\n"
  printf "%-8s %14s %12s\n", "", "TNS", "WNS"
  printf "%-8s %14.1f %12.2f\n", "setup", $1, $2
  printf "%-8s %14.1f %12.2f\n", "hold", $3, $4 }' > "$W/reports/4_cts_timing.rpt"
[[ ${CTS3D_KEEP_INTERMEDIATES:-0} == 1 ]] || rm -rf "$RUN"
say "CTS result                $res"
say "results $W/results   total $(elapsed) (h:m:s)"
