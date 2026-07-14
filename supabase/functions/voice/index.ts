// BusterPhone voice webhook — the answering machine.
//
// One function, three Twilio callbacks routed by ?event=:
//   (none)          incoming call  → greeting + <Record>
//   ?event=recording      recording completed → pull .mp3 into Storage,
//                         insert telephony_events row (the row the Mac drains)
//   ?event=transcription  Twilio transcription ready → update the row
//
// The Mac is never in this path. It subscribes to telephony_events via
// Realtime (outbound websocket only) and drains rows on its own schedule.
//
// Env (set via `supabase secrets set`):
//   TWILIO_ACCOUNT_SID / TWILIO_AUTH_TOKEN — verify signatures + fetch media
//   GREETING_TEXT   (optional) override the default greeting
//   PUBLIC_URL_BASE (REQUIRED) exact public URL of this function. Twilio signs
//                   the URL it was configured to call; on Supabase's edge
//                   runtime `req.url` is the internally-rewritten URL, so the
//                   signature never matches and every call 403s (Twilio then
//                   plays an error and hangs up). Verified 07-12: without this
//                   the phone answers and drops. It was documented as optional;
//                   it is not.
// SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY are injected automatically.

import { createClient, SupabaseClient } from "jsr:@supabase/supabase-js@2";
import {
  emptyTwiml,
  escapeXml,
  twilioBasicAuth,
  twimlResponse,
  verifyTwilioSignature,
} from "../_shared/twilio.ts";
import { hashPin, pinHashEquals } from "../_shared/pin.ts";

const TWILIO_API = "https://api.twilio.com";

Deno.serve(async (req) => {
  if (req.method !== "POST") {
    return new Response("method not allowed", { status: 405 });
  }

  const accountSid = Deno.env.get("TWILIO_ACCOUNT_SID");
  const authToken = Deno.env.get("TWILIO_AUTH_TOKEN");
  if (!accountSid || !authToken) {
    return new Response("not configured", { status: 500 });
  }

  const params: Record<string, string> = {};
  for (const [k, v] of await req.formData()) {
    if (typeof v === "string") params[k] = v;
  }

  const url = publicUrl(req);
  const signature = req.headers.get("x-twilio-signature") ?? "";
  if (!(await verifyTwilioSignature(authToken, url, params, signature))) {
    return new Response("forbidden", { status: 403 });
  }

  switch (new URL(req.url).searchParams.get("event")) {
    case "pin":
      return await handlePin(params, url);
    case "recording":
      return await handleRecording(params, accountSid, authToken, url);
    case "transcription":
      return await handleTranscription(params);
    default:
      return answerCall(url);
  }
});

// Twilio signs the exact URL it was configured to call. req.url is normally
// already the public https://<ref>.supabase.co/functions/v1/voice URL; if a
// proxy rewrite ever breaks that, PUBLIC_URL_BASE pins it explicitly.
function publicUrl(req: Request): string {
  const base = Deno.env.get("PUBLIC_URL_BASE");
  if (!base) return req.url;
  return base.replace(/\/+$/, "") + new URL(req.url).search;
}

function answerCall(selfUrl: string): Response {
  const self = selfUrl.split("?")[0];
  const greeting = Deno.env.get("GREETING_TEXT") ??
    "You've reached Buster Claw.";
  // Everyone is prompted, uniformly — we do not reveal whether a given number
  // has a PIN configured. A caller with the code punches it; a caller without
  // one waits out the timeout and falls through to <Record> as a stranger
  // (recorded, playable, but never verified and so never enqueued as work).
  //
  // <Gather> requests `action` only when digits are entered; on timeout it
  // proceeds to the verbs *after* </Gather>. So the fall-through below IS the
  // no-PIN path. finishOnKey="#" lets PIN length vary; timeout gives a caller
  // who is just leaving a message a few seconds to start talking.
  return twimlResponse(`<Response>
  <Gather input="dtmf" finishOnKey="#" timeout="6" numDigits="10"
    action="${self}?event=pin" method="POST">
    <Say voice="Polly.Matthew">${escapeXml(greeting)} If you have an access code, enter it now, then press pound. Otherwise, stay on the line to leave a message.</Say>
  </Gather>
  ${recordVerb(self, false)}
</Response>`);
}

// The <Record> verb, shared by the fall-through (unverified) and PIN-pass
// (verified) paths. The verified flag rides on the recording callback URL, which
// Twilio signs — so the Mac drain can trust it without a lookup, and a caller
// cannot forge it. maxLength 120: Twilio only transcribes up to two minutes.
function recordVerb(self: string, verified: boolean): string {
  // `&amp;`, NOT `&`. This string is interpolated into an XML attribute value,
  // where a raw ampersand is a parse error — Twilio rejects the whole document
  // ("an application error has occurred") and never records. Twilio XML-decodes
  // the attribute before calling the URL, so the actual request is still
  // `?event=recording&verified=1`. This only bites the verified path (the empty
  // flag has no `&`), which is why the PIN-less function never hit it. Do not
  // "simplify" this back to a bare `&`.
  const flag = verified ? "&amp;verified=1" : "";
  return `<Say voice="Polly.Matthew">Leave a message after the beep.</Say>
  <Record maxLength="120" playBeep="true" transcribe="true"
    transcribeCallback="${self}?event=transcription"
    recordingStatusCallback="${self}?event=recording${flag}"
    recordingStatusCallbackEvent="completed"/>
  <Say voice="Polly.Matthew">No message received. Goodbye.</Say>`;
}

// The PIN gate. Digits were entered; decide whether this call is verified, then
// record either way (a wrong code still gets to leave a message — as a stranger).
async function handlePin(
  params: Record<string, string>,
  selfUrl: string,
): Promise<Response> {
  const self = selfUrl.split("?")[0];
  const from = params.From ?? "";
  const digits = params.Digits ?? "";

  const verified = await verifyPin(from, digits);
  return twimlResponse(`<Response>
  ${recordVerb(self, verified)}
</Response>`);
}

// Look up the PIN configured for the *claimed* calling number and compare. A
// match clears the failed-attempt counter; a miss bumps it (brute-force
// telemetry — a spike is visible in the table without trawling logs). Any error
// fails closed to unverified: the gate must never grant trust on a hiccup.
async function verifyPin(from: string, digits: string): Promise<boolean> {
  if (!from || !digits) return false;

  try {
    const supabase = serviceClient();
    const { data, error } = await supabase
      .from("phone_pins")
      .select("pin_hash, salt, failed_attempts")
      .eq("number", from)
      .maybeSingle();

    if (error || !data) return false;

    const candidate = await hashPin(data.salt, digits);
    const ok = pinHashEquals(candidate, data.pin_hash);

    await supabase
      .from("phone_pins")
      .update(
        ok
          ? { failed_attempts: 0, last_verified_at: new Date().toISOString() }
          : { failed_attempts: (data.failed_attempts ?? 0) + 1, last_attempt_at: new Date().toISOString() },
      )
      .eq("number", from);

    return ok;
  } catch {
    return false;
  }
}

async function handleRecording(
  params: Record<string, string>,
  accountSid: string,
  authToken: string,
  selfUrl: string,
): Promise<Response> {
  if (params.RecordingStatus && params.RecordingStatus !== "completed") {
    return emptyTwiml();
  }
  // The PIN verdict, carried on the (Twilio-signed) callback URL. Signature
  // verification already passed for this request, so the query string is
  // authentic — a caller cannot append &verified=1 themselves.
  const verified = new URL(selfUrl).searchParams.get("verified") === "1";
  const auth = twilioBasicAuth(accountSid, authToken);

  // Recording callbacks don't carry From/To — fetch the parent call.
  const callRes = await fetch(
    `${TWILIO_API}/2010-04-01/Accounts/${accountSid}/Calls/${params.CallSid}.json`,
    { headers: { Authorization: auth } },
  );
  if (!callRes.ok) {
    return new Response("call lookup failed", { status: 502 });
  }
  const call = await callRes.json();

  const audioRes = await fetch(`${params.RecordingUrl}.mp3`, {
    headers: { Authorization: auth },
  });
  if (!audioRes.ok) {
    return new Response("recording fetch failed", { status: 502 });
  }
  const audio = new Uint8Array(await audioRes.arrayBuffer());

  const day = new Date().toISOString().slice(0, 10);
  const path = `${day}/voicemail-${params.RecordingSid}.mp3`;
  const supabase = serviceClient();

  const { error: uploadError } = await supabase.storage
    .from("recordings")
    .upload(path, audio, { contentType: "audio/mpeg", upsert: true });
  if (uploadError) {
    return new Response(`upload failed: ${uploadError.message}`, { status: 502 });
  }

  // Upsert on twilio_sid: Twilio retries failed callbacks and this must be
  // idempotent. Non-2xx responses above deliberately trigger those retries.
  const { error: insertError } = await supabase
    .from("telephony_events")
    .upsert({
      direction: "inbound",
      kind: "voicemail",
      from_number: call.from,
      to_number: call.to,
      duration_seconds: parseInt(params.RecordingDuration ?? "0", 10),
      recording_path: path,
      twilio_sid: params.RecordingSid,
      verified,
    }, { onConflict: "twilio_sid" });
  if (insertError) {
    return new Response(`insert failed: ${insertError.message}`, { status: 502 });
  }

  return emptyTwiml();
}

async function handleTranscription(
  params: Record<string, string>,
): Promise<Response> {
  const transcript = params.TranscriptionStatus === "completed"
    ? (params.TranscriptionText ?? "")
    : "(transcription failed)";
  const supabase = serviceClient();

  // Callback ordering isn't guaranteed — the recording row may not exist yet.
  for (let attempt = 0; attempt < 5; attempt++) {
    const { data, error } = await supabase
      .from("telephony_events")
      .update({ transcript })
      .eq("twilio_sid", params.RecordingSid)
      .select("id");
    if (!error && data && data.length > 0) return emptyTwiml();
    await new Promise((resolve) => setTimeout(resolve, 3000));
  }
  return new Response("no matching recording row", { status: 404 });
}

function serviceClient(): SupabaseClient {
  return createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );
}
