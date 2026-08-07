#!/usr/bin/env bash
# The Rule 11 ratchet — void signatures only go DOWN.
#
#   ./tool/rule11_ratchet.sh            # verify against the baseline
#   ./tool/rule11_ratchet.sh --update   # rewrite the baseline (after a
#                                       # migration phase lowers counts)
#
# Counts production `void` / `Future<void>` method signatures per package
# (lib/ only; `void Function(` callback TYPES are excluded — they are
# sinks by construction, see rules.md Rule 11). The committed baseline
# (tool/rule11_baseline.txt) must match reality EXACTLY: a rise fails CI
# (new void API), and a fall fails too until the baseline is tightened —
# so improvements can never silently drift back.
#
# The migration plan behind this: ~/.claude/plans/rule11-void-migration.md.
# The sanctioned-sink ledger lives at the bottom of the baseline file as
# comments.
set -u

BASELINE="tool/rule11_baseline.txt"

count_package() {
  # Signatures like `void name(` / `Future<void> name(`, excluding
  # callback types (`void Function(`), comment lines, and main().
  grep -rhoE '(^|[[:space:]])(Future<void>|void) [a-zA-Z_][a-zA-Z0-9_]*\(' \
      "$1/lib" --include='*.dart' 2>/dev/null \
    | grep -v 'void Function(' \
    | grep -cv ' main(' || true
}

current() {
  for dir in packages/*/*/; do
    name=${dir#packages/}
    name=${name%/}
    [ -d "$dir/lib" ] || continue
    n=$(count_package "$dir")
    [ "$n" -gt 0 ] && echo "$name $n"
  done
}

if [ "${1:-}" = "--update" ]; then
  {
    echo "# Rule 11 void-signature baseline — regenerate with:"
    echo "#   ./tool/rule11_ratchet.sh --update"
    echo "# Counts only go DOWN (see tool/rule11_ratchet.sh)."
    current
  } > "$BASELINE"
  echo "baseline rewritten: $BASELINE"
  exit 0
fi

if [ ! -f "$BASELINE" ]; then
  echo "RULE 11 RATCHET: missing $BASELINE — run with --update once."
  exit 1
fi

fail=0
while read -r pkg base; do
  case "$pkg" in \#*|'') continue;; esac
  dir="packages/$pkg"
  [ -d "$dir/lib" ] && now=$(count_package "$dir") || now=0
  if [ "$now" -gt "$base" ]; then
    echo "RULE 11 RATCHET: $pkg rose to $now void signatures (baseline $base) — new void APIs must return what they did (rules.md Rule 11)."
    fail=1
  elif [ "$now" -lt "$base" ]; then
    echo "RULE 11 RATCHET: $pkg improved to $now (baseline $base) — tighten the baseline: ./tool/rule11_ratchet.sh --update"
    fail=1
  fi
done < "$BASELINE"

# Packages absent from the baseline must be void-free.
current | while read -r pkg n; do
  if ! grep -q "^$pkg " "$BASELINE"; then
    echo "RULE 11 RATCHET: $pkg has $n void signatures but no baseline entry."
    exit 9
  fi
done || fail=1
[ $? -eq 9 ] && fail=1

if [ "$fail" -ne 0 ]; then
  echo "RULE 11 RATCHET FAILED"
  exit 1
fi
echo "RULE 11 RATCHET OK"
