#!/usr/bin/env bash
# One CTS session (cts_3d.tcl through `make ord-cts-3d`) of stage P or D.
#   usage: cts_session.sh <arm_stage_root> <platform> <design> <placement_dir> <phase1|delivery> <threads>
#   Links 3_place.{def,sdc,v} into <root>/results/<platform>/<design>/openroad (the stage inputs that the caller
#   linked there stay), exports the session environment and runs the session.  Every variable exported by the
#   caller (case recipe, EARLY_CLOCK_PLAN, ...) reaches the session.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
root=$1; platform=$2; design=$3; src=$4; stage=$5; th=$6
results=$root/results/$platform/$design/openroad
mkdir -p "$results" "$root/logs/$platform/$design/openroad" "$root/reports/$platform/$design/openroad" \
  "$root/objects/$platform/$design/openroad"
for f in 3_place.def 3_place.sdc 3_place.v; do ln -sfn "$(readlink -f "$src/$f")" "$results/$f"; done
rm -f "$results"/4_*
export FLOW_HOME=$FLOW_HOME_DIR WORK_HOME=$root PLATFORM=$platform DESIGN_NICKNAME=$design RESULTS_DIR=$results
export LOG_DIR=$root/logs/$platform/$design/openroad REPORTS_DIR=$root/reports/$platform/$design/openroad
export OBJECTS_DIR=$root/objects/$platform/$design/openroad OPENROAD_SCRIPTS_DIR=$CTS_DIR/tcl
export OPENROAD_EXE=$CTS3D_OPENROAD NUM_CORES=$th CTS_STAGE=$stage
export HETEROGENEOUS_3D=$(hetero_of "$platform")
set +u; source "$FLOW_HOME_DIR/env.sh"; source "$ROOT/flow/configs/cts_params.env"; set -u
{
  echo "stage=$stage platform=$platform design=$design date=$(date -Is) source=$src"
  env | grep -E '^(CTS_|EXTRACT_|EARLY_CLOCK|HETEROGENEOUS_3D)' | sort
  echo "openroad=$OPENROAD_EXE"
  sha256sum "$OPENROAD_EXE" "$OPENROAD_SCRIPTS_DIR/cts_3d.tcl"
} > "$root/run_manifest_${platform}_${design}.txt"
# delivery: the stage-G graph, the Phase-1 reference and the LP bounds must belong to this chain
if [[ $stage == delivery ]]; then
  if [[ -n ${CTS_STA_GUARD_MANIFEST:-} ]]; then "$NATIVE/cts_checks" guarded-inputs "$results"
  else "$NATIVE/cts_checks" inputs "$results"; fi
fi
cd "$FLOW_HOME_DIR"
exec nice -n 19 make DESIGN_CONFIG="designs/$platform/$design/config_cts.mk" ord-cts-3d
