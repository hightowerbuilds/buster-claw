import { handleSms } from "./index.ts";

const encoder = new TextEncoder();
const publicUrl = "https://project.supabase.co/functions/v1/sms";
const token = "test_auth_token";

Deno.test("rejects a bad Twilio signature before inserting", async () => {
  let inserted = false;

  const response = await handleSms(request({ Body: "hello" }, "bad-signature"), {
    authToken: token,
    publicUrlBase: publicUrl,
    insert: async () => {
      inserted = true;
      return null;
    },
  });

  if (response.status !== 403) throw new Error(`expected 403, got ${response.status}`);
  if (inserted) throw new Error("invalid request reached the relay insert");
});

Deno.test("valid SMS is relayed with opt-out metadata and empty TwiML", async () => {
  const params = baseParams({ Body: "STOP", OptOutType: "STOP", NumMedia: "0" });
  const signature = await sign(params);
  let inserted: Record<string, unknown> | undefined;

  const response = await handleSms(request(params, signature, false), {
    authToken: token,
    publicUrlBase: publicUrl,
    insert: async (row) => {
      inserted = row;
      return null;
    },
  });

  if (response.status !== 200) throw new Error(`expected 200, got ${response.status}`);
  if ((await response.text()).includes("<Message")) {
    throw new Error("webhook must not auto-reply");
  }
  if (inserted?.kind !== "sms" || inserted?.direction !== "inbound") {
    throw new Error("wrong relay event kind or direction");
  }
  if (inserted?.twilio_sid !== "SM123" || inserted?.body !== "STOP") {
    throw new Error("message identity or body was not preserved");
  }

  const metadata = inserted?.metadata as Record<string, unknown>;
  if (metadata.opt_out_type !== "STOP" || metadata.num_media !== 0) {
    throw new Error("opt-out metadata was not preserved");
  }
});

function request(
  overrides: Record<string, string>,
  signature: string,
  mergeBase = true,
): Request {
  const params = mergeBase ? baseParams(overrides) : overrides;

  return new Request(publicUrl, {
    method: "POST",
    headers: {
      "content-type": "application/x-www-form-urlencoded",
      "x-twilio-signature": signature,
    },
    body: new URLSearchParams(params),
  });
}

function baseParams(overrides: Record<string, string>): Record<string, string> {
  return {
    MessageSid: "SM123",
    From: "+15035550123",
    To: "+13603646763",
    ...overrides,
  };
}

async function sign(params: Record<string, string>): Promise<string> {
  const payload = publicUrl +
    Object.keys(params).sort().map((key) => key + params[key]).join("");
  const key = await crypto.subtle.importKey(
    "raw",
    encoder.encode(token),
    { name: "HMAC", hash: "SHA-1" },
    false,
    ["sign"],
  );
  const mac = await crypto.subtle.sign("HMAC", key, encoder.encode(payload));
  return btoa(String.fromCharCode(...new Uint8Array(mac)));
}
