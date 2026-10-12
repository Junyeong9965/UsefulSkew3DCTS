#!/usr/bin/env bash
# 3D CTS of one case, from the placed design to the selected CTS checkpoint.
#   usage: cts_flow.sh <case> <placement_dir> <run_dir>
#
#   OFF chain   P -> G -> [GB] -> D -> [GA] -> R -> J -> Q -> F   (arms/off; stages in cts_stage.sh)
#   decision    one session (early_decision.tcl) on the OFF phase1.odb: early-group selection or, when no tier has a
#               valid shift model, single-root hub candidates; result in decide/DECISION.txt and a plan.tsv
#   ON chain    the same chain with the early-clock plan, only when the decision returned a plan   (arms/on)
#   selection   route-input preparation and independent STA reload of both arms, plan check; cts_select output
#               selects ON if it accepts the ON arm, else OFF
#   multi-hub   after a hub decision only: prefixes k = 2..3 of the measured hub candidates are built as ON chains
#               (multi_hub/k<k>) and judged by the same rule; the accepted prefix with the largest setup + hold TNS
#               gain is the output (k = 1 is the ON arm)
#   CTS3D_PARALLEL_ARMS=1 (default) runs the arms after the decision concurrently, 0 one after another.
# Output: <run_dir>/OUTPUT/ (4_cts.{odb,def,v,sdc}, pre_cts_skew_targets.csv); the timing table of every built arm,
# the selection record, the early-clock plan and the step times stay in <run_dir>/work/.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
c=$1; src=$(cd "$2" && pwd); W=$3
case_info "$c" || exit 2
export NID BAL_BASE BAL_FULL THREADS=${THREADS:-16}
plat=$PLATFORM; des=$DESIGN; sub=results/$plat/$des/openroad
mkdir -p "$W"; W=$(cd "$W" && pwd); RUN=$W/work   # stage data under work/; the user-facing result is $W/OUTPUT
mkdir -p "$RUN"
exec 9> "$RUN/.lock"; flock -n 9 || { echo "$RUN is in use by another run"; exit 1; }
rm -rf "$RUN/arms" "$RUN/decide" "$RUN/logs" "$RUN/out" "$RUN/route_prep" "$RUN/multi_hub" "$RUN/OUTPUT" "$W/OUTPUT"
mkdir -p "$RUN/arms" "$RUN/logs" "$RUN/out"
T=$RUN/out/times.txt
T0=$(date +%s.%N)
{ echo "RUN case=$c platform=$plat design=$des host=$(hostname -s) date=$(date -Is) src=$src threads=$THREADS load=[$(cut -d' ' -f1-3 /proc/loadavg)]"
  echo "RUN binary=$CTS3D_OPENROAD sha256=$(sha256sum "$CTS3D_OPENROAD" | cut -c1-64)"; } > "$T"

# ---------------------------------------------------------------------------------------------- run log
# stdout is the run log (<run_dir>/cts.log): step start/end with wall, CPU and peak memory, the timing after the steps that
# change the circuit, the decision and the output.  Checking steps are timed in work/out/times.txt only; the OpenROAD
# console of every step goes to work/logs/.
elapsed() { local s=$(( $(date +%s) - ${T0%.*} )); printf '%02d:%02d:%02d' $((s/3600)) $((s%3600/60)) $((s%60)); }
say() { printf '%s  %s\n' "$(elapsed)" "$*"; }
# step_title <step name>: arm and description of a step for the log
step_title() { local n=$1 a="" s=$1
  case $n in
    off_*) a=baseline; s=${n#off_};;  on_*) a=early; s=${n#on_};;
    K[0-9]*_on_*) a="early k=${n%%_on_*}"; a=${a/k=K/k=}; s=${n#*_on_};;
    K[0-9]*_*) a="early k=${n%%_*}"; a=${a/k=K/k=}; s=${n#*_};;
    PREP_*|NATIVE_*) a=${n#*_}; s=${n%%_*};;
    DEC) a=planning; s=DEC;;
  esac
  case $s in
    P) s="initial 3D clock tree";; G) s="timing graph extraction ($K_G processes)";; GB) s="STA guard baseline";;
    D) s="useful-skew scheduling + shared delay chains";; GA) s="STA guard admission";; R) s="clock-tree refinement";;
    J) s="LP target check";; Q) s="clock-buffer relocation";; F) s="final checkpoint";;
    PREP) s="route-input preparation";; NATIVE) s="independent STA reload";; DEC) s="early-clock calibration and register grouping";;
    CHECK) s="plan check";; SELECT) s="ON/OFF selection";;
  esac
  printf '%-11s %s' "${a:-selection}" "$s"; }
# quiet <step name>: checking steps that are timed but not printed in the run log
quiet() { case ${1##*_} in GB|GA|J|F|CHECK|SELECT) return 0;; esac; case $1 in PREP_*|NATIVE_*|K[0-9]*_PREP|K[0-9]*_NATIVE) return 0;; esac; return 1; }
K_G=$(( THREADS > 1 ? THREADS : 2 ))   # graph-extraction processes (cts_stage.sh)
# fmt_metrics <metrics.csv>: setup/hold TNS/WNS of a metrics file (ps)
fmt_metrics() { [[ -s $1 ]] || return 0
  tail -1 "$1" | awk -F, '{printf "setup TNS %.1f WNS %.2f | hold TNS %.1f WNS %.2f ps", $1, $2, $3, $4}'; }
# step_metrics <step name>: metrics file of the circuit after the step (empty if the step does not change it)
step_metrics() { local n=$1 d k
  case $n in
    off_*) d=$RUN/arms/off;;  on_*) d=$RUN/arms/on;;
    K[0-9]*_on_*) k=${n%%_on_*}; d=$RUN/multi_hub/k${k#K}/arms/on;;
    *) return 0;;
  esac
  case ${n##*_} in G) echo "$d/G/reports/metrics.csv";; R) echo "$d/R/reports/metrics.csv";; Q) echo "$d/Q/metrics_after.csv";; esac; }
# log_step <step name> <rc>: end line of a step from its time record
log_step() { local n=$1 rc=$2 l w u p m
  l=$(grep "^$n wall_s=" "$T" | tail -1)
  w=$(sed -n 's/.*wall_s=\([^ ]*\).*/\1/p' <<< "$l"); u=$(sed -n 's/.*user_s=\([^ ]*\).*/\1/p' <<< "$l"); p=$(sed -n 's/.*peak_kb=\([^ ]*\).*/\1/p' <<< "$l")
  if [[ $rc != 0 ]]; then say "$(step_title "$n")  FAILED (rc=$rc, see work/logs/)"; return; fi
  quiet "$n" && return 0
  say "$(printf '%-70s %8.1f s  cpu %8.1f s  mem %5.1f GB' "$(step_title "$n")" "${w:-0}" "${u:-0}" "$(echo "${p:-0}/1048576" | bc -l)")"
  m=$(step_metrics "$n"); [[ -z $m ]] || { m=$(fmt_metrics "$m"); [[ -z $m ]] || say "          -> $m"; }; }
# st <name> <cmd...>: run and time one step; abort the run on failure
st() { local n=$1; shift
  quiet "$n" || say "$(step_title "$n")  ..."
  /usr/bin/time -f "$n wall_s=%e user_s=%U sys_s=%S peak_kb=%M" -a -o "$T" "$@" >> "$RUN/logs/stages.log" 2>&1; local rc=$?
  echo "$n rc=$rc load_end=[$(cut -d' ' -f1-3 /proc/loadavg)]" >> "$T"
  log_step "$n" $rc
  [[ $rc == 0 ]] || { echo "FAILED stage=$n" >> "$T"; exit 1; }; }
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
  [[ ($p -gt 0 && $d -gt 0) || ($p == 0 && $d == 0) ]] || { echo "FAILED Phase-1 / delivery insertion-delay mismatch arm=$a" | tee -a "$T"; exit 1; }; }
# route-input preparation + independent STA reload of one arm: <arm dir> <prep dir> <out dir of the selection>
prep_native() { local dir=$1 prep=$2 o=$3 tag=$4
  st "PREP_$tag" bash "$CTS_DIR/route_prep.sh" "$prep" "$dir/final" "$plat" "$des" "$src"
  st "NATIVE_$tag" bash "$CTS_DIR/openroad_run.sh" "$prep/native" "$plat" "$des" "$prep/$sub/4_cts.odb" "$prep/$sub/4_cts.sdc" \
     "$CTS_DIR/tcl/timing_metrics.tcl" 4
  cp "$prep/native/reports/metrics.csv" "$o/native_$tag.csv"; cp "$prep/native/reports/electrical.csv" "$o/native_elec_$tag.csv"; }

say "3D CTS  case $c  ($plat / $des, clock period ${src##*/T} ps)"
early=off; [[ ${CTS3D_EARLY_CLOCK:-1} != 1 ]] || early=on
say "        host $(hostname -s), threads $THREADS, early-clock construction $early"
say "        placement $src"
say "        OpenROAD $CTS3D_OPENROAD"
say "        step logs: $RUN/logs/   (columns: elapsed h:m:s | step | wall | cpu | peak memory)"

# ---------------------------------------------------------------------------------------------- OFF chain
chain off "$RUN/arms/off" "$RUN" P G GB D
nid_check off "$RUN"
[[ -e $RUN/arms/off/.guarded ]] && chain off "$RUN/arms/off" "$RUN" GA

# ---------------------------------------------------------------------------------------------- OFF refinement
# R J Q F of the OFF arm do not depend on the decision; with CTS3D_PARALLEL_ARMS=1 they start here.
PAR=${CTS3D_PARALLEL_ARMS:-1}
off_pid=""
if [[ $PAR == 1 ]]; then ( chain off "$RUN/arms/off" "$RUN" R J Q F ) & off_pid=$!; fi

# ---------------------------------------------------------------------------------------------- decision
# CTS3D_EARLY_CLOCK=0 (run_cts.sh --early off): no decision and no ON arm; the output is the OFF arm.
plan=""; reason="early-clock construction disabled (--early off)"; kind=""
if [[ ${CTS3D_EARLY_CLOCK:-1} == 1 ]]; then
  DEC=$RUN/decide; mkdir -p "$DEC"
  P1=$RUN/arms/off/P/$sub
  setrc=$(platform_setrc "$plat")
  # clock-tree and clock-net dumps, calibration, early groups and, without a valid shift model, the hub candidates
  export EARLY_DEC=$DEC EARLY_REF_ARM=$RUN/arms/off EARLY_CASE=$c EARLY_SETRC=$setrc EARLY_RUN=$RUN
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
echo "DECISION plan=${plan:-none} reason=$reason" >> "$T"
trim "$RUN/arms/off/P/$sub/phase1.odb"   # read by G, GB, D and the decision probes; nothing later

# ---------------------------------------------------------------------------------------------- arms after the decision
# The OFF, ON and multi-hub prefix arms use separate directories and THREADS each; with CTS3D_PARALLEL_ARMS=0 they run
# in the order OFF, ON, k=2, k=3.  The selection starts after every arm has finished.
branch_pids=(); branch_names=()
branch() {   # branch <name> <function...>: run one arm in the background (or inline when PAR=0)
  local n=$1; shift
  if [[ $PAR == 1 ]]; then ( "$@" ) & branch_pids+=($!); branch_names+=("$n")
  else ( "$@" ) || { echo "FAILED arm=$n" | tee -a "$T"; exit 1; }; fi; }
branch_wait() { local i rc=0
  for i in "${!branch_pids[@]}"; do wait "${branch_pids[$i]}" || { echo "FAILED arm=${branch_names[$i]}" | tee -a "$T"; rc=1; }; done
  branch_pids=(); branch_names=(); [[ $rc == 0 ]] || exit 1; }

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
      quiet "K${k}_on_$s" || say "$(step_title "K${k}_on_$s")  ..."
      /usr/bin/time -f "K${k}_on_$s wall_s=%e user_s=%U sys_s=%S peak_kb=%M" -a -o "$T" $STAGE "$s" "$KR/arms/on" "$plat" "$des" "$src" "$c" \
        >> "$KR/logs/stages.log" 2>&1; local rc=$?
      log_step "K${k}_on_$s" $rc
      [[ $rc == 0 ]] || { echo "K${k}_on_$s failed" >> "$T"; return 1; }
    done; }
  chain_k P G GB D || { echo "MULTI k=$k build failed" >> "$T"; say "early k=$k prefix not built (candidate dropped)"; return 0; }
  local p1n d1n
  p1n=$(grep -c "CTS_NO_INSERTION_DELAY=1" "$KR/logs/on_P.log"); d1n=$(grep -c "CTS_NO_INSERTION_DELAY=1" "$KR/logs/on_D.log")
  echo "NID_CHECK arm=k$k P_lines=$p1n D_lines=$d1n" >> "$T"
  [[ ($p1n -gt 0 && $d1n -gt 0) || ($p1n == 0 && $d1n == 0) ]] || { echo "MULTI k=$k build failed" >> "$T"; say "early k=$k prefix not built (candidate dropped)"; return 0; }
  trim "$KR/arms/on/P/$sub/phase1.odb"
  chain_k GA R J Q F || { echo "MULTI k=$k build failed" >> "$T"; say "early k=$k prefix not built (candidate dropped)"; return 0; }
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
  wait "$off_pid" || { echo "FAILED arm=off" | tee -a "$T"; branch_wait; exit 1; }
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
    "$NATIVE/cts_select" output "$c" "$KR" "$RUN/route_prep/off" "$KR/route_prep/on" > "$KR/out/SELECT.txt" || { echo "FAILED stage=K${k}_SELECT" | tee -a "$T"; exit 1; }
    res+=("$k $KR/out/select.json $KR/arms/on")
  done
  "$NATIVE/cts_select" multihub "$c" "$MH/multi_hub.json" "${res[@]}" > /dev/null || { echo "FAILED stage=MULTI_HUB" | tee -a "$T"; exit 1; }
  mk=$(jget "$MH/multi_hub.json" output)
  echo "MULTI_HUB $mk" >> "$T"
  if [[ $mk == "on k=1" ]]; then out_arm=on; why="multi-hub k=1 (select_output accept); $reason"
  elif [[ $mk == on* ]]; then out_arm=${mk#on }; why="multi-hub $mk (select_output accept, largest TNS gain); $reason"
  else out_arm=off; why="multi-hub: no prefix accepted; $reason"; fi
  echo "OUTPUT $out_arm ($why)" >> "$T"
fi

# ---------------------------------------------------------------------------------------------- prune
# Unless CTS3D_KEEP_INTERMEDIATES=1 (run_cts.sh -k), removes the extraction partitions and graph CSVs, the probe-session
# databases, the per-stage checkpoints and the route-input copies.  OUTPUT/, out/, logs/, the decision files and the
# stage reports are kept.
prune_run() {
  local a
  for a in "$RUN"/arms/* "$RUN"/multi_hub/k*/arms/*; do
    [[ -d $a ]] || continue
    rm -rf "$a/G/parts" "$a"/*/session/results "$a"/*/session/objects "$a/Q/session/reports/edited.odb" \
      "$a/G/results/pre_cts_ff_timing_graph.csv" "$a/G/results/pre_cts_io_timing_edges.csv"
    find "$a" -type f \( -name '*.odb' -o -name '*.def' -o -name '*.v' \) -delete 2>/dev/null
    find "$a" -xtype l -delete 2>/dev/null
  done
  rm -rf "$RUN"/decide/*/probe/results "$RUN"/decide/*/probe/objects "$RUN"/decide/view/P
  find "$RUN"/route_prep "$RUN"/multi_hub/k*/route_prep -type f \( -name '*.odb' -o -name '*.def' -o -name '*.v' \) -delete 2>/dev/null
  find "$RUN"/route_prep "$RUN"/multi_hub -xtype l -delete 2>/dev/null
  echo "PRUNE kept=OUTPUT,out,logs,decide,reports size=$(du -sh "$RUN" | cut -f1)" >> "$T"
}

# ---------------------------------------------------------------------------------------------- output
case $out_arm in
  off) arm_dir=$RUN/arms/off; oplan="";;
  on)  arm_dir=$RUN/arms/on; oplan=$plan;;
  k=*) arm_dir=$RUN/multi_hub/k${out_arm#k=}/arms/on; oplan=$RUN/multi_hub/plan_k${out_arm#k=}.tsv;;
esac
O=$RUN/OUTPUT; mkdir -p "$O"
for f in 4_cts.odb 4_cts.def 4_cts.v 4_cts.sdc pre_cts_skew_targets.csv; do cp -L "$arm_dir/final/$f" "$O/$f"; done
echo "END case=$c end_to_end_wall_s=$(echo "$(date +%s.%N) - $T0" | bc) date=$(date -Is)" >> "$T"
"$NATIVE/cts_select" report "$RUN" "$c" "$out_arm" "$arm_dir" "$why" "${oplan:-}" > /dev/null || { echo "FAILED stage=REPORT" | tee -a "$T"; exit 1; }
[[ ${CTS3D_KEEP_INTERMEDIATES:-0} == 1 ]] || prune_run
rm -rf "$W/OUTPUT"; mv "$RUN/OUTPUT" "$W/OUTPUT"
# summary: timing of the output checkpoint (the table of every built arm and the selection are in work/out/) and the total time
say "RESULT      $(fmt_metrics "$arm_dir/final/metrics.csv")  (placement parasitics)"
say "            checkpoint $W/OUTPUT   total $(elapsed) (h:m:s), threads $THREADS, host $(hostname -s)"
