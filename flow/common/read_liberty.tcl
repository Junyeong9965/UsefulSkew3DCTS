# Liberty reading as in OpenROAD-flow-scripts (BSD-3-Clause, The Regents of the University of California):
# every library of LIB_FILES (one corner).
foreach libFile $::env(LIB_FILES) {
  read_liberty $libFile
}
