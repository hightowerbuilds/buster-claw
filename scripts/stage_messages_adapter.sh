#!/usr/bin/env bash
# Stage only the ordinary Messages adapter and its Swift resource bundles.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="0.15.6"
SHA256="a91bf50a568878b4aca68391dcd24368c687261bf6c0c252af82bd8b2eb796b1"
ARCHIVE="tmp/imessage-spike/imsg-macos.zip"
DEST="priv/messages"
URL="https://github.com/openclaw/imsg/releases/download/v${VERSION}/imsg-macos.zip"

mkdir -p tmp/imessage-spike
if [ ! -f "$ARCHIVE" ]; then
  curl --fail --location --retry 3 "$URL" -o "$ARCHIVE.part"
  mv "$ARCHIVE.part" "$ARCHIVE"
fi

ACTUAL="$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')"
if [ "$ACTUAL" != "$SHA256" ]; then
  echo "FATAL: Messages adapter checksum mismatch: $ARCHIVE" >&2
  exit 1
fi

# Extract into a fresh directory; old or private helper files cannot survive a
# rebuild. These are explicit entries, never a whole-archive extraction.
STAGE="$(mktemp -d tmp/imessage-spike/stage.XXXXXX)"
trap 'rm -rf "$STAGE"' EXIT
unzip -q "$ARCHIVE" imsg 'SQLite.swift_SQLite.bundle/*' \
  'PhoneNumberKit_PhoneNumberKit.bundle/*' -d "$STAGE"
codesign --verify --strict "$STAGE/imsg"
[ "$("$STAGE/imsg" --version)" = "$VERSION" ] || {
  echo "FATAL: Messages adapter version mismatch" >&2
  exit 1
}
test -s "$STAGE/PhoneNumberKit_PhoneNumberKit.bundle/PhoneNumberMetadata.json"
test -s "$STAGE/SQLite.swift_SQLite.bundle/PrivacyInfo.xcprivacy"
for notice in imsg Commander SQLite.swift PhoneNumberKit; do
  test -s "priv/third_party/imsg/$notice-LICENSE.txt"
done
rm -rf "$DEST"
mkdir -p "$DEST"
cp -R "$STAGE/." "$DEST/"
echo "    staged imsg $VERSION (verified checksum and signature, ordinary adapter only)"
