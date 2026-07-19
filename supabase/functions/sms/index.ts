// BusterPhone SMS webhook.
//
// Twilio signs the exact configured webhook URL. Supabase may expose an
// internally-rewritten req.url, so PUBLIC_SMS_URL_BASE should be set to the
// public function URL used in the Messaging Service webhook configuration.
//
// Env (set via `supabase secrets set`):
//   TWILIO_AUTH_TOKEN   verifies X-Twilio-Signature
//   PUBLIC_SMS_URL_BASE exact public URL of this function (recommended)
// SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY are injected automatically.

// This function deliberately returns empty TwiML. Replies are explicit,
// policy-gated outbound actions on the Mac; Twilio handles opt-out responses.

import { createClient } from "jsr:@supabase/supabase-js@2";
import {
  emptyTwiml,
  verifyTwilioSignature,
} from "../_shared/twilio.ts";

type RelayRow = {
  direction: "inbound";
  kind: "sms";
  from_number: string;
  to_number: string;
  body: string;
  twilio_sid: string;
  metadata: Record<string, string | number>;
};

type HandlerOptions = {
  authToken?: string;
  publicUrlBase?: string;
  insert?: (row: RelayRow) => Promise<{ message: string } | null>;
};

export async function handleSms(
  req: Request,
  options: HandlerOptions = {},
): Promise<Response> {
  if (req.method !== "POST") {
    return new Response("method not allowed", { status: 405 });
  }

  const authToken = options.authToken ?? Deno.env.get("TWILIO_AUTH_TOKEN");
  if (!authToken) {
    return new Response("not configured", { status: 500 });
  }

  const params: Record<string, string> = {};
  for (const [key, value] of await req.formData()) {
    if (typeof value === "string") params[key] = value;
  }

  const signature = req.headers.get("x-twilio-signature") ?? "";
  const signedUrl = publicUrl(req, options.publicUrlBase);
  if (!(await verifyTwilioSignature(authToken, signedUrl, params, signature))) {
    return new Response("forbidden", { status: 403 });
  }

  const messageSid = params.MessageSid || params.SmsSid;
  if (!messageSid || !params.From || !params.To) {
    return new Response("missing required message fields", { status: 422 });
  }

  const metadata: Record<string, string | number> = {};
  if (params.OptOutType) metadata.opt_out_type = params.OptOutType;
  if (params.NumMedia) metadata.num_media = parseInt(params.NumMedia, 10) || 0;

  // Twilio retries failed webhooks. Upsert by MessageSid makes the relay write
  // idempotent while preserving the original receive timestamp.
  const row: RelayRow = {
    direction: "inbound",
    kind: "sms",
    from_number: params.From,
    to_number: params.To,
    body: params.Body ?? "",
    twilio_sid: messageSid,
    metadata,
  };

  const error = await (options.insert ?? insertRelay)(row);

  if (error) {
    return new Response(`insert failed: ${error.message}`, { status: 502 });
  }

  return emptyTwiml();
}

async function insertRelay(row: RelayRow): Promise<{ message: string } | null> {
  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  const { error } = await supabase
    .from("telephony_events")
    .upsert(row, { onConflict: "twilio_sid", ignoreDuplicates: true });

  return error;
}

function publicUrl(req: Request, configuredBase?: string): string {
  const base = configuredBase ?? Deno.env.get("PUBLIC_SMS_URL_BASE");
  if (!base) return req.url;
  return base.replace(/\/+$/, "") + new URL(req.url).search;
}

if (import.meta.main) Deno.serve((req) => handleSms(req));
