#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 2 ] || { [ "$1" != staple ] && [ "$1" != validate ]; }; then
  echo "Usage: bash scripts/stapler_retry.sh <staple|validate> <artifact>" >&2
  exit 64
fi

# Apple's ticket service can drop connections even after notarization succeeds.
# Retry briefly, but keep validation mandatory and preserve its final exit code.
for attempt in 1 2 3; do
  if xcrun stapler "$1" "$2"; then
    exit 0
  else
    status=$?
  fi

  if [ "$attempt" -eq 3 ]; then
    echo "stapler $1 failed after $attempt attempts (exit $status)." >&2
    exit "$status"
  fi

  echo "stapler $1 failed (exit $status); retrying in 5 seconds ($attempt/3)." >&2
  sleep 5
done
