# asap7_nangate45_3D platform

Heterogeneous two-tier face-to-face stack: ASAP7 standard cells on the upper tier, NanGate FreePDK45 standard cells
on the bottom tier, assembled for the Pin-3D flow from the ASAP7 and NanGate45 platforms of OpenROAD-flow-scripts.

| Content | Origin and modification |
|---|---|
| `lef/asap7_nangate45_{2A6M10M,6M10M}.lef` | ASAP7 technology LEF (upper tier, `_m` layer suffix) merged with the NanGate45 technology layers (bottom tier) and the `hb_layer` hybrid-bond cut layer |
| `lef_upper/`, `lib_upper/` | ASAP7 standard-cell LEF/lib (`*.processed.*`: the cell subset used by the designs) with the `_upper` suffix; FakeRAM 2.0 macros |
| `lef_bottom/`, `lib_bottom/` | NanGate45 standard-cell LEF/lib with the `_bottom` suffix, `metal1` renamed to `M1`, a `SITE` definition added, and the cell subset used by the designs; `*.cover.*` copies use `CLASS COVER`; FakeRAM 2.0 macros |
| `setRC_*.tcl` | wire and via RC for both technologies and the hybrid-bond via resistance |
| `config.mk` | the variables read by the CTS flow (technology LEF, per-tier LEF/lib lists, placement sites, excluded cells, clock buffers, CTS tier) |

The placed inputs of this platform contain no NanGate45 placement rows; the flow snaps new bottom-tier clock cells
to the NanGate45 site grid. Every library file keeps its original license header; see `THIRD_PARTY_NOTICES.md`.
