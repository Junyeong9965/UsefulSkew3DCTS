#!/usr/bin/env bash
# Site configuration of the 3D CTS flow.  Copy to setup_env.sh and edit (setup_env.sh is not tracked by git):
#   cp setup_env.example.sh setup_env.sh

# OpenROAD binary with the 3D CTS changes (build: see README.md); every stage uses this one binary
export CTS3D_OPENROAD=/path/to/OpenROAD/build/bin/openroad

# runtime libraries of that binary (environment modules on our cluster; adjust or delete)
command -v module >/dev/null 2>&1 || source /etc/profile.d/modules.sh 2>/dev/null
if command -v module >/dev/null 2>&1; then
  module load tcl/8.6.6 yaml-cpp/0.8.0 gcc/12.2.0 2>/dev/null || true
fi
# export LD_LIBRARY_PATH=/path/to/extra/libs:${LD_LIBRARY_PATH:-}

# thread budget of one case (stage G runs 16 extraction processes x 1 thread regardless)
export THREADS=${THREADS:-16}

# Cadence Innovus (routing of ariane133 only; ./run_route.sh of the other designs needs no Cadence tool)
# export INNOVUS_EXE=/path/to/innovus
