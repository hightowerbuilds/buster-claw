// Twilio webhook signature verification (X-Twilio-Signature).
// Scheme: base64(HMAC-SHA1(auth_token, url + POST params concatenated as
// key+value, sorted by key)). https://www.twilio.com/docs/usage/security
//
// Shared by voice (Phase 1) and sms (Phase 2) functions. Fail closed: a
// request that doesn't verify never reaches TwiML or the database.

const encoder = new TextEncoder();

export async function verifyTwilioSignature(
  authToken: string,
  url: string,
  params: Record<string, string>,
  signature: string,
): Promise<boolean> {
  if (!signature) return false;
  const payload = url +
    Object.keys(params).sort().map((k) => k + params[k]).join("");
  const key = await crypto.subtle.importKey(
    "raw",
    encoder.encode(authToken),
    { name: "HMAC", hash: "SHA-1" },
    false,
    ["sign"],
  );
  const mac = await crypto.subtle.sign("HMAC", key, encoder.encode(payload));
  const expected = btoa(String.fromCharCode(...new Uint8Array(mac)));
  return timingSafeEqual(expected, signature);
}

function timingSafeEqual(a: string, b: string): boolean {
  const ab = encoder.encode(a);
  const bb = encoder.encode(b);
  if (ab.length !== bb.length) return false;
  let diff = 0;
  for (let i = 0; i < ab.length; i++) diff |= ab[i] ^ bb[i];
  return diff === 0;
}

export function twilioBasicAuth(accountSid: string, authToken: string): string {
  return "Basic " + btoa(`${accountSid}:${authToken}`);
}

export function escapeXml(text: string): string {
  return text
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&apos;");
}

export function twimlResponse(body: string): Response {
  return new Response(
    `<?xml version="1.0" encoding="UTF-8"?>\n${body}`,
    { headers: { "Content-Type": "text/xml" } },
  );
}

export function emptyTwiml(): Response {
  return twimlResponse("<Response/>");
}
