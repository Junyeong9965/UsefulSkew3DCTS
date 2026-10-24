#!/usr/bin/env bash
# Site configuration of the 3D CTS flow.  Copy to setup_env.sh and edit (setup_env.sh is not tracked by git):
#   cp setup_env.example.sh setup_env.sh
# openroad/build_openroad.sh, flow/cts/native/build.sh, run_cts.sh and run_route.sh read this file.

# OpenROAD binary with the 3D CTS changes (path printed by openroad/build_openroad.sh); every stage uses this one binary
export CTS3D_OPENROAD=/path/to/OpenROAD-3dcts/build/bin/openroad

# thread budget of one case (graph extraction runs THREADS processes x 1 thread)
export THREADS=${THREADS:-16}

# Cadence Innovus (routing of ariane133 only; ./run_route.sh of the other designs needs no Cadence tool).
# Used from PATH when INNOVUS_EXE is not set.
# export INNOVUS_EXE=/path/to/innovus

# OpenROAD dependencies outside the default search paths (used by openroad/build_openroad.sh).
# With environment modules, load them here, for example:
# module load gcc cmake tcl yaml-cpp swig bison flex boost spdlog or-tools cudd lemon
# Or give the install prefixes and the compiler:
# export CMAKE_PREFIX_PATH=/path/to/or-tools:/path/to/spdlog:/path/to/yaml-cpp:/path/to/boost
# export CMAKE_C_COMPILER=/path/to/gcc-12/bin/gcc CMAKE_CXX_COMPILER=/path/to/gcc-12/bin/c++
# A dependency that CMake still does not find can be set by its CMake variable, for example
# (LEMON: the OpenROAD fork lemon-graph, tag 1.3.1, not the original LEMON release)
# export LEMON_DIR=/path/to/lemon/share/lemon/cmake
# (the variables are listed in the header of openroad/build_openroad.sh).
