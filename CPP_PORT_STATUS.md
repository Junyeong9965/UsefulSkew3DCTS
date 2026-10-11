# C++ port of the Python decision / check modules — status log

Branch `cpp-port` (worktree `3DCTS_cpp`), OpenROAD source `OpenROAD-3dcts-cpp` (upstream 0609245c + patch).
Reference runs: `3DCTS_iscas_ref/runs/ref_aes` (a7a7_aes), `3DCTS_iscas_ref/runs/ref_jpeg` (a7n45_jpeg).

## Step 0 — baseline binary
- `JOBS=24 bash openroad/build_openroad.sh ../OpenROAD-3dcts-cpp` : OK
  (`$CTS3D_OPENROAD -version` -> 26Q1-617-g0609245cc4).

## Numerical facts reproduced from the Python stack (python 3.9.20, numpy 2.0.2, scipy 1.13.1)
- `ndarray.sum()` of a contiguous float64 array = `0.0 + pairwise_sum(a)` (numpy `DOUBLE_pairwise_sum`, blocks of
  8 accumulators up to 128 elements, recursive halving to a multiple of 8; n < 8 sequential from -0.0).
- `np.bincount(x, weights)` and Python `sum()` are sequential sums.
- `array ** 2` is `np.square` (x*x); a Python / numpy scalar `** 2` and `** 0.5` call libm `pow`.
- `round(np.float64, n)` = `rint(x * 10**n) / 10**n`; `round(float, n)` = correctly rounded decimal.
- `str()/repr()` of floats = shortest round-trip digits (std::to_chars), Python 'r' layout.
- `csv.writer` / `DictWriter` lines end with CRLF; files written with `f.write` end with LF.
- scipy `cKDTree(leafsize=16, balanced_tree, compact_nodes)` build (std::nth_element + std::partition on the index
  array, compact bounds) and `query(k, p=1, distance_upper_bound)` (node heap + neighbour heap, strict `<` on the
  bound) are re-implemented from scipy 1.13.1 `build.cxx` / `query.cxx` with the same libstdc++ algorithms.

## Work log
(see below, newest last)

### Step 1 — replay / scope / HBT / hub path (C++ in the OpenROAD patch, `src/cts/src/Early*.{h,cpp}`)
- `EarlyUtil.h` (CSV, Python repr/round, numpy sums, JSON), `EarlyClockReplay.{h,cpp}` (load_replay, HBT, scope),
  `EarlyHub.cpp` (generate / measure / select / multi), `EarlyDecision.h` (entry points).
- Validated on `3DCTS_iscas_ref/runs/ref_jpeg` (standalone CLI built from the same sources, reference probe reports):
  `decide/view/{scope.json,fixed_groups.csv,fixed_regs.txt,P/.../phase1_leaf_groups.csv}`, `decide/hub/gen.csv`,
  `gen.json` (except runtime_s), `cands/*` (17 files), `measured.csv`, `plan/{plan.tsv,cid,select.json}`,
  `multi_hub/{plan_k2.tsv,plan_k3.tsv,prefixes.json}` all byte-identical.  Scope also identical on ref_aes.

### Step 2 — calibration (`EarlyClockCalibration.cpp`)
- Structures (`cands/*`, 21 files) and fit from the reference probe reports (`calib.json`, `calib_points.csv`)
  byte-identical on ref_jpeg and ref_aes.

### Step 3 — early groups (`EarlyClockGroups.cpp`, `EarlyKDTree.h`)
- KD-tree replica checked against scipy.cKDTree on the aes / jpeg register coordinates and on tie-heavy integer
  grids (k, bound sweeps): identical neighbour sets.
- ref_aes `decide/early_groups/{plan.tsv,membership.csv,groups.csv,clusters.csv,prefix.csv,pred_shift.csv,regs_debug.csv}`
  and the three `search_*` directories: byte-identical; `summary.json` identical except the time fields.
  ref_jpeg (model_invalid): plan.tsv identical, summary.json json_same.

### Step 4 — native flow tools (`flow/native/{partitions,checks,select}.cpp`, built by `tools/build_helpers.sh`)
- `cts_partitions check|merge` (umap_order embedded): merged G results of ref_aes / ref_jpeg (6 files each) identical.
- `cts_checks targets|lp-bounds|inputs|guard-*`: TARGET_VERIFICATION.json json_same, `lp_bounds.csv` /
  `lp_undeliverable.csv` identical and the `LP bounds:` log line identical (ref_aes ON arm).
- `cts_select plan|output|overlap|report|multihub|jget`: check_on.json, select.json, overlap summary,
  multi_hub.json json_same; OUTPUT/{POLICY.txt,timing.txt,times.txt} byte-identical (ref_aes / ref_jpeg data).

### In-session probe loop (Tcl) and flow wiring
- `flow/tcl/early_probe.tcl` (probe procs, `probe_candidates`), `early_decide.tcl` (session A: scope + calibration +
  early groups), `early_hub.tcl` (session B: hub generate/probe/measure/select + multi-hub prefixes); `early_eval.tcl`
  kept as a stand-alone wrapper.  `cts::early_*` commands registered in `TritonCTS.i`; patch regenerated.
- Session A on the reference OFF arms: aes 76 / jpeg 49 decision files byte-identical to the reference (incl. all
  `probe/reports/arr_*.csv`, `raw_base.csv`); session B on jpeg: 43 files identical (hub + multi-hub).
- `policy.sh`, `stage.sh`, `cts_session.sh`, `route_prep.sh`, `cts_3d.tcl`, `common.sh` call the native tools / the
  sessions; no python3 call left in the flow scripts (the .py files are removed after step 5).

### Step 5 — whole-case equivalence
- `THREADS=8 ./run_cts.sh a7a7_aes -w runs/cpp_aes` (binary with the cts::early_* commands): OUTPUT on (early groups),
  end to end 214 s.  `python3 ../3DCTS_v162/tools/cmp_runs.py ../3DCTS_iscas_ref/runs/ref_aes runs/cpp_aes --odb-dump
  $CTS3D_OPENROAD` -> `SUMMARY compared=140 json_same=5 same=130 text_same=5` (0 DIFF).
- `THREADS=8 ./run_cts.sh a7n45_jpeg -w runs/cpp_jpeg`: decision model_invalid -> hub F1_893, ON accepted, multi-hub
  k=2 output (as the reference), end to end 1292 s.  cmp_runs vs `../3DCTS_iscas_ref/runs/ref_jpeg` ->
  `SUMMARY compared=159 json_same=6 same=139 semantic_same=9 text_same=5` (0 DIFF).  The json_same files:
  `decide/early_groups/summary.json`, `decide/hub/gen.json` (runtime fields), `out/check_on.json`,
  `multi_hub/multi_hub.json` (run paths), `multi_hub/k{2,3}/out/check_on.json` (`by_class` key order: the Python
  code iterated a hash-randomised `set`; the C++ writes first-occurrence order; dict contents identical).

### Step 6 — Python removed
- Deleted `flow/decision/{early_model,early_clock}.py`, `flow/extract/{partitions.py,umap_order.cpp}`,
  `flow/checks.py`, `flow/select.py`; README requirements updated (no Python / numpy / scipy; gcc 12+ for the native
  tools); `tools/check_tree.sh` no longer compiles Python files and prunes `flow/native/bin`.  `check_tree: OK`.

## Not numerically identical by construction
- Only run-time / date / host fields of JSON files and the SDC timestamp comment (the cmp_runs benign classes), plus
  the `by_class` dictionary key order noted above.  Every compared CSV/TSV/DEF/Verilog/ODB/report file is identical.

## Commands
- Build: `JOBS=24 bash openroad/build_openroad.sh ../OpenROAD-3dcts-cpp`; `tools/build_helpers.sh`.
- Decision validation on reference data (no DB): the `cts::early_*` commands work on files, e.g.
  `openroad -no_init -exit` with `cts::early_scope <ref_arm> <plat> <des> <dump> <view>`,
  `cts::early_calibrate_structures/fit`, `cts::early_groups`, `cts::early_hub_generate/measure/select/multi`.
- Whole case: `THREADS=8 ./run_cts.sh <case> -w runs/<name>`; compare with
  `python3 ../3DCTS_v162/tools/cmp_runs.py <ref_run> runs/<name> --odb-dump $CTS3D_OPENROAD`.

## Runtime items of the research handoff (RT1 / RT2, `../handoff_rt12/*.md`)
- RT1 (sharded probe sessions): not needed — the probe loop runs inside the decision session; the per-candidate
  apply -> estimate_parasitics -> predict -> undo order of early_eval.tcl is kept (early_probe.tcl) and every
  `arr_*.csv` / `raw_base.csv` of both reference probes is byte-identical.
- RT2(a) (graph cache): `load_graph()` parses the two stage-G CSVs once per session (cache keyed by directory and the
  files' size / mtime; names in first-appearance order, row order kept, values = strtod of the CSV fields) and every
  later step of the session (scope, 4 load_replay of the tier search, hub generate / measure) reuses the arrays.
  No cache file is written.  `register_demand` is not computed: its result was never consumed by the Python code.
- RT2(b) (parallel hub generation): the per-register cgain loops of hub generation and of early-groups step 1 run in
  `NUM_CORES` threads (round-robin slots, per-slot outputs, no cross-thread reduction; the call counter is added
  afterwards).  jpeg gen.csv + cands and aes early_groups (28 files, `cgain_calls`) identical with 8 threads.
- Rebuilt binary (cache + threads, NUM_CORES=4 in the sessions): session A on the ref_aes OFF arm 76/76 files identical,
  sessions A+B on ref_jpeg 92/92 identical (incl. multi-hub plans); decision wall: aes 35 s, jpeg 185 s + 152 s
  (dominated by the per-candidate estimate_parasitics + prediction of the probes, as before).
