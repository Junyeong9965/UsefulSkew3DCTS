#!/usr/bin/env bash
# Build the OpenROAD binary of this flow: upstream OpenROAD at BASE_COMMIT + openroad_3dcts.patch.
#
#   usage: [JOBS=40] openroad/build_openroad.sh [source_dir]      (default source_dir: ./OpenROAD-3dcts)
#
# 1. clones upstream OpenROAD into source_dir (skipped when source_dir already exists), checks out BASE_COMMIT and its
#    submodules (OpenSTA, abc) and applies openroad_3dcts.patch (skipped when it is already applied);
# 2. configures and builds the openroad target into source_dir/build (Release; C++20, set by the upstream CMakeLists);
# 3. prints the path of the binary; set CTS3D_OPENROAD in setup_env.sh to it.
#
# Dependencies are the upstream OpenROAD dependencies (OR-Tools, spdlog, Boost, yaml-cpp, Tcl, SWIG, Bison, Flex, lemon,
# CUDD; see the upstream DependencyInstaller).  The dependency locations that the upstream installer records in
# source_dir/etc/openroad_deps_prefixes.txt are passed to CMake.  This script sources setup_env.sh when it exists; for
# dependencies outside the default search paths, set there (only as needed):
#   CMAKE_PREFIX_PATH, CMAKE_C_COMPILER, CMAKE_CXX_COMPILER      install prefixes and compiler
#   BISON_EXECUTABLE FLEX_EXECUTABLE FLEX_INCLUDE_DIR SWIG_EXECUTABLE LEMON_DIR LEMON_INCLUDE_DIR LEMON_LIBRARY
#   CUDD_HEADER CUDD_LIB spdlog_DIR Boost_DIR TCL_LIBRARY TCL_HEADER   individual CMake locations
#   RPATH_DIRS                                                   extra run-path directories of the binary
# Compiler and library search variables (CPLUS_INCLUDE_PATH, LIBRARY_PATH, LD_LIBRARY_PATH) are used as exported.
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
BASE_COMMIT=0609245cc439dfaa667571b5ca386a6a265c0146          # upstream OpenROAD master (January 2026)
UPSTREAM=${UPSTREAM:-https://github.com/The-OpenROAD-Project/OpenROAD.git}
SRC=$(realpath -m "${1:-OpenROAD-3dcts}")
JOBS=${JOBS:-40}
if [[ -f $HERE/../setup_env.sh ]]; then source "$HERE/../setup_env.sh"; fi

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

# ---- configure (optional dependency locations from setup_env.sh)
# A Tcl environment module sets TCL_LIBRARY to the directory of the Tcl library; CMake needs the library file and header.
if [[ -d ${TCL_LIBRARY:-} ]]; then
  tcl_dir=${TCL_LIBRARY%/}
  tcl_so=$(ls "$tcl_dir"/libtcl8*.so "$tcl_dir"/libtcl.so 2>/dev/null | head -1 || true)
  [[ -n $tcl_so ]] && TCL_LIBRARY=$tcl_so || unset TCL_LIBRARY
  [[ -n ${TCL_HEADER:-} || ! -f $tcl_dir/../include/tcl.h ]] || TCL_HEADER=$(realpath "$tcl_dir/../include/tcl.h")
fi
cfg=(-DCMAKE_BUILD_TYPE=Release -DBUILD_GUI=${BUILD_GUI:-ON} -DENABLE_TESTS=OFF)
# package roots recorded by the upstream installer (-D <pkg>_ROOT=<dir> ...); setup_env.sh settings follow and take effect
deps=$SRC/etc/openroad_deps_prefixes.txt
if [[ -s $deps ]]; then read -r -d '' -a roots < "$deps" || true; cfg+=(${roots[@]+"${roots[@]}"}); echo "dependency locations: $deps"; fi
if [[ -n ${CMAKE_PREFIX_PATH:-} ]]; then cfg+=(-DCMAKE_PREFIX_PATH="$CMAKE_PREFIX_PATH"); fi
for v in CMAKE_C_COMPILER CMAKE_CXX_COMPILER BISON_EXECUTABLE FLEX_EXECUTABLE FLEX_INCLUDE_DIR LEMON_DIR \
         LEMON_INCLUDE_DIR LEMON_LIBRARY SWIG_EXECUTABLE CUDD_HEADER CUDD_LIB spdlog_DIR Boost_DIR TCL_LIBRARY TCL_HEADER; do
  if [[ -n ${!v:-} ]]; then cfg+=(-D$v="${!v}"); fi
done
cmake -S "$SRC" -B "$SRC/build" "${cfg[@]}"
cmake --build "$SRC/build" -j"$JOBS" --target openroad

# ---- link fix-ups, then one relink when anything changed
#   (1) prebuilt OR-Tools: libortools.so contains absl, so the explicit absl libraries on the openroad link line are
#       removed (duplicate copies fail the absl ODR check at start-up);
#   (2) run paths: the directory of every shared library the binary resolves on this server outside the system
#       directories (ldd in the build environment, plus TCL_LIBRARY of the CMake cache and RPATH_DIRS of
#       setup_env.sh) is recorded in the binary, so it runs without LD_LIBRARY_PATH on the server where it was built.
BIN=$SRC/build/bin/openroad
LT=$SRC/build/src/CMakeFiles/openroad.dir/link.txt
before=$(cksum < "$LT")
sed -i -E 's#[^ ]*libabsl[a-z0-9_]*\.a##g; s#[^ ]*libabsl[a-z0-9_]*\.so[.0-9]*##g; s#-labsl[a-z0-9_]*##g' "$LT"
#   The run paths are searched in this order: the C++ runtime of the compiler, RPATH_DIRS, TCL_LIBRARY, then the
#   directories ldd reports (so an older libstdc++ on LD_LIBRARY_PATH at build time is not taken first).
dirs=()
add_dir() { case $1 in ''|.|/lib|/lib64|/usr/lib|/usr/lib64) return;; esac; [[ " ${dirs[*]} " == *" $1 "* ]] || dirs+=("$1"); }
cxx=$(sed -n 's/^CMAKE_CXX_COMPILER:[A-Z]*=//p' "$SRC/build/CMakeCache.txt")
stdcxx=$("${cxx:-c++}" -print-file-name=libstdc++.so 2>/dev/null || true)
[[ $stdcxx == /* ]] && add_dir "$(dirname "$(realpath "$stdcxx")")"
for d in ${RPATH_DIRS:-}; do add_dir "$d"; done
tcl=$(sed -n 's/^TCL_LIBRARY:[A-Z]*=//p' "$SRC/build/CMakeCache.txt")
[[ $tcl == *.so* ]] && add_dir "$(dirname "$tcl")"
while read -r lib; do add_dir "$(dirname "$lib")"; done < <(ldd "$BIN" 2>/dev/null | sed -n 's#^.* => \(/[^ ]*\) .*#\1#p')
rp=""; for d in "${dirs[@]}"; do rp+="-Wl,-rpath,$d "; done
sed -i -E 's#-Wl,-rpath,[^ ]* ##g' "$LT"
sed -i "s#-rdynamic #-rdynamic $rp#" "$LT"
if [[ $(cksum < "$LT") != "$before" ]]; then ( cd "$SRC/build/src" && eval "$(cat CMakeFiles/openroad.dir/link.txt)" ); fi
"$BIN" -version > /dev/null 2>&1 || { echo "error: $BIN does not start; check the libraries it resolves (ldd $BIN)" >&2; exit 1; }
missing=$(env -u LD_LIBRARY_PATH ldd "$BIN" 2>/dev/null | sed -n 's/^[[:space:]]*\([^ ]*\) => not found.*/\1/p' | tr '\n' ' ')
[[ -z $missing ]] || echo "warning: not found without LD_LIBRARY_PATH: $missing(add their directories to LD_LIBRARY_PATH in setup_env.sh)" >&2
echo "binary: $BIN"
