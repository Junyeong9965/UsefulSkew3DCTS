#!/usr/bin/env bash
# The adopted 3D CTS policy for one case, from the placed design to the selected CTS checkpoint.
#   usage: policy.sh <case> <placement_dir> <run_dir>
#
#   OFF chain   P -> G -> [GB] -> D -> [GA] -> R -> J -> Q -> F          (arms/off)
#   decision    clock-tree dump + clock-net dump of the OFF Phase-1 tree, then one OpenROAD session (early_decide.tcl):
#               scoped view, shift calibration (structures, in-session probe, fit), early-group selection; when no
#               tier has a valid model a second session (early_hub.tcl): single-root hub candidates (generate ->
#               in-session probe -> measure -> select, multi-hub prefixes).  The decision steps are cts::early_*
#               commands of the OpenROAD binary.
#   ON chain    only when the decision returned a plan: the same chain with the early-clock plan     (arms/on)
#   selection   route-input preparation of both arms (overlap check + legalization recovery only), independent STA
#               reload of both, plan check, cts_select output -> ON if accepted, else OFF
#   multi-hub   only after a hub decision: prefixes k = 2..3 of the compatible measured hub candidates are built as
#               ON chains (multi_hub/k<k>) and judged by the same selection rule against the OFF route input; the
#               accepted prefix with the largest setup + hold TNS gain replaces the output (k = 1 = the ON arm)
# Output: <run_dir>/OUTPUT/ (4_cts.{odb,def,v,sdc}, POLICY.txt, timing.txt, times.txt), <run_dir>/out/times.txt.
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

# st <name> <cmd...>: run and time one step; abort the run on failure
st() { local n=$1; shift
  /usr/bin/time -f "$n wall_s=%e user_s=%U sys_s=%S peak_kb=%M" -a -o "$T" "$@" >> "$RUN/logs/stages.log" 2>&1; local rc=$?
  echo "$n rc=$rc load_end=[$(cut -d' ' -f1-3 /proc/loadavg)]" >> "$T"
  [[ $rc == 0 ]] || { echo "FAILED stage=$n" | tee -a "$T"; exit 1; }; }
STAGE="bash $FLOW/stage.sh"
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
  st "PREP_$tag" bash "$FLOW/route_prep.sh" "$prep" "$dir/final" "$plat" "$des" "$src"
  st "NATIVE_$tag" bash "$FLOW/openroad_run.sh" "$prep/native" "$plat" "$des" "$prep/$sub/4_cts.odb" "$prep/$sub/4_cts.sdc" placement \
     "$FLOW/tcl/timing_metrics.tcl" 4
  cp "$prep/native/reports/metrics.csv" "$o/native_$tag.csv"; cp "$prep/native/reports/electrical.csv" "$o/native_elec_$tag.csv"; }

# ---------------------------------------------------------------------------------------------- OFF chain
chain off "$RUN/arms/off" "$RUN" P G GB D
nid_check off "$RUN"
[[ -e $RUN/arms/off/.guarded ]] && chain off "$RUN/arms/off" "$RUN" GA

# ---------------------------------------------------------------------------------------------- decision
DEC=$RUN/decide; mkdir -p "$DEC"
P1=$RUN/arms/off/P/$sub
setrc=$(platform_setrc "$plat")
st DEC_dump bash "$FLOW/openroad_run.sh" "$DEC/dump" "$plat" "$des" "$P1/phase1.odb" "$P1/phase1.sdc" placement "$FLOW/tcl/clock_tree_dump.tcl" 4
st DEC_nets bash "$FLOW/openroad_run.sh" "$DEC/nets" "$plat" "$des" "$P1/phase1.odb" "$P1/phase1.sdc" placement "$FLOW/tcl/clock_nets_dump.tcl" 4
# session A: scoped view, shift calibration (structures + in-session probe + fit), early groups (early_decide.tcl)
export EARLY_DEC=$DEC EARLY_REF_ARM=$RUN/arms/off EARLY_CASE=$c EARLY_SETRC=$setrc EARLY_RUN=$RUN
st DEC_decide bash "$FLOW/openroad_run.sh" "$DEC/session" "$plat" "$des" "$P1/phase1.odb" "$P1/phase1.sdc" placement "$FLOW/tcl/early_decide.tcl" 4
dget() { sed -n "s/^$1=//p" "$DEC/DECISION.txt" | tail -1; }
status=$(dget early_groups_status)
echo "DECISION early_groups_status=$status" >> "$T"
plan=""; reason=""; kind=""
if [[ $status == selected && $(tail -n +2 "$DEC/early_groups/plan.tsv" | grep -c .) -gt 0 ]]; then
  plan=$DEC/early_groups/plan.tsv; reason="early groups"; kind=groups
elif [[ $status == model_invalid ]]; then
  # session B: hub candidates (generate -> in-session probe -> measure -> select, multi-hub prefixes) (early_hub.tcl)
  H=$DEC/hub
  st DEC_hub bash "$FLOW/openroad_run.sh" "$H/session" "$plat" "$des" "$P1/phase1.odb" "$P1/phase1.sdc" placement "$FLOW/tcl/early_hub.tcl" 4
  cid=$(dget hub_cid)
  if [[ -n $cid && -s $H/plan/plan.tsv ]]; then plan=$H/plan/plan.tsv; reason="hub $cid"; kind=hub
  else reason="model_invalid; no valid hub candidate"; fi
else reason=$status
fi
echo "DECISION plan=${plan:-none} reason=$reason" >> "$T"
trim "$RUN/arms/off/P/$sub/phase1.odb"   # read by G, GB, D and the decision probes; nothing later

# ---------------------------------------------------------------------------------------------- ON chain
if [[ -n $plan ]]; then
  ( export EARLY_CLOCK_PLAN=$plan EARLY_CLOCK_LEGAL=1
    chain on "$RUN/arms/on" "$RUN" P G GB D; nid_check on "$RUN"; trim "$RUN/arms/on/P/$sub/phase1.odb"
    chain on "$RUN/arms/on" "$RUN" GA R J Q F ) || exit 1
fi
chain off "$RUN/arms/off" "$RUN" R J Q F

# ---------------------------------------------------------------------------------------------- selection
out_arm=off; why="no early structure: $reason"
if [[ -n $plan ]]; then
  prep_native "$RUN/arms/off" "$RUN/route_prep/off" "$RUN/out" off
  prep_native "$RUN/arms/on" "$RUN/route_prep/on" "$RUN/out" on
  st CHECK "$NATIVE/cts_select" plan "$c" "$RUN/route_prep/on/$sub/4_cts.def" "$RUN/route_prep/off/$sub/4_cts.def" "$plan" "$RUN/out/check_on.json"
  st SELECT "$NATIVE/cts_select" output "$c" "$RUN" "$RUN/route_prep/off" "$RUN/route_prep/on"
  d=$(jget "$RUN/out/select.json" decision)
  if [[ $d == accept ]]; then out_arm=on; fi
  why="select_output $d; $reason"
fi
echo "OUTPUT $out_arm ($why)" >> "$T"

# ---------------------------------------------------------------------------------------------- multi-hub prefixes
if [[ $kind == hub ]]; then
  MH=$RUN/multi_hub; mkdir -p "$MH"   # plan_k<k>.tsv and prefixes.json were written by session B
  res=("1 $RUN/out/select.json $RUN/arms/on")
  for p in "$MH"/plan_k*.tsv; do [[ -e $p ]] || continue
    k=$(basename "$p" .tsv | sed 's/plan_k//'); KR=$MH/k$k; mkdir -p "$KR/arms" "$KR/logs" "$KR/out"
    ( export EARLY_CLOCK_PLAN=$p EARLY_CLOCK_LEGAL=1 EARLY_HUB_ANCHOR_FALLBACK=1
      chain_k() { local s; mkdir -p "$KR/arms/on"; touch "$KR/arms/on/.start"
        for s in "$@"; do
          if [[ $s == GB || $s == GA ]] && [[ ! -e $KR/arms/on/.guarded ]]; then continue; fi
          /usr/bin/time -f "K${k}_on_$s wall_s=%e user_s=%U sys_s=%S peak_kb=%M" -a -o "$T" $STAGE "$s" "$KR/arms/on" "$plat" "$des" "$src" "$c" \
            >> "$KR/logs/stages.log" 2>&1 || { echo "K${k}_on_$s failed" >> "$T"; return 1; }
        done; }
      chain_k P G GB D || exit 1
      p1n=$(grep -c "CTS_NO_INSERTION_DELAY=1" "$KR/logs/on_P.log"); d1n=$(grep -c "CTS_NO_INSERTION_DELAY=1" "$KR/logs/on_D.log")
      echo "NID_CHECK arm=k$k P_lines=$p1n D_lines=$d1n" >> "$T"
      [[ ($p1n -gt 0 && $d1n -gt 0) || ($p1n == 0 && $d1n == 0) ]] || exit 1
      trim "$KR/arms/on/P/$sub/phase1.odb"
      chain_k GA R J Q F ) || { echo "MULTI k=$k build failed" >> "$T"; continue; }
    cp "$RUN/out/native_off.csv" "$RUN/out/native_elec_off.csv" "$KR/out/"
    # every step of the prefix arm is checked; a failure aborts the run (as in the OFF / ON arms)
    st "K${k}_PREP" bash "$FLOW/route_prep.sh" "$KR/route_prep/on" "$KR/arms/on/final" "$plat" "$des" "$src"
    st "K${k}_NATIVE" bash "$FLOW/openroad_run.sh" "$KR/route_prep/on/native" "$plat" "$des" "$KR/route_prep/on/$sub/4_cts.odb" "$KR/route_prep/on/$sub/4_cts.sdc" \
      placement "$FLOW/tcl/timing_metrics.tcl" 4
    cp "$KR/route_prep/on/native/reports/metrics.csv" "$KR/out/native_on.csv"
    cp "$KR/route_prep/on/native/reports/electrical.csv" "$KR/out/native_elec_on.csv"
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
# After the output is written, the intermediates of the run are removed unless CTS3D_KEEP_INTERMEDIATES=1
# (run_cts.sh -k): extraction partitions, probe-session databases, the per-stage checkpoints of the arms that were
# not selected, and the route-input copies.  OUTPUT/, out/, logs/, the decision files and every stage report stay.
prune_run() {
  local keep_arm a; keep_arm=$(readlink -f "$arm_dir")
  for a in "$RUN"/arms/* "$RUN"/multi_hub/k*/arms/*; do
    [[ -d $a ]] || continue
    rm -rf "$a/G/parts" "$a"/*/session/results "$a"/*/session/objects "$a/Q/session/reports/edited.odb"
    if [[ $(readlink -f "$a") == "$keep_arm" ]]; then
      find "$a/P" "$a/D" -type f \( -name '*.odb' -o -name '*.def' -o -name '*.v' \) -delete 2>/dev/null
      [[ -L $a/Q/$sub/4_cts.odb ]] || find "$a/R" -type f \( -name '*.odb' -o -name '*.def' -o -name '*.v' \) -delete 2>/dev/null
    else
      find "$a" -type f \( -name '*.odb' -o -name '*.def' -o -name '*.v' \) -delete 2>/dev/null
    fi
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
[[ -z $oplan ]] || cp "$oplan" "$O/early_clock_plan.tsv"
echo "END case=$c end_to_end_wall_s=$(echo "$(date +%s.%N) - $T0" | bc) date=$(date -Is)" >> "$T"
"$NATIVE/cts_select" report "$RUN" "$c" "$out_arm" "$arm_dir" "$why" "${oplan:-}" > /dev/null || { echo "FAILED stage=REPORT" | tee -a "$T"; exit 1; }
[[ ${CTS3D_KEEP_INTERMEDIATES:-0} == 1 ]] || prune_run
rm -rf "$W/OUTPUT"; mv "$RUN/OUTPUT" "$W/OUTPUT"
echo "$(date -Is) done $c: $(grep '^OUTPUT' "$T" | tail -1)"
