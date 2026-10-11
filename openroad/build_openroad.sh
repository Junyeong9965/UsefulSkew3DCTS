#!/usr/bin/env bash
# Build the OpenROAD binary of this flow: upstream OpenROAD at BASE_COMMIT + openroad_3dcts.patch.
#
#   usage: [JOBS=40] openroad/build_openroad.sh [source_dir]      (default source_dir: ./OpenROAD-3dcts)
#
# 1. clones upstream OpenROAD into source_dir (skipped when source_dir already exists), checks out BASE_COMMIT and its
#    submodules (OpenSTA, abc) and applies openroad_3dcts.patch (skipped when it is already applied);
# 2. configures and builds the openroad target into source_dir/build (Release, C++17);
# 3. prints the path of the binary; set CTS3D_OPENROAD in setup_env.sh to it.
#
# Dependencies are the upstream OpenROAD dependencies (OR-Tools, spdlog, Boost, yaml-cpp, Tcl, SWIG, Bison, Flex, lemon,
# CUDD; see the upstream DependencyInstaller).  When they are not on the default search paths, put their locations into
# openroad/deps.local.sh (not tracked; see deps.example.sh); this script sources it when it exists.
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
BASE_COMMIT=0609245cc439dfaa667571b5ca386a6a265c0146          # upstream OpenROAD master (January 2026)
UPSTREAM=${UPSTREAM:-https://github.com/The-OpenROAD-Project/OpenROAD.git}
SRC=$(realpath -m "${1:-OpenROAD-3dcts}")
JOBS=${JOBS:-40}
if [[ -f $HERE/deps.local.sh ]]; then source "$HERE/deps.local.sh"; fi

# ---- source: upstream base commit + patch
if [[ ! -d $SRC ]]; then
  git clone "$UPSTREAM" "$SRC"
  git -C "$SRC" checkout -q "$BASE_COMMIT"
  git -C "$SRC" submodule update --init --recursive
fi
[[ $(git -C "$SRC" rev-parse HEAD) == "$BASE_COMMIT" ]] || { echo "error: $SRC is not at $BASE_COMMIT" >&2; exit 1; }
if git -C "$SRC" apply --check "$HERE/openroad_3dcts.patch" 2>/dev/null; then
  git -C "$SRC" apply "$HERE/openroad_3dcts.patch"
elif git -C "$SRC" apply --reverse --check "$HERE/openroad_3dcts.patch" 2>/dev/null; then
  echo "openroad_3dcts.patch already applied"
else
  echo "error: openroad_3dcts.patch does not apply to $SRC" >&2; exit 1
fi

# ---- configure (optional dependency locations from deps.local.sh)
cfg=(-DCMAKE_BUILD_TYPE=Release -DCMAKE_CXX_STANDARD=17 -DBUILD_GUI=${BUILD_GUI:-ON} -DENABLE_TESTS=OFF)
if [[ -n ${CMAKE_PREFIX_PATH:-} ]]; then cfg+=(-DCMAKE_PREFIX_PATH="$CMAKE_PREFIX_PATH"); fi
for v in CMAKE_C_COMPILER CMAKE_CXX_COMPILER BISON_EXECUTABLE FLEX_EXECUTABLE FLEX_INCLUDE_DIR LEMON_DIR \
         LEMON_INCLUDE_DIR LEMON_LIBRARY SWIG_EXECUTABLE CUDD_HEADER CUDD_LIB spdlog_DIR Boost_DIR TCL_LIBRARY TCL_HEADER; do
  if [[ -n ${!v:-} ]]; then cfg+=(-D$v="${!v}"); fi
done
cmake -S "$SRC" -B "$SRC/build" "${cfg[@]}"
cmake --build "$SRC/build" -j"$JOBS" --target openroad

# ---- link fix for prebuilt OR-Tools: the configure lists every absl library of the OR-Tools package explicitly on the
#      openroad link line; libortools.so already carries absl, and the duplicate static copies abort at start-up (absl
#      ODR check).  Drop the explicit absl entries and relink once; RPATH_DIRS (deps.local.sh) are added as run paths so
#      that the binary finds OR-Tools / spdlog without LD_LIBRARY_PATH.
LT=$SRC/build/src/CMakeFiles/openroad.dir/link.txt
if grep -qE 'libabsl[a-z0-9_]*\.(a|so)' "$LT"; then
  sed -i -E 's#[^ ]*libabsl[a-z0-9_]*\.a##g; s#[^ ]*libabsl[a-z0-9_]*\.so[.0-9]*##g; s#-labsl[a-z0-9_]*##g' "$LT"
  for d in ${RPATH_DIRS:-}; do grep -q -- "-rpath,$d " "$LT" || sed -i "s#-rdynamic #-rdynamic -Wl,-rpath,$d #" "$LT"; done
  ( cd "$SRC/build/src" && eval "$(cat CMakeFiles/openroad.dir/link.txt)" )
fi
echo "binary: $SRC/build/bin/openroad"
