#!/usr/bin/env bash
# 3D CTS from the placed design to the selected CTS checkpoint, for one case or for all ten.
#
#   usage: ./run_cts.sh <case> [-p <period_ps>] [-w <run_dir>] [-k] [--early on|off]
#          ./run_cts.sh all [-j <lanes>]
#          ./run_cts.sh --list
#     <case>       a7a7_aes a7a7_jpeg a7a7_ibex a7a7_swerv a7a7_ariane a7n45_aes a7n45_jpeg a7n45_ibex a7n45_swerv a7n45_ariane
#     all          every case of flow/configs/cases.tsv at its default period, <lanes> cases at a time (default 1)
#     -p period    clock period in ps; the placement must exist as inputs/<case>/T<period>/ (default: flow/configs/cases.tsv)
#     -w run_dir   output directory (default: runs/<case> for the default period, runs/<case>_T<period> otherwise)
#     -k           keep the intermediate files of every stage (default: pruned after the output is written)
#     --early      on (default): plan an early-clock tree, build it next to the baseline tree and keep it only if an
#                  independent STA comparison accepts it; off: baseline tree only (shorter run)
#   env: THREADS (default 16) = thread budget of one case (multiplied by the lane count for "all").
#   output: <run_dir>/cts.log (run log) and <run_dir>/OUTPUT/4_cts.{odb,def,v,sdc} (CTS checkpoint for routing);
#           step logs and intermediate data in <run_dir>/work/
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$ROOT/flow/cts/common.sh"
if [[ ${1:-} == --list ]]; then   # cases, periods and the design-specific CTS settings
  for x in $(case_list); do case_info "$x"
    printf '%-14s %-20s %-15s T%-5s ps   no_insertion_delay=%s balancer_base_restore=%s balancer_full_traverse=%s\n' \
      "$x" "$PLATFORM" "$DESIGN" "$PERIOD_PS" "$NID" "$BAL_BASE" "$BAL_FULL"
  done; exit 0
fi
[[ $# -ge 1 ]] || { sed -n '4,14p' "$0"; exit 2; }
c=$1; shift; period=""; work=""; lanes=1; keep=""; early=on
while [[ $# -gt 0 ]]; do
  case $1 in -p) period=$2; shift 2;; -w) work=$2; shift 2;; -j) lanes=$2; shift 2;; -k) keep=1; shift;; --early) early=$2; shift 2;; *) echo "unknown option $1" >&2; exit 2;; esac
done
if [[ $c == all ]]; then
  mapfile -t cases < <(case_list); mkdir -p "$ROOT/runs"
  run_lane() { local i; for ((i = $1; i < ${#cases[@]}; i += lanes)); do "$ROOT/run_cts.sh" "${cases[i]}" --early "$early"; done; }
  for ((l = 0; l < lanes; l++)); do run_lane $l > "$ROOT/runs/run_all_lane$l.log" 2>&1 & done
  wait
  for x in "${cases[@]}"; do printf '%-14s %s\n' "$x" "$(grep 'RESULT' "$ROOT/runs/$x/cts.log" 2>/dev/null | tail -1)"; done
  exit 0
fi
case_info "$c" || exit 2
[[ -n $period ]] || period=$PERIOD_PS
src=$ROOT/inputs/$c/T$period
for f in 3_place.def 3_place.sdc 3_place.v; do
  [[ -s $src/$f ]] || { echo "missing placement $src/$f (available: $(ls "$ROOT/inputs/$c" | tr '\n' ' '))" >&2; exit 2; }
done
if [[ -z $work ]]; then
  if [[ $period == "$PERIOD_PS" ]]; then work=$ROOT/runs/$c; else work=$ROOT/runs/${c}_T$period; fi
fi
mkdir -p "$work/work"; work=$(cd "$work" && pwd)
[[ $early == on || $early == off ]] || { echo "--early takes on or off" >&2; exit 2; }
# one run log, <run_dir>/cts.log (also printed): every step with its time and the timing after it, then the summary
CTS3D_EARLY_CLOCK=$([[ $early == on ]] && echo 1 || echo 0) \
CTS3D_KEEP_INTERMEDIATES=${keep:-${CTS3D_KEEP_INTERMEDIATES:-0}} bash "$ROOT/flow/cts/cts_flow.sh" "$c" "$src" "$work" 2>&1 | tee "$work/cts.log"
rc=${PIPESTATUS[0]}
[[ $rc == 0 ]] || echo "FAILED rc=$rc (see $work/cts.log and $work/work/logs/)" | tee -a "$work/cts.log"
exit $rc
