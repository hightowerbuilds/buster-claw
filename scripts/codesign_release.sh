#!/usr/bin/env bash
# Sign every Mach-O object inside a staged Elixir/OTP release.
#
# ## Why this script has to exist
#
# Tauri does not sign `bundle.resources`. Its bundler signs frameworks,
# sidecars, and the main executable, and it *copies* resources without adding
# them to the sign list — its recursive walker descends into six hardcoded
# folders (MacOS, Frameworks, Plugins, Helpers, XPCServices, Libraries) and
# `Resources` is not one of them. The whole Erlang VM lives in `Resources`.
#
# So the naive path fails in the most misleading way available: the build
# succeeds, the app runs fine locally, and notarization comes back rejected once
# per unsigned Erlang binary — each one reading "The binary is not signed with a
# valid Developer ID certificate."
#
# We sign the OTP tree ourselves, before Tauri ever bundles it. This is
# Livebook's pattern (livebook-dev/elixirkit, lib/elixirkit/release.ex) — same
# framework, same VM, same bundling problem, public and solved.
#
# ## Where we diverge from Livebook, and it is not cosmetic
#
# Livebook's finder is `find <release> -perm +111`. Measured against our own
# prod release (OTP 28.4.2 / erts-16.3.1), that finds **17 of 24** Mach-O
# objects. The seven it misses are NIF shared libraries shipped without an
# execute bit:
#
#   crypto.so · crypto_callback.so · otp_test_engine.so · asn1rt_nif.so
#   dyntrace.so · trace_ip_drv.so · trace_file_drv.so
#
# Those are exactly the libraries the BEAM `dlopen`s, and exactly what
# `disable-library-validation` exists to permit. Worse, the pass is *partial* —
# `sqlite3_nif.so` does carry the bit and would be signed — so the failure looks
# arbitrary rather than systematic.
#
# This script therefore identifies Mach-O by **content** (`file`), never by mode
# bits. A NIF's permissions are an accident of how its build system installed
# it; whether it is a Mach-O object is the thing we actually care about.
#
# ## Contract
#
#   codesign_release.sh [release-dir]
#
# With APPLE_SIGNING_IDENTITY unset this is a no-op that says so and exits 0, so
# unsigned local builds and unsigned CI runs keep working unchanged. Signing is
# opt-in by having a certificate, not by passing a flag — there is no way to
# accidentally produce a build that *thinks* it is signed.
set -euo pipefail

cd "$(dirname "$0")/.."
REPO_ROOT="$(pwd)"

RELEASE_DIR="${1:-desktop/tauri/resources/release}"
ENTITLEMENTS="$REPO_ROOT/desktop/tauri/Entitlements.plist"

if [ -z "${APPLE_SIGNING_IDENTITY:-}" ]; then
  echo "==> Code signing: SKIPPED (APPLE_SIGNING_IDENTITY unset — unsigned build)"
  echo "    This bundle will not open on another Mac. See LAUNCH_ROADMAP.md III.F."
  exit 0
fi

if [ ! -d "$RELEASE_DIR" ]; then
  echo "FATAL: no release tree at $RELEASE_DIR" >&2
  exit 1
fi

if [ ! -f "$ENTITLEMENTS" ]; then
  echo "FATAL: no entitlements at $ENTITLEMENTS" >&2
  exit 1
fi

# An empty entitlements file is the trap this whole path exists to avoid: it
# signs and notarizes clean, then the BEAM dies on the user's machine because
# `beam.smp` has no allow-jit of its own. Refuse rather than ship that.
if ! /usr/libexec/PlistBuddy -c "Print :com.apple.security.cs.allow-jit" "$ENTITLEMENTS" >/dev/null 2>&1; then
  echo "FATAL: $ENTITLEMENTS does not grant com.apple.security.cs.allow-jit." >&2
  echo "       Signing the OTP tree without it produces a bundle that notarizes" >&2
  echo "       and then crashes at launch on every machine but this one." >&2
  exit 1
fi

echo "==> Code signing the OTP tree in $RELEASE_DIR"
echo "    identity:     $APPLE_SIGNING_IDENTITY"
echo "    entitlements: ${ENTITLEMENTS#"$REPO_ROOT"/}"

# Mach-O by content, never by mode bits — see the header. Sorted deepest-path
# first so nested objects are signed before anything that encloses them
# (inside-out is the rule; `--deep` is not an acceptable shortcut and Apple's
# own guidance says so).
mach_o_objects() {
  find "$RELEASE_DIR" -type f -print0 |
    while IFS= read -r -d '' candidate; do
      if file -b "$candidate" | grep -q 'Mach-O'; then
        printf '%s\t%s\n' "$(awk -F/ '{print NF}' <<<"$candidate")" "$candidate"
      fi
    done |
    sort -rn -k1,1 |
    cut -f2-
}

OBJECTS=()
while IFS= read -r object; do
  [ -n "$object" ] && OBJECTS+=("$object")
done < <(mach_o_objects)

COUNT=${#OBJECTS[@]}

# A release tree with no Mach-O objects in it is a staging failure wearing a
# success costume — `cp` into an empty destination is not an error, and every
# signature below would be a no-op loop that exits 0.
if [ "$COUNT" -eq 0 ]; then
  echo "FATAL: found no Mach-O objects under $RELEASE_DIR." >&2
  echo "       The release did not stage, or staged empty. Nothing would be signed," >&2
  echo "       and the bundle would be rejected once per missing signature." >&2
  exit 1
fi

echo "    found $COUNT Mach-O objects to sign"

# The Apple timestamp service is a network dependency in the middle of a build,
# and it flakes. Without --timestamp a signature dies the moment the certificate
# expires (five years) or is revoked (immediately), so dropping it on failure is
# not an option — retry instead.
sign_one() {
  local target="$1"
  local attempt
  for attempt in 1 2 3; do
    if codesign \
      --force \
      --options runtime \
      --timestamp \
      --entitlements "$ENTITLEMENTS" \
      --sign "$APPLE_SIGNING_IDENTITY" \
      "$target" 2>/tmp/codesign_err.$$; then
      return 0
    fi

    if ! grep -qi 'timestamp' /tmp/codesign_err.$$; then
      break
    fi
    echo "    timestamp service flaked on ${target##*/}, retry $attempt/3" >&2
    sleep $((attempt * 5))
  done

  echo "" >&2
  echo "FATAL: codesign failed for $target" >&2
  cat /tmp/codesign_err.$$ >&2
  rm -f /tmp/codesign_err.$$
  return 1
}

for object in "${OBJECTS[@]}"; do
  sign_one "$object"
done
rm -f /tmp/codesign_err.$$

echo "==> Verifying $COUNT signatures"

# Verify every object rather than spot-checking. This loop is cheap and it is
# the only thing standing between a silently-unsigned NIF and a notarization
# rejection round measured in hours.
for object in "${OBJECTS[@]}"; do
  if ! codesign --verify --strict "$object" 2>/tmp/verify_err.$$; then
    echo "FATAL: signature did not verify for $object" >&2
    cat /tmp/verify_err.$$ >&2
    rm -f /tmp/verify_err.$$
    exit 1
  fi
done
rm -f /tmp/verify_err.$$

# Prove the entitlements actually landed on the VM binary, not merely that a
# signature exists. This is the specific assertion that would have caught an
# empty Entitlements.plist, and beam.smp is the binary whose failure is
# invisible until a stranger double-clicks the app.
BEAM="$(find "$RELEASE_DIR" -type f -name 'beam.smp' -print -quit)"
if [ -n "$BEAM" ]; then
  if codesign -d --entitlements - --xml "$BEAM" 2>/dev/null |
    plutil -convert xml1 -o - - 2>/dev/null |
    grep -q 'com.apple.security.cs.allow-jit'; then
    echo "    beam.smp carries allow-jit on its own signature"
  else
    echo "FATAL: beam.smp signed WITHOUT allow-jit." >&2
    echo "       This build would notarize and then fail to launch. Refusing." >&2
    exit 1
  fi
else
  echo "FATAL: no beam.smp found under $RELEASE_DIR — this is not an OTP release." >&2
  exit 1
fi

echo "==> Signed and verified $COUNT Mach-O objects"
