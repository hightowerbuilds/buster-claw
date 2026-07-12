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
//   PUBLIC_URL_BASE (optional) exact public URL of this function, only needed
//                   if signature verification fails because req.url differs
//                   from the URL Twilio signed (proxy rewrite)
// SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY are injected automatically.

import { createClient, SupabaseClient } from "jsr:@supabase/supabase-js@2";
import {
  emptyTwiml,
  escapeXml,
  twilioBasicAuth,
  twimlResponse,
  verifyTwilioSignature,
} from "../_shared/twilio.ts";

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
    case "recording":
      return await handleRecording(params, accountSid, authToken);
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
  const greeting = Deno.env.get("GREETING_TEXT") ??
    "You've reached Buster Claw. Leave a message after the beep.";
  const self = selfUrl.split("?")[0];
  // maxLength 120: Twilio only transcribes recordings up to two minutes.
  return twimlResponse(`<Response>
  <Say voice="Polly.Matthew">${escapeXml(greeting)}</Say>
  <Record maxLength="120" playBeep="true" transcribe="true"
    transcribeCallback="${self}?event=transcription"
    recordingStatusCallback="${self}?event=recording"
    recordingStatusCallbackEvent="completed"/>
  <Say voice="Polly.Matthew">No message received. Goodbye.</Say>
</Response>`);
}

async function handleRecording(
  params: Record<string, string>,
  accountSid: string,
  authToken: string,
): Promise<Response> {
  if (params.RecordingStatus && params.RecordingStatus !== "completed") {
    return emptyTwiml();
  }
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
