// Caller-PIN hashing — the cloud-side half of a contract shared with Elixir.
//
// THE ALGORITHM IS FIXED AND DUPLICATED. `BusterClaw.Telephony.Pins` on the Mac
// hashes a PIN exactly this way when the operator sets it; this function hashes
// the punched digits when a caller enters them. If either side changes, every
// stored PIN stops verifying. Any change must land in both places at once:
//
//     hash = lowercase_hex( sha256( utf8(salt) <> utf8(pin) ) )
//
// - `salt` is the row's random salt (hex string), used verbatim.
// - `pin` is the literal digit string as dialed ("4815"), no normalization.
// - Concatenation is salt-then-pin, bytes, no separator.
//
// A short numeric PIN is low-entropy, so the hash is not the real defense —
// online rate visibility (failed_attempts) and a long-enough PIN are. The hash
// exists so a leak of the phone_pins table does not hand over plaintext PINs.

const encoder = new TextEncoder();

export async function hashPin(salt: string, pin: string): Promise<string> {
  const digest = await crypto.subtle.digest(
    "SHA-256",
    encoder.encode(salt + pin),
  );
  return [...new Uint8Array(digest)]
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

// Constant-time compare of two lowercase-hex digests of equal length.
export function pinHashEquals(a: string, b: string): boolean {
  const ab = encoder.encode(a);
  const bb = encoder.encode(b);
  if (ab.length !== bb.length) return false;
  let diff = 0;
  for (let i = 0; i < ab.length; i++) diff |= ab[i] ^ bb[i];
  return diff === 0;
}
