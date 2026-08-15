defmodule BusterClawWeb.DevMicProbeController do
  @moduledoc """
  **Development-only diagnostic for STUDIO_ROADMAP V.4a.** Its route lives inside
  the `dev_routes` compile-time block in `router.ex`, so it does not exist in a
  release at all — this module compiles there and is unreachable.

  ## What it answers, and why it had to be a page rather than a test

  V.4a asks whether `getUserMedia` works inside this shell, and V.5 wants to add
  `NSMicrophoneUsageDescription` plus the audio-input entitlement to make it
  possible. Before touching either — both are signing-affecting — this measures
  what the CURRENT build does, because the code read that prompted the work
  turned up something the roadmap did not know:

  **`Info.plist` claims Tauri's WKUIDelegate does not implement
  `requestMediaCapturePermissionForOrigin`, so capture is denied before TCC is
  consulted. That is stale.** wry 0.55.1 implements it at
  `wkwebview/class/wry_web_view_ui_delegate.rs:126` and calls the decision
  handler with `WKPermissionDecision::Grant` **unconditionally, for every origin,
  with no prompt**. Nothing in `desktop/tauri/src/` overrides it, and the
  embedded browser builds its webviews from the same class
  (`WebviewBuilder` + `WebviewUrl::External`).

  So the per-origin gate this app relies on does not exist, and the only thing
  currently stopping capture is that the app declares no microphone usage and
  carries no entitlement — an OS-level refusal, not an app-level one. Adding
  them is therefore not merely groundwork: it is the step that makes wry's
  grant-everything reachable, including for pages the embedded browser visits.

  A `Permissions-Policy` header cannot close that: the browser loads external
  URLs directly, so this app's response headers never touch them.

  ## Read the result in THREE places, because they disagree by design

  * **Chrome at `localhost:4000`** — Chrome's own permission model, not this
    app's. Useful only as a control: it proves the page itself is correct.
  * **The Tauri window (`cargo tauri dev`)** — a real WKWebView, but *unsigned*
    and with no hardened runtime, so TCC treats it differently from a release.
  * **A webview inside the in-app browser** — the case that matters for the
    security question, since it is an arbitrary-page surface sharing one
    delegate with the app's own UI.

  The packaged, signed, notarized build remains the only authority for what
  ships. This narrows the question; it does not close it.
  """
  use BusterClawWeb, :controller

  def show(conn, _params) do
    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, page())
  end

  # Inline script, deliberately: `csp_mode` is `:enforce` only in prod
  # (config/prod.exs) and this route cannot exist there. Nothing here is a
  # pattern to copy into a shipping page — see the browser pages, which were
  # migrated off inline script for exactly that reason.
  defp page do
    """
    <!doctype html>
    <html><head><meta charset="utf-8"><title>Mic probe — V.4a</title>
    <style>
      body { font: 14px ui-monospace, Menlo, monospace; background:#121212; color:#f4f1ea;
             margin:0; padding:2rem; line-height:1.6; }
      h1 { font-size:1rem; letter-spacing:.15em; text-transform:uppercase; color:#ff4d1c; }
      .row { padding:.4rem 0; border-bottom:1px solid #2e2e2e; }
      .k { color:#9d9a92; display:inline-block; min-width:19rem; }
      .ok { color:#7dc98f; } .bad { color:#ff4d1c; } .warn { color:#e8b64c; }
      button { font:inherit; background:#ff4d1c; color:#121212; border:0;
               padding:.6rem 1.2rem; margin:1.2rem 0; cursor:pointer; font-weight:700; }
      #out { white-space:pre-wrap; }
    </style></head><body>
    <h1>Microphone probe — STUDIO V.4a</h1>
    <p>Nothing opens the microphone until you press the button.</p>
    <div id="pre"></div>
    <button id="go">Request the microphone</button>
    <div id="out"></div>
    <script>
      const pre = document.getElementById("pre");
      const out = document.getElementById("out");
      const row = (el, k, v, cls) =>
        el.insertAdjacentHTML("beforeend",
          '<div class="row"><span class="k">' + k + '</span><span class="' +
          (cls || "") + '">' + v + '</span></div>');

      // Measured BEFORE any request, so the "labels are empty until permission
      // is granted" gotcha (V.6) is visible as a before/after difference.
      row(pre, "isSecureContext", String(window.isSecureContext),
          window.isSecureContext ? "ok" : "bad");
      row(pre, "navigator.mediaDevices", String(!!navigator.mediaDevices),
          navigator.mediaDevices ? "ok" : "bad");
      row(pre, "getUserMedia present",
          String(!!(navigator.mediaDevices && navigator.mediaDevices.getUserMedia)),
          (navigator.mediaDevices && navigator.mediaDevices.getUserMedia) ? "ok" : "bad");
      row(pre, "userAgent", navigator.userAgent);

      if (navigator.mediaDevices && navigator.mediaDevices.enumerateDevices) {
        navigator.mediaDevices.enumerateDevices().then(function (ds) {
          const ins = ds.filter(function (d) { return d.kind === "audioinput"; });
          const named = ins.filter(function (d) { return d.label && d.label.length; });
          row(pre, "audioinput devices (before)", String(ins.length));
          row(pre, "…of those with labels", String(named.length),
              named.length ? "ok" : "warn");
        });
      }

      document.getElementById("go").addEventListener("click", function () {
        out.innerHTML = "";
        row(out, "requesting…", "getUserMedia({audio:true})");
        const t0 = performance.now();

        navigator.mediaDevices.getUserMedia({ audio: true }).then(function (stream) {
          const ms = Math.round(performance.now() - t0);
          const track = stream.getAudioTracks()[0];
          const settings = (track && track.getSettings) ? track.getSettings() : {};
          let rate = settings.sampleRate;
          try {
            // The authority on rate is the AudioContext, not the track: WebKit
            // often reports no sampleRate in track settings.
            const ctx = new (window.AudioContext || window.webkitAudioContext)();
            rate = rate || ctx.sampleRate;
            ctx.close();
          } catch (e) { /* leave rate as whatever the track gave */ }

          row(out, "RESULT", "GRANTED", "ok");
          row(out, "elapsed", ms + " ms  " +
              (ms < 150 ? "(no prompt shown — auto-granted)" : "(a prompt probably appeared)"),
              ms < 150 ? "warn" : "");
          row(out, "sample rate", String(rate || "unknown"), "ok");
          row(out, "track label", (track && track.label) || "(none)");
          row(out, "settings", JSON.stringify(settings));
          stream.getTracks().forEach(function (t) { t.stop(); });
          row(out, "stream", "stopped again immediately", "ok");

          navigator.mediaDevices.enumerateDevices().then(function (ds) {
            const named = ds.filter(function (d) {
              return d.kind === "audioinput" && d.label && d.label.length;
            });
            row(out, "labelled inputs (after)", String(named.length), "ok");
          });
        }).catch(function (err) {
          row(out, "RESULT", "REFUSED", "bad");
          row(out, "error.name", err && err.name ? err.name : "(none)", "bad");
          row(out, "error.message", err && err.message ? err.message : "(none)");
          row(out, "read as",
              err && err.name === "NotAllowedError"
                ? "denied by TCC or by the webview delegate"
                : err && err.name === "NotFoundError"
                  ? "no input device visible to this process"
                  : "see the name above");
        });
      });
    </script>
    </body></html>
    """
  end
end
