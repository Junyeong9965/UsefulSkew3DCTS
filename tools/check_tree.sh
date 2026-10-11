#!/usr/bin/env bash
# Hygiene check of the repository tree before a push (files listed in .gitignore are skipped):
#   - every shell script parses; no symbolic links; no absolute home or temporary paths and no host-name
#     gates in the scripts and configurations; no version tags or dates in the scripts;
#   - no file over 95 MB (GitHub limit 100 MB);
#   - orfs/platforms, orfs/designs and inputs hold exactly the platforms / designs / cases of configs/cases.tsv, every
#     placed input is present and inputs/SHA256SUMS verifies.
# Vendor platform files (orfs/platforms/*/lef*, lib*) are not scanned for text patterns.
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd); cd "$ROOT"; bad=0
files=$(find . -path ./runs -prune -o -path ./.git -prune -o -path ./flow/native/bin -prune -o -name setup_env.sh -prune \
        -o -name '*.local.*' -prune -o -name __pycache__ -prune -o -type f -print -o -type l -print)
links=$(find . -path ./runs -prune -o -type l -print); [[ -z $links ]] || { echo "symlinks:"; echo "$links"; bad=1; }
ours=$(echo "$files" | grep -v '^./orfs/platforms/' | grep -E '\.(sh|tcl|py|mk|env|json|cfg|md|tsv|cpp|cff)$|/Makefile$|/LICENSE$')
for f in $(echo "$ours" | grep -E '\.sh$'); do bash -n "$f" 2>/dev/null || { echo "bash syntax: $f"; bad=1; }; done
abs=$(echo "$ours" | xargs grep -lE '/(home|tmp)/[A-Za-z]' 2>/dev/null)
[[ -z $abs ]] || { echo "absolute paths in:"; echo "$abs"; bad=1; }
host=$(echo "$ours" | grep -v "^./tools/check_tree.sh$" | grep -E "\.(sh|tcl|py)$" | xargs grep -lE 'case .*hostname|hostname[^|]*(==|!=)|\[\[[^]]*hostname' 2>/dev/null)
[[ -z $host ]] || { echo "host-name gates in:"; echo "$host"; bad=1; }
ver=$(echo "$ours" | grep -v '^./tools/check_tree.sh$' | grep -E '\.(sh|tcl|py|mk|env|json|cfg|tsv|cpp)$|/Makefile$' \
      | xargs grep -nE '\b[Vv][0-9]{2,3}[a-z]?\b|[Vv]1[0-9]{2}_|20[0-9]{2}-[0-9]{2}-[0-9]{2}' 2>/dev/null)
[[ -z $ver ]] || { echo "version tags / dates:"; echo "$ver" | head -40; bad=1; }
big=$(echo "$files" | xargs ls -l 2>/dev/null | awk '$5 > 95*1024*1024 {print $5, $9}')
[[ -z $big ]] || { echo "files over 95 MB:"; echo "$big"; bad=1; }
# platform / design / input directories against the case table
want_p=$(awk -F'\t' '!/^#/ && NF {print $2}' configs/cases.tsv | sort -u)
want_d=$(awk -F'\t' '!/^#/ && NF {print $2"/"$3}' configs/cases.tsv | sort -u)
want_c=$(awk -F'\t' '!/^#/ && NF {print $1}' configs/cases.tsv | sort -u)
have_p=$(ls orfs/platforms | sort); have_d=$(cd orfs/designs && ls -d */*/ | sed 's#/$##' | sort); have_c=$(ls -d inputs/*/ | xargs -n1 basename | sort)
[[ $want_p == "$have_p" ]] || { echo "platforms differ from cases.tsv:"; diff <(echo "$want_p") <(echo "$have_p"); bad=1; }
[[ $want_d == "$have_d" ]] || { echo "designs differ from cases.tsv:"; diff <(echo "$want_d") <(echo "$have_d"); bad=1; }
[[ $want_c == "$have_c" ]] || { echo "inputs differ from cases.tsv:"; diff <(echo "$want_c") <(echo "$have_c"); bad=1; }
while IFS=$'\t' read -r c p d t rest; do
  [[ $c == \#* || -z $c ]] && continue
  for f in def sdc v; do [[ -s inputs/$c/T$t/3_place.$f ]] || { echo "missing inputs/$c/T$t/3_place.$f"; bad=1; }; done
done < configs/cases.tsv
( cd inputs && sha256sum --quiet -c SHA256SUMS ) || { echo "inputs/SHA256SUMS mismatch"; bad=1; }
[[ $bad == 0 ]] && echo "check_tree: OK ($(echo "$files" | wc -l) files)" || echo "check_tree: FAILED"
exit $bad
