#!/usr/bin/env bash
# Site configuration of the 3D CTS flow.  Copy to setup_env.sh and edit (setup_env.sh is not tracked by git):
#   cp setup_env.example.sh setup_env.sh
# openroad/build_openroad.sh, flow/cts/native/build.sh, run_cts.sh and run_route.sh read this file.

# OpenROAD binary with the 3D CTS changes (path printed by openroad/build_openroad.sh); every stage uses this one binary
export CTS3D_OPENROAD=/path/to/OpenROAD-3dcts/build/bin/openroad

# thread budget of one case (graph extraction runs THREADS processes x 1 thread)
export THREADS=${THREADS:-16}

# Cadence Innovus (routing of ariane133 only; ./run_route.sh of the other designs needs no Cadence tool)
# export INNOVUS_EXE=/path/to/innovus

# Dependencies installed outside the default search paths (used by openroad/build_openroad.sh), for example:
# export CMAKE_PREFIX_PATH=/path/to/or-tools:/path/to/spdlog:/path/to/yaml-cpp:/path/to/boost
# export CMAKE_C_COMPILER=/path/to/gcc-12/bin/gcc CMAKE_CXX_COMPILER=/path/to/gcc-12/bin/c++
# Other CMake locations can be set here when needed; see the header of openroad/build_openroad.sh.
