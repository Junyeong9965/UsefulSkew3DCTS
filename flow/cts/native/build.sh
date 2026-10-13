#!/usr/bin/env bash
# Build the native helpers of the flow (flow/cts/native/bin): cts_partitions (graph-merge step), cts_checks (input / LP
# target / guard checks, LP bounds) and cts_select (overlap check, plan check, ON/OFF selection, reports).
# cts_partitions must use the same libstdc++ hashing as the OpenROAD binary (gcc 12), because it
# reproduces the iteration order of the extractor's std::unordered_map.  The tools link libstdc++ statically.
#   usage: flow/cts/native/build.sh [c++ compiler]
#   default compiler: $CXX, else CMAKE_CXX_COMPILER of setup_env.sh (the OpenROAD compiler), else g++
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
[[ -f $ROOT/setup_env.sh ]] && source "$ROOT/setup_env.sh"
CXX=${1:-${CXX:-${CMAKE_CXX_COMPILER:-g++}}}
# warn if the compiler version differs from the newest GCC version recorded in the OpenROAD binary
if [[ -n ${CTS3D_OPENROAD:-} && -f $CTS3D_OPENROAD ]] && command -v readelf > /dev/null; then
  ref=$(readelf -p .comment "$CTS3D_OPENROAD" 2> /dev/null | grep -o 'GCC: ([^)]*) [0-9.]*' | awk '{print $NF}' | sort -V | tail -1)
  cur=$("$CXX" -dumpfullversion -dumpversion 2> /dev/null | head -1)
  [[ -z $ref || $ref == "$cur" ]] || echo "warning: $CXX is GCC $cur; the OpenROAD binary was built with GCC $ref" >&2
fi
mkdir -p "$ROOT/flow/cts/native/bin"
for t in partitions checks select; do
  "$CXX" -O2 -std=c++17 -static-libstdc++ -static-libgcc -o "$ROOT/flow/cts/native/bin/cts_$t" "$ROOT/flow/cts/native/$t.cpp"
done
echo "built flow/cts/native/bin/{cts_partitions,cts_checks,cts_select} with $("$CXX" --version | head -1)"
