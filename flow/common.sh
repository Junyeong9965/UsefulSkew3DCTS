# Shared shell prologue of the flow scripts (sourced).
#   in : nothing (locates the repository from this file)
#   out: ROOT, FLOW, FLOW_HOME_DIR, case helpers; setup_env.sh sourced (CTS3D_OPENROAD)
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
FLOW=$ROOT/flow
FLOW_HOME_DIR=$ROOT/orfs
if [[ -z ${CTS3D_SETUP_DONE:-} ]]; then
  [[ -f $ROOT/setup_env.sh ]] || { echo "missing $ROOT/setup_env.sh (cp setup_env.example.sh setup_env.sh)" >&2; exit 2; }
  # shellcheck disable=SC1091
  source "$ROOT/setup_env.sh"
  export CTS3D_SETUP_DONE=1
fi
: "${CTS3D_OPENROAD:?CTS3D_OPENROAD is not set (setup_env.sh)}"
export CTS3D_OPENROAD CTS3D_FLOW_DIR=$FLOW
# native helpers (tools/build_helpers.sh): graph merge, checks, selection
NATIVE=$FLOW/native/bin
for t in cts_partitions cts_checks cts_select; do
  [[ -x $NATIVE/$t ]] || { echo "missing $NATIVE/$t (run tools/build_helpers.sh)" >&2; exit 2; }
done
# jget <file.json> <key>: top-level value of a JSON file
jget() { "$NATIVE/cts_select" jget "$1" "$2"; }

# case_info <case>: PLATFORM DESIGN PERIOD_PS from configs/cases.tsv, and the design-specific CTS settings
# NID BAL_BASE BAL_FULL (0/1) from orfs/designs/<platform>/<design>/config_bottom_cover.mk
case_info() {
  local line
  line=$(awk -F'\t' -v c="$1" '$1 == c {print; exit}' "$ROOT/configs/cases.tsv")
  [[ -n $line ]] || { echo "unknown case $1 (configs/cases.tsv)" >&2; return 1; }
  IFS=$'\t' read -r _ PLATFORM DESIGN PERIOD_PS <<< "$line"
  NID=$(design_setting DESIGN_CTS_NO_INSERTION_DELAY); BAL_BASE=$(design_setting DESIGN_CTS_BALANCER_BASE_RESTORE)
  BAL_FULL=$(design_setting DESIGN_CTS_BALANCER_FULL_TRAVERSE)
}
# design_setting <make variable>: its value in the design configuration (empty -> 0); needs PLATFORM and DESIGN
design_setting() {
  local v
  v=$(make -s -C "$FLOW_HOME_DIR" DESIGN_CONFIG="designs/$PLATFORM/$DESIGN/config_bottom_cover.mk" "print-$1" 2>/dev/null | tail -1)
  echo "${v:-0}"
}
case_list() { awk -F'\t' '!/^#/ && NF {print $1}' "$ROOT/configs/cases.tsv"; }
# platform files read outside the make environment
platform_setrc() { case $1 in asap7_3D) echo "$FLOW_HOME_DIR/platforms/asap7_3D/setRC_2A6M7M.tcl";;
                               asap7_nangate45_3D) echo "$FLOW_HOME_DIR/platforms/asap7_nangate45_3D/setRC_2A6M10M.tcl";; esac; }
hetero_of() { [[ $1 == asap7_nangate45_3D ]] && echo 1 || echo 0; }
unset CLK_PERIOD   # the placed SDC would take the clock period from it
