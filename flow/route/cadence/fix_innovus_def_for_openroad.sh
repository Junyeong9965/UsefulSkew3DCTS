#!/bin/bash
# Post-processing of an Innovus DEF for the OpenROAD DEF reader, which accepts only tech-LEF vias in NONDEFAULTRULES
# and no VIRTUAL routing segments:
#   1. NONDEFAULTRULES: "+ VIA" entries of NanoRoute generated vias (NR_VIA*, M2_M1_VH, TECH_RULE_*, M2_m_M1_m_*,
#      M3add_M2add_*, ...) are removed; tech-LEF vias are kept.
#   2. NETS: the VIRTUAL keyword (zero-length routing segments) is removed.
#
# Usage: bash fix_innovus_def_for_openroad.sh <input.def> [output.def]
#        If output omitted, writes to <input>.mod.def

set -euo pipefail

INPUT="$1"
OUTPUT="${2:-${INPUT%.def}.mod.def}"

if [[ ! -f "$INPUT" ]]; then
    echo "ERROR: $INPUT not found" >&2
    exit 1
fi

awk '
# 1. NONDEFAULTRULES: keep "+ VIA" lines of tech-LEF vias (VIA12, VIA56_m, VIA_M1m_M2add, hb_layer_0, ...);
#    every other via (Vx_, M2add_, NR_VIA, TECH_RULE_, ...) is NanoRoute generated
/^NONDEFAULTRULES/,/^END NONDEFAULTRULES/ {
    if ($0 ~ /\+ VIA / && $0 !~ /\+ VIA (VIA[0-9]|VIA_M|hb_layer|via[0-9])/) next
}
# 2. remove the VIRTUAL keyword from the routing
{ gsub(/ VIRTUAL /, " "); print }
' "$INPUT" > "$OUTPUT"

# Report
REMOVED=$(( $(wc -l < "$INPUT") - $(wc -l < "$OUTPUT") ))
VIRTUAL_ORIG=$(grep -c "VIRTUAL" "$INPUT" || true)
VIRTUAL_LEFT=$(grep -c "VIRTUAL" "$OUTPUT" || true)
VIRTUAL_FIXED=$(( VIRTUAL_ORIG - VIRTUAL_LEFT ))
echo "Removed $REMOVED NDR via lines, fixed $VIRTUAL_FIXED/$VIRTUAL_ORIG VIRTUAL keywords"
echo "Output: $OUTPUT"
