# Useful-Skew Clock Tree Synthesis for Face-to-Face 3D ICs

Clock tree synthesis (CTS) flow of our paper on useful-skew CTS for face-to-face (F2F) stacked 3D ICs with hybrid
bonding. From a placed two-tier design and its constraints, the flow builds a 3D clock tree that reduces setup and
hold violations while limiting clock buffers and hybrid-bond terminals: selected sinks are regrouped onto new
early-clock paths, additional delays scheduled by a linear program are realized through shared buffer chains with
load-aware tap assignment, and STA-guided refinement improves the constructed tree. One command runs the flow for
one benchmark case and produces the CTS checkpoint that is handed to routing.

<p align="center"><img src="docs/images/cts_flow.png" width="100%" alt="Clock construction flow"></p>

The implementation is a patch to OpenROAD (`openroad/openroad_3dcts.patch`) plus the shell / Tcl scripts under
`flow/` that drive the OpenROAD sessions and three small native tools (`flow/native/`). The early-clock decision
(scoped reference view, stored-check replay, shift calibration, early-group selection, hub candidates) is part of the
patch (`src/cts/src/Early*.cpp`, Tcl commands `cts::early_*`); its candidate probes run inside the decision sessions.

| Paper section | Main implementation |
|---|---|
| III-A. Timing Analysis and LP Scheduling | `TimingGraphExtractor.cpp` — `extractRegisterEdges()`; `CtsSkewLpSolver.cpp` — `solveTns()` |
| III-B. Early-Clock Construction | `StagePredictor.cpp` — `runStagePredictor()`; `EarlyClockGroups.cpp`, `EarlyHub.cpp` |
| III-C. Shared Delay Chains | `HTreeBuilder.cpp` — `buildSharedDelayChains()`, `assignLoadAwareTapDepths()` |
| III-D. Clock Tree Refinement | `ClockRefinement.cpp` — `runClockRefinement()` |

The `.cpp` files are added by the patch under `src/cts/src/` of the OpenROAD source tree.

## Build

Requirements: Linux x86-64, GNU make, bash 4+, a C++17 compiler (gcc 12 or later), and the upstream OpenROAD
build dependencies. The largest case (`ariane133`) needs about 30 GB of memory.

```
openroad/build_openroad.sh ../OpenROAD-3dcts    # upstream OpenROAD at commit 0609245c + the patch
cp setup_env.example.sh setup_env.sh            # set CTS3D_OPENROAD to the built binary
tools/build_helpers.sh                          # native flow helpers (graph merge, checks, selection)
```

Dependency locations that are not on the default search paths go into `openroad/deps.local.sh`
(see `openroad/deps.example.sh`).

## Run

```
./run_cts.sh --list          # the ten cases (aes, ibex, jpeg, swerv_wrapper, ariane133 on two F2F stacks) and their clock periods
./run_cts.sh a7a7_aes        # CTS of one case  -> runs/a7a7_aes/OUTPUT/
./run_route.sh a7a7_aes      # routing, extraction and final STA of that checkpoint -> runs/a7a7_aes/route/
./run_cts.sh all -j 2        # all ten cases, two at a time (./run_route.sh all -j 2 likewise)
```

The placed inputs under `inputs/` were produced with the Pin-3D flow; the platform collateral under `orfs/platforms/`
is derived from the ASAP7 and NanGate45 open libraries (origin and modifications in `orfs/platforms/*/README.md`). The cases and their
clock periods are listed in `configs/cases.tsv`; a few designs use design-specific CTS settings in
`orfs/designs/<platform>/<design>/config_bottom_cover.mk` (`./run_cts.sh --list` shows them).

`run_cts.sh` writes `runs/<case>/OUTPUT/`: the CTS checkpoint `4_cts.{odb,def,v,sdc}`. The stage data (logs, reports,
intermediate files) is under `runs/<case>/work/`; stage databases are deleted as soon as no later step reads them (`-k` keeps them).

`run_route.sh` routes that checkpoint with OpenROAD (global and detailed routing, 10 detailed-routing iterations),
extracts parasitics with OpenRCX and reports the post-route timing, area, power and wire length in
`runs/<case>/route/reports/<platform>/<design>/openroad/6_finish.rpt` (routed design in `results/.../6_final.*`).
The two `ariane133` cases are routed with Cadence Innovus 21.1 (route only, no post-route optimization) (`INNOVUS_EXE` in `setup_env.sh`; scripts under
`orfs/scripts_cadence/`), followed by the same OpenRCX extraction and OpenROAD timing report.

## Scope

The flow covers CTS, routing, extraction and final STA of the placed designs; synthesis and placement are not part of
this repository. Timing inside the CTS flow uses placement-based parasitic estimation with propagated clocks.
