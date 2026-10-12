#!/usr/bin/env bash
# Route-input preparation of one arm (no routing): same-tier overlap check of the final CTS checkpoint and, only if it
# has real overlaps, minimum-displacement legalization (tcl/legalize_recover.tcl); overlap check of the result
# (flow/cts/native cts_select overlap).
#   usage: route_prep.sh <out_dir> <checkpoint_dir> <platform> <design> <placement_dir>
#   out: <out_dir>/results/<platform>/<design>/openroad/4_cts.{odb,def,v,sdc}, <out_dir>/overlap_*_summary.json,
#        <out_dir>/GATE_L.txt
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
out=$1; ck=$(readlink -f "$2"); platform=$3; design=$4; src=$5
L=$out/results/$platform/$design/openroad
rm -rf "$out"; mkdir -p "$L" "$out/logs"
grid=""; [[ $platform == asap7_nangate45_3D ]] && grid="--ng45-grid 190,1400,0,0"
lef=$FLOW_HOME_DIR/platforms/$platform
"$NATIVE/cts_select" overlap --def "$ck/4_cts.def" --lefdir "$lef" --ref "$src/3_place.def" $grid --out "$out/overlap_in" > "$out/logs/overlap_in.log" 2>&1
nreal=$(jget "$out/overlap_in_summary.json" overlaps_real) || exit 1
[[ -n $nreal ]] || { echo "overlap check of the input produced no count"; exit 1; }
cp -L "$ck/4_cts.sdc" "$L/4_cts.sdc"; cp -L "$ck/pre_cts_skew_targets.csv" "$L/" 2>/dev/null || true
if [[ $nreal -gt 0 ]]; then
  awk '/^COMPONENTS/{f=1;next} /^END COMPONENTS/{exit} f && $1=="-"{print $2}' "$src/3_place.def" > "$out/pre_cts_names.txt"
  HETEROGENEOUS_3D=$(hetero_of "$platform") REC_ODB=$ck/4_cts.odb REC_PRE=$out/pre_cts_names.txt REC_OUT=$L \
    "$CTS3D_OPENROAD" -no_init -threads 4 -exit "$CTS_DIR/tcl/legalize_recover.tcl" > "$out/logs/legalize_recover.log" 2>&1 || { echo "legalization recovery failed"; exit 1; }
  echo "legalized (input had $nreal real overlaps)" > "$out/GATE_L.txt"
else
  for f in 4_cts.odb 4_cts.def 4_cts.v; do ln -sfn "$(readlink -f "$ck/$f")" "$L/$f"; done
  echo "pass-through (input had $nreal real overlaps)" > "$out/GATE_L.txt"
fi
"$NATIVE/cts_select" overlap --def "$L/4_cts.def" --lefdir "$lef" --ref "$src/3_place.def" $grid --out "$out/overlap_4cts" > "$out/logs/overlap_4cts.log" 2>&1
