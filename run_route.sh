#!/usr/bin/env bash
# Routing, parasitic extraction and final STA of the CTS checkpoint, for one case or for all ten.
#
#   usage: ./run_route.sh <case> [-w <run_dir>]
#          ./run_route.sh all [-j <lanes>]
#     <case>     one of the cases of flow/configs/cases.tsv; its checkpoint is <run_dir>/OUTPUT/4_cts.{def,sdc,v}
#                (written by ./run_cts.sh <case>; default run_dir: runs/<case>)
#     all        every case whose checkpoint exists, <lanes> cases at a time (default 1)
#   env: THREADS (default 16); DETAILED_ROUTE_END_ITERATION overrides the detailed-routing iteration count of the
#        design configuration (10) for quick checks.  ariane133 is routed with Cadence Innovus (INNOVUS_EXE in setup_env.sh); the other
#        designs with OpenROAD.  Extraction (OpenRCX) and the final timing report always run in OpenROAD.
#   output: <run_dir>/route/results/<platform>/<design>/openroad/{5_route,6_final}.*  and
#           <run_dir>/route/reports/<platform>/<design>/openroad/6_finish.rpt (summary printed at the end)
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
  for x in "${cases[@]}"; do printf '%-14s %s\n' "$x" "$(grep -E '^(tns|wns|FAILED)' "$ROOT/runs/$x/route_summary.txt" 2>/dev/null | tr '\n' ' ')"; done
  exit 0
fi
case_info "$c" || exit 2
[[ -n $work ]] || work=$ROOT/runs/$c
work=$(cd "$work" 2>/dev/null && pwd) || { echo "no run directory for $c (run ./run_cts.sh $c first)" >&2; exit 2; }
ckpt=$work/OUTPUT
for f in 4_cts.def 4_cts.sdc 4_cts.v; do
  [[ -s $ckpt/$f ]] || { echo "missing $ckpt/$f (run ./run_cts.sh $c first)" >&2; exit 2; }
done
set +u; source "$FLOW_HOME_DIR/env.sh"; source "$ROOT/flow/configs/cts_params.env"; set -u
export OPENROAD_EXE=$CTS3D_OPENROAD NUM_CORES=${THREADS:-16} FLOW_VARIANT=openroad
R=$work/route; res=$R/results/$PLATFORM/$DESIGN/openroad; rep=$R/reports/$PLATFORM/$DESIGN/openroad; sum=$work/route_summary.txt
rm -rf "$R" "$sum"; mkdir -p "$res" "$rep" "$R/logs/$PLATFORM/$DESIGN/openroad" "$R/objects/$PLATFORM/$DESIGN/openroad"
cp "$ckpt"/4_cts.def "$ckpt"/4_cts.sdc "$ckpt"/4_cts.v "$res/"
cfg=designs/$PLATFORM/$DESIGN/config.mk
mk() { make -C "$FLOW_HOME_DIR" --no-print-directory DESIGN_CONFIG=$cfg WORK_HOME="$R" \
         ${DETAILED_ROUTE_END_ITERATION:+DETAILED_ROUTE_END_ITERATION=$DETAILED_ROUTE_END_ITERATION} "$@"; }
fail() { echo "FAILED $1 (see $R/logs)" | tee "$sum"; exit 1; }
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
rpt=$rep/6_finish.rpt
[[ -s $rpt ]] || fail "ord-final: $rpt was not written"
log=$R/logs/$PLATFORM/$DESIGN/openroad
{ echo "report: $rpt"
  awk '/^finish report_tns/,/^finish hold timing/' "$rpt" | grep -E '^(tns|wns)' | head -4
  grep -E '^Design area' "$log/6_report.log" | head -1
  if [[ $DESIGN == ariane133 ]]; then grep -E '^#Total wire length = ' "$log/cadence_innovus_3d_route.log" | tail -1 | sed 's/^#//'
  else grep -E '^Total wire length = ' "$log/5_2_route.log" | tail -1; grep -E 'Number of violations' "$log/5_2_route.log" | tail -1 | sed 's/.*\] *//'; fi
  awk '/^finish report_power/,/^$/' "$rpt" | grep -E '^Total' | head -1 | sed 's/^Total/power (internal switching leakage total, W)/'
} | tee "$sum"
exit 0
