#!/usr/bin/env bash
# Build the native helpers of the flow (flow/native/bin): cts_partitions (graph-merge step), cts_checks (input / LP
# target / guard checks, LP bounds) and cts_select (overlap check, plan check, ON/OFF selection, reports).
# cts_partitions must use the same libstdc++ hashing as the OpenROAD binary (gcc 12 on our side), because it
# reproduces the iteration order of the extractor's std::unordered_map.  Static libstdc++ so the tools run without
# environment modules.
#   usage: tools/build_helpers.sh [c++ compiler]   (default: g++ on PATH after setup_env.sh)
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
[[ -f $ROOT/setup_env.sh ]] && source "$ROOT/setup_env.sh"
CXX=${1:-${CXX:-g++}}
mkdir -p "$ROOT/flow/native/bin"
for t in partitions checks select; do
  "$CXX" -O2 -std=c++17 -static-libstdc++ -static-libgcc -o "$ROOT/flow/native/bin/cts_$t" "$ROOT/flow/native/$t.cpp"
done
echo "built flow/native/bin/{cts_partitions,cts_checks,cts_select} with $("$CXX" --version | head -1)"
