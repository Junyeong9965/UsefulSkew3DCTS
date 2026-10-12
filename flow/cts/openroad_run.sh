#!/usr/bin/env bash
# One OpenROAD session that runs a stage script on a saved database, in the flow-home environment of the case.
#   usage: openroad_run.sh <workdir> <platform> <design> <odb> <sdc> <script.tcl> <threads>
#   The script sees PROBE_INPUT_ODB / PROBE_INPUT_SDC (placement parasitics are estimated by the script), RESULTS_DIR / REPORTS_DIR of
#   <workdir> and every variable exported by the caller.  console.log, INPUTS.sha256 and TIME are written to <workdir>.
#   <workdir> is recreated unless OPENROAD_RUN_KEEP=1 (then only the subdirectories are created).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
work=$1; platform=$2; design=$3; odb=$4; sdc=$5; script=$6; th=$7
[[ ${OPENROAD_RUN_KEEP:-0} == 1 ]] || rm -rf "$work"; mkdir -p "$work/reports" "$work/results" "$work/logs" "$work/objects"
export FLOW_HOME=$FLOW_HOME_DIR WORK_HOME=$work PLATFORM=$platform DESIGN_NICKNAME=$design
export RESULTS_DIR=$work/results REPORTS_DIR=$work/reports LOG_DIR=$work/logs OBJECTS_DIR=$work/objects
export OPENROAD_SCRIPTS_DIR=$CTS_DIR/tcl OPENROAD_EXE=$CTS3D_OPENROAD NUM_CORES=$th
export HETEROGENEOUS_3D=$(hetero_of "$platform")
set +u; source "$FLOW_HOME_DIR/env.sh"; source "$ROOT/flow/configs/cts_params.env"; set -u
export PROBE_INPUT_ODB=$odb PROBE_INPUT_SDC=$sdc
config=designs/$platform/$design/config_cts.mk
{ echo "host=$(hostname -s) threads=$th date=$(date -Is)"; sha256sum "$CTS3D_OPENROAD" "$odb" "$sdc" "$script"; } > "$work/INPUTS.sha256"
cd "$FLOW_HOME_DIR"
/usr/bin/time -f "wall_s=%e peak_kb=%M" -o "$work/TIME" \
  make DESIGN_CONFIG="$config" OPENROAD_EXE="$CTS3D_OPENROAD" OPENROAD_SCRIPT="$script" openroad-script > "$work/console.log" 2>&1
