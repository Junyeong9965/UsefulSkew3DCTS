#!/usr/bin/env bash
# Site configuration of the 3D CTS flow.  Copy to setup_env.sh and edit (setup_env.sh is not tracked by git):
#   cp setup_env.example.sh setup_env.sh

# OpenROAD binary with the 3D CTS changes (build: see README.md); every stage uses this one binary
export CTS3D_OPENROAD=/path/to/OpenROAD/build/bin/openroad

# runtime libraries of that binary that are not on the default search path, for example
# export LD_LIBRARY_PATH=/path/to/tcl/lib:/path/to/yaml-cpp/lib64:/path/to/gcc/lib64:${LD_LIBRARY_PATH:-}

# thread budget of one case (graph extraction runs THREADS processes x 1 thread)
export THREADS=${THREADS:-16}

# Cadence Innovus (routing of ariane133 only; ./run_route.sh of the other designs needs no Cadence tool)
# export INNOVUS_EXE=/path/to/innovus
