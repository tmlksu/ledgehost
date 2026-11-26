#!/bin/sh
# Pre-push / pre-commit check: fail if any tracked file contains a
# forbidden personal identifier. Run from the repository root.
#   sh scripts/check-forbidden-strings.sh
# Exits 0 when clean, 1 when a match is found.
set -eu

# Forbidden patterns are assembled from fragments so this script itself
# does not contain the literal strings it searches for.
p1='pey''an'
p2='ism''il'
p3='ri''ad'
p4='sudo''su'
p5='172\.20\.121\.'
p6='tml''ksu'

pattern="$p1|$p2|$p3|$p4|$p5|$p6"

# Search tracked files when in a git repo, otherwise all files under .
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  files=$(git ls-files)
else
  files=$(find . -type f -not -path './.git/*')
fi

fail=0
for f in $files; do
  # This checker must not flag itself.
  case "$f" in
    *check-forbidden-strings.sh) continue ;;
  esac
  if grep -E -i -q "$pattern" "$f" 2>/dev/null; then
    echo "FORBIDDEN STRING in: $f"
    fail=1
  fi
done

if [ "$fail" -ne 0 ]; then
  echo "check-forbidden-strings: FAILED" >&2
  exit 1
fi
echo "check-forbidden-strings: clean"
