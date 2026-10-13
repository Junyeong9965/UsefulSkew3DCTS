#!/usr/bin/env bash
# Routing, parasitic extraction and final STA of the CTS checkpoint, for one case or for all ten.
#
#   usage: ./run_route.sh <case> [-w <run_dir>]
#          ./run_route.sh all [-j <lanes>]
#     <case>     one of the cases of flow/configs/cases.tsv; its CTS result is <run_dir>/results/4_cts.{def,sdc,v}
#                (written by ./run_cts.sh <case>; default run_dir: runs/<case>)
#     all        every case whose checkpoint exists, <lanes> cases at a time (default 1)
#   env: THREADS (default 16); DETAILED_ROUTE_END_ITERATION overrides the detailed-routing iteration count of the
#        design configuration (10) for quick checks.  ariane133 is routed with Cadence Innovus (INNOVUS_EXE in setup_env.sh); the other
#        designs with OpenROAD.  Extraction (OpenRCX) and the final timing report always run in OpenROAD.
#   output: <run_dir>/results/{5_route,6_final}.*, <run_dir>/reports/6_finish.rpt (summary printed at the end) and the
#           step logs in <run_dir>/logs/
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$ROOT/flow/cts/common.sh"
[[ $# -ge 1 ]] || { sed -n '4,13p' "$0"; exit 2; }
c=$1; shift; work=""; lanes=1
while [[ $# -gt 0 ]]; do
  case $1 in -w) work=$2; shift 2;; -j) lanes=$2; shift 2;; *) echo "unknown option $1" >&2; exit 2;; esac
done
if [[ $c == all ]]; then
  mapfile -t cases < <(case_list); mkdir -p "$ROOT/runs"
  run_lane() { local i; for ((i = $1; i < ${#cases[@]}; i += lanes)); do "$ROOT/run_route.sh" "${cases[i]}"; done; }
  for ((l = 0; l < lanes; l++)); do run_lane $l > "$ROOT/runs/run_route_lane$l.log" 2>&1 & done
  wait
  for x in "${cases[@]}"; do r=$ROOT/runs/$x/reports/6_finish.rpt
    if [[ -s $r ]]; then printf '%-14s %s\n' "$x" "$(awk '/^finish report_tns/,/^finish hold timing/' "$r" | grep -E '^(tns|wns)' | head -4 | tr '\n' ' ')"
    else printf '%-14s %s\n' "$x" "no route result"; fi; done
  exit 0
fi
case_info "$c" || exit 2
[[ -n $work ]] || work=$ROOT/runs/$c
work=$(cd "$work" 2>/dev/null && pwd) || { echo "no run directory for $c (run ./run_cts.sh $c first)" >&2; exit 2; }
ckpt=$work/results
for f in 4_cts.def 4_cts.sdc 4_cts.v; do
  [[ -s $ckpt/$f ]] || { echo "missing $ckpt/$f (run ./run_cts.sh $c first)" >&2; exit 2; }
done
set +u; source "$FLOW_HOME_DIR/env.sh"; source "$ROOT/flow/configs/cts_params.env"; set -u
export OPENROAD_EXE=$CTS3D_OPENROAD NUM_CORES=${THREADS:-16} FLOW_VARIANT=openroad
exec 9< "$work"; flock -n 9 || { echo "$work is in use by another run" >&2; exit 2; }
# the route runs in <run_dir>/tmp/route (deleted after a successful run); the 5_*/6_* files are then moved to
# <run_dir>/{results,reports,logs}
R=$work/tmp/route; res=$R/results/$PLATFORM/$DESIGN/openroad; rep=$R/reports/$PLATFORM/$DESIGN/openroad
rm -rf "$R"; rm -f "$work"/results/[56]_* "$work"/results/route.guide "$work"/results/updated_clks.sdc "$work"/reports/[56]_* "$work"/reports/final_* "$work"/reports/drt_* "$work"/logs/[56]_* "$work"/logs/cadence_*
mkdir -p "$res" "$rep" "$R/logs/$PLATFORM/$DESIGN/openroad" "$R/objects/$PLATFORM/$DESIGN/openroad"
cp "$ckpt"/4_cts.def "$ckpt"/4_cts.sdc "$ckpt"/4_cts.v "$res/"
cfg=designs/$PLATFORM/$DESIGN/config.mk
mk() { make -C "$FLOW_HOME_DIR" --no-print-directory DESIGN_CONFIG=$cfg WORK_HOME="$R" \
         ${DETAILED_ROUTE_END_ITERATION:+DETAILED_ROUTE_END_ITERATION=$DETAILED_ROUTE_END_ITERATION} "$@"; }
fail() { echo "FAILED $1 (logs kept in $R/logs)"; exit 1; }
echo "case=$c platform=$PLATFORM design=$DESIGN checkpoint=$ckpt threads=$NUM_CORES"
if [[ $DESIGN == ariane133 ]]; then
  : "${INNOVUS_EXE:?INNOVUS_EXE is not set (setup_env.sh): ariane133 is routed with Cadence Innovus}"
  [[ -x $INNOVUS_EXE ]] || { echo "INNOVUS_EXE=$INNOVUS_EXE is not executable" >&2; exit 2; }
  echo "router=innovus ($INNOVUS_EXE)"
  mk cds-route   || fail cds-route
else
  echo "router=openroad"
  mk ord-route || fail ord-route
fi
mk ord-final || fail ord-final
[[ -s $rep/6_finish.rpt ]] || fail "ord-final: 6_finish.rpt was not written"
log=$R/logs/$PLATFORM/$DESIGN/openroad
mv_out() { local f; for f in "$1"/*; do [[ -e $f && ${f##*/} != 4_cts.* ]] || continue; cp -rL "$f" "$2/" && rm -rf "$f"; done; }
mv_out "$res" "$work/results"; mv_out "$rep" "$work/reports"; mv_out "$log" "$work/logs"
rm -rf "$R"; rmdir "$work/tmp" 2>/dev/null
rpt=$work/reports/6_finish.rpt; log=$work/logs
{ echo "report: $rpt"
  awk '/^finish report_tns/,/^finish hold timing/' "$rpt" | grep -E '^(tns|wns)' | head -4
  grep -E '^Design area' "$log/6_report.log" | head -1
  if [[ $DESIGN == ariane133 ]]; then grep -E '^#Total wire length = ' "$log/cadence_innovus_3d_route.log" | tail -1 | sed 's/^#//'
  else grep -E '^Total wire length = ' "$log/5_2_route.log" | tail -1; grep -E 'Number of violations' "$log/5_2_route.log" | tail -1 | sed 's/.*\] *//'; fi
  awk '/^finish report_power/,/^$/' "$rpt" | grep -E '^Total' | head -1 | sed 's/^Total/power (internal switching leakage total, W)/'
}
exit 0
