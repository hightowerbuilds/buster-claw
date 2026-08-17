#!/usr/bin/env bash
# Assemble the updater feed (latest.json) from the per-architecture bundles.
#
# UPDATE_ROADMAP G-18. This is the file every installed copy of Buster Claw polls
# to learn that a newer version exists; the app fetches it from
# https://busterclaw.lol/updates/latest.json, which rewrites to the `latest`
# GitHub Release.
#
# It lives here rather than inline in release-desktop.yml for the same reason
# codesign_release.sh does: CI calling a script in the repo is one implementation,
# CI holding its own copy is two that drift.
#
# Usage:
#   scripts/build_update_feed.sh --tag v0.1.1 --dir <artifacts> [--out latest.json]
#                                [--repo owner/name] [--notes "..."]
#
# <artifacts> is a directory holding, for EVERY shipped architecture, a pair:
#   BusterClaw_<version>_<arch>.app.tar.gz
#   BusterClaw_<version>_<arch>.app.tar.gz.sig
set -euo pipefail

# The architectures Buster Claw ships, mapped to the platform keys Tauri's
# updater looks itself up by. Buster Claw builds one native bundle per
# architecture and never a universal binary — a lipo'd ERTS cannot allocate JIT
# memory on the Intel slice (APPLE_ROADMAP III.G) — so this table is the thing
# that stops an arm64 install being handed an Intel bundle.
ARCHES=(aarch64 x86_64)
platform_key() {
  case "$1" in
    aarch64) echo "darwin-aarch64" ;;
    x86_64)  echo "darwin-x86_64" ;;
    *) echo "build_update_feed: unknown architecture '$1'" >&2; exit 1 ;;
  esac
}

TAG=""
DIR=""
OUT="latest.json"
REPO="${GITHUB_REPOSITORY:-hightowerbuilds/buster-claw}"
NOTES=""

while [ $# -gt 0 ]; do
  case "$1" in
    --tag)   TAG="$2"; shift 2 ;;
    --dir)   DIR="$2"; shift 2 ;;
    --out)   OUT="$2"; shift 2 ;;
    --repo)  REPO="$2"; shift 2 ;;
    --notes) NOTES="$2"; shift 2 ;;
    *) echo "build_update_feed: unknown argument '$1'" >&2; exit 1 ;;
  esac
done

[ -n "$TAG" ] || { echo "build_update_feed: --tag is required (e.g. v0.1.1)" >&2; exit 1; }
[ -n "$DIR" ] || { echo "build_update_feed: --dir is required" >&2; exit 1; }
[ -d "$DIR" ] || { echo "build_update_feed: no such directory: $DIR" >&2; exit 1; }

# Tauri compares this against the running version and it must NOT carry the `v`.
# A leading `v` makes every comparison fail to parse, which presents as "no
# update available" forever rather than as an error (UPDATE_ROADMAP D4).
VERSION="${TAG#v}"

if [ -z "$NOTES" ]; then
  NOTES="Buster Claw $VERSION. Release notes: https://github.com/$REPO/releases/tag/$TAG"
fi

# The only field here that is not base64, a semver, or a URL — so the only one
# that can carry a character JSON cares about.
json_escape() {
  printf '%s' "$1" \
    | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\t/\\t/g' -e 's/\r//g' \
    | awk 'BEGIN{ORS=""} {print sep $0; sep="\\n"}'
}

PUB_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

platforms=""
for arch in "${ARCHES[@]}"; do
  base="BusterClaw_${VERSION}_${arch}.app.tar.gz"
  tarball="$DIR/$base"
  sigfile="$tarball.sig"

  # Fail closed, and this is the failure worth being loud about. A feed that
  # describes one architecture is not a partial success — it is an update that
  # silently never arrives for everyone on the other one, with no error anywhere
  # for them to see. Shipping half a feed is worse than shipping none.
  if [ ! -f "$tarball" ]; then
    echo "FATAL: missing update bundle for $arch: $tarball" >&2
    echo "" >&2
    echo "Every architecture in ARCHES must be present. A feed missing one strands" >&2
    echo "every install on that architecture — silently, with no error on their end." >&2
    echo "" >&2
    echo "Found in $DIR:" >&2
    ls -A "$DIR" >&2 || true
    exit 1
  fi
  [ -f "$sigfile" ] || {
    echo "FATAL: bundle for $arch has no minisign signature: $sigfile" >&2
    echo "The build ran without TAURI_SIGNING_PRIVATE_KEY, so nothing signed it." >&2
    exit 1
  }

  signature="$(tr -d '\n' < "$sigfile")"
  [ -n "$signature" ] || { echo "FATAL: empty signature for $arch" >&2; exit 1; }

  key="$(platform_key "$arch")"
  url="https://github.com/$REPO/releases/download/$TAG/$base"

  [ -z "$platforms" ] || platforms="$platforms,"
  platforms="$platforms
    \"$key\": {
      \"signature\": \"$signature\",
      \"url\": \"$url\"
    }"
done

cat > "$OUT" <<EOF
{
  "version": "$VERSION",
  "notes": "$(json_escape "$NOTES")",
  "pub_date": "$PUB_DATE",
  "platforms": {$platforms
  }
}
EOF

# Validate rather than trust. A malformed feed is not a build failure anywhere —
# it is a 200 response that every installed app fails to parse, which reads to a
# user as "updates are broken" and to us as nothing at all.
if command -v python3 >/dev/null 2>&1; then
  python3 -c "
import json, sys
feed = json.load(open('$OUT'))
missing = [k for k in ('version', 'notes', 'pub_date', 'platforms') if k not in feed]
if missing:
    sys.exit('latest.json is missing keys: ' + ', '.join(missing))
if not feed['platforms']:
    sys.exit('latest.json describes no platforms')
for name, entry in feed['platforms'].items():
    for field in ('signature', 'url'):
        if not entry.get(field):
            sys.exit('platform %s has no %s' % (name, field))
print('latest.json: valid JSON, %d platform(s): %s'
      % (len(feed['platforms']), ', '.join(sorted(feed['platforms']))))
"
else
  echo "build_update_feed: python3 not found — wrote $OUT WITHOUT validating it" >&2
fi

echo "==> Wrote $OUT for $TAG (version $VERSION)"
