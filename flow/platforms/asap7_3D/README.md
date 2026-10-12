# asap7_3D platform

Two-tier face-to-face stack with ASAP7 standard cells on both tiers, assembled for the Pin-3D flow from the ASAP7
platform of OpenROAD-flow-scripts (ASAP7 7 nm predictive PDK v1.7, Arizona State University).

| Content | Origin and modification |
|---|---|
| `lef/asap7_tech_1x_{2A6M7M,6M7M}.lef` | ASAP7 technology LEF merged into a two-tier stack; upper-tier layers carry the `_m` suffix; `hb_layer` is the hybrid-bond cut layer between the tiers |
| `lef_bottom/`, `lef_upper/` | ASAP7 standard-cell LEF with `_bottom`/`_upper` cell-name suffix; `*.cover.lef` copies use `CLASS COVER` (cells of the other tier are blockages during per-tier legalization); FakeRAM 2.0 memory macros in `fakeram_block/` and `fakeram_cover/` |
| `lib_bottom/`, `lib_upper/` | ASAP7 NLDM libraries with the same cell-name suffixes; FakeRAM macro libraries |
| `setRC_*.tcl` | wire and via RC of the OpenROAD-flow-scripts ASAP7 platform, extended with the upper-tier layers and the hybrid-bond via resistance |
| `config.mk` | the variables read by the CTS flow (technology LEF, per-tier LEF/lib lists, placement site, excluded cells, clock buffers) |

Every library file keeps its original license header; see `../LICENSE.ASAP7` for the licenses and the full
list of modifications.
