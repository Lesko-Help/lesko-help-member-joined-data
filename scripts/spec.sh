#!/usr/bin/env sh
# Read a module spec in the terminal.
#
#   scripts/spec.sh                 list the specs
#   scripts/spec.sh build-overview  render and browse that spec
#
# With pandoc and w3m installed you get a browsable page: Tab/Enter to follow a
# link, B to go back, / to search, q to quit. Without them it falls back to the
# Markdown source in a pager, which is perfectly readable.
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SPECS="$ROOT/docs/specs"

if [ $# -eq 0 ]; then
    echo "Specs in docs/specs:"
    for f in "$SPECS"/*.md; do
        b=$(basename "$f" .md)
        case "$b" in _*|README) continue ;; esac
        printf '  %-18s %s\n' "$b" "$(sed -n 's/^title: //p' "$f" | head -1)"
    done
    echo
    echo "Usage: scripts/spec.sh <name>"
    exit 0
fi

SRC="$SPECS/$1.md"
[ -f "$SRC" ] || { echo "No such spec: $1" >&2; exit 1; }

if command -v pandoc >/dev/null 2>&1 && command -v w3m >/dev/null 2>&1; then
    OUT="${TMPDIR:-/tmp}/spec-$1.html"
    pandoc --standalone --toc --metadata title="$1" \
           -f markdown -t html5 "$SRC" -o "$OUT"
    exec w3m -o display_charset=utf-8 "$OUT"
fi

exec "${PAGER:-less}" "$SRC"
