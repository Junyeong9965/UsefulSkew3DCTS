#!/usr/bin/env bash
# Flow-home environment (sourced by flow/*.sh before every OpenROAD session).
# The OpenROAD binary and the runtime libraries are set in ../setup_env.sh.
FLOW_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export FLOW_HOME
export QT_QPA_PLATFORM="${QT_QPA_PLATFORM:-offscreen}"   # headless OpenROAD
