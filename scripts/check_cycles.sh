#!/usr/bin/env bash
# Dependency-cycle guard.
#
# CODE_QUALITY_REFACTOR_ROADMAP took `mix xref` cycles from 6 to 2 and recorded
# the two survivors as accepted, with reasons. Nothing then held that result: a
# third cycle appeared on 08-03 (Trading -> ChartBuilder -> Portfolio ->
# Trading) and went unnoticed until someone re-ran xref by hand a day later.
# A number nobody checks is a number that drifts back.
#
# So this asserts the inventory rather than a total: each accepted cycle is
# named with WHY it is accepted, and anything else fails. Breaking one of the
# two is a win and fails here too — deliberately, so the roadmap gets updated
# in the same commit that earns it.
#
# The two accepted cycles:
#
#   ~69 files, 1 export — the Phoenix web layer. Router <-> LiveView <->
#   verified-routes is inherent to the framework's compile-time route helpers;
#   breaking it means giving up verified routes.
#
#   4 files — the Google ring. OAuth persists through its parent context, which
#   is idiomatic, runtime-only, and would take relocating a PubSub topic to
#   undo. Accepted for a number's sake is exactly what it would be.
#
# No `lib/buster_claw` (core) file may participate in a cross-layer cycle. That
# is the property worth keeping, and it is what the third cycle broke.
set -euo pipefail
cd "$(dirname "$0")/.."

CYCLES=$(mix xref graph --format cycles 2>/dev/null | grep '^Cycle of length' || true)
COUNT=$(printf '%s' "$CYCLES" | grep -c . || true)

if [ "$COUNT" -ne 2 ]; then
  echo "FAIL: expected exactly 2 accepted dependency cycles, found ${COUNT}."
  echo
  echo "Found:"
  printf '%s\n' "$CYCLES"
  echo
  echo "A NEW cycle: break it, or add it here with the reason it is accepted."
  echo "One FEWER: congratulations — update this script and the roadmap together."
  echo
  echo "Full detail: mix xref graph --format cycles"
  exit 1
fi

# The web cycle grows and shrinks with the number of LiveViews, so its length is
# not pinned; its shape is what matters. The Google ring is small and stable.
if ! printf '%s' "$CYCLES" | grep -q 'Cycle of length 4:'; then
  echo "FAIL: the 4-file Google cycle is not where it was."
  printf '%s\n' "$CYCLES"
  exit 1
fi

echo "OK: 2 accepted dependency cycles (web layer, Google ring)."
