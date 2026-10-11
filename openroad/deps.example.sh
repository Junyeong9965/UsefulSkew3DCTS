# Dependency locations for build_openroad.sh.  Copy to deps.local.sh (not tracked) and edit; every entry is optional
# (an empty value leaves the CMake default search).  Validated versions: gcc 12.2, OR-Tools 9.15, spdlog 1.15.1,
# Boost 1.81, yaml-cpp 0.8.0, Tcl 8.6.6, SWIG 4.0, Bison 3.3, Flex 2.6.4, lemon 1.3.1 (lemon-graph), CUDD 3.0.0.
ORTOOLS=/opt/or-tools                 # prebuilt OR-Tools package (contains absl, protobuf, re2)
SPDLOG=/opt/spdlog
BOOST=/opt/boost
YAMLCPP=/opt/yaml-cpp
GCC=/opt/gcc-12
export CMAKE_PREFIX_PATH="$ORTOOLS:$SPDLOG:$YAMLCPP:$BOOST"
export CMAKE_C_COMPILER=$GCC/bin/gcc CMAKE_CXX_COMPILER=$GCC/bin/c++
export CPLUS_INCLUDE_PATH="$BOOST/include:$ORTOOLS/include:$SPDLOG/include:${CPLUS_INCLUDE_PATH:-}"
export LIBRARY_PATH="$ORTOOLS/lib64:$ORTOOLS/lib:$YAMLCPP/lib64:$GCC/lib64:${LIBRARY_PATH:-}"
export LD_LIBRARY_PATH="$ORTOOLS/lib64:$ORTOOLS/lib:$SPDLOG/lib64:$GCC/lib64:${LD_LIBRARY_PATH:-}"
export RPATH_DIRS="$ORTOOLS/lib64 $ORTOOLS/lib $SPDLOG/lib64 $GCC/lib64"
# optional explicit tool / library locations (CMake variable names)
export BISON_EXECUTABLE= FLEX_EXECUTABLE= FLEX_INCLUDE_DIR= SWIG_EXECUTABLE=
export LEMON_DIR= LEMON_INCLUDE_DIR= LEMON_LIBRARY= CUDD_HEADER= CUDD_LIB= spdlog_DIR= Boost_DIR= TCL_LIBRARY= TCL_HEADER=
