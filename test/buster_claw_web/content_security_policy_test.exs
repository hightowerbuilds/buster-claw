defmodule BusterClawWeb.ContentSecurityPolicyTest do
  use BusterClawWeb.ConnCase

  describe "browser CSP header" do
    test "script-src allows our own bundles and nothing inline", %{conn: conn} do
      conn = get(conn, ~p"/")

      # Report-Only by default: our script-src protection ships as the
      # report-only header (it must not enforce without an explicit config flip,
      # which would risk breaking the live socket / Tauri IPC).
      assert [policy] = get_resp_header(conn, "content-security-policy-report-only")

      # Phoenix's put_secure_browser_headers already sets a minimal *enforcing*
      # CSP (base-uri/frame-ancestors only). It must NOT yet enforce script-src —
      # that's exactly the restriction we're validating in report-only first.
      enforcing = get_resp_header(conn, "content-security-policy")
      refute Enum.any?(enforcing, &(&1 =~ "script-src"))

      # script-src is the RCE control. As of 08-03 it is 'self' ALONE — asserted
      # as the whole directive, because "contains 'self'" would still pass with
      # 'unsafe-inline' sitting beside it.
      assert [script_src] = Regex.run(~r/script-src [^;]+/, policy)
      assert script_src == "script-src 'self'"

      # `style-src 'unsafe-inline'` stays and is deliberate: LiveView writes
      # inline style attributes. Styles are not an RCE vector; scripts are.
      assert policy =~ "style-src 'self' 'unsafe-inline'"
      refute policy =~ "unsafe-eval"
      assert policy =~ "object-src 'none'"
      assert policy =~ "base-uri 'self'"
    end

    # The nonce had exactly one consumer — the theme bootstrap — and an unused
    # escape hatch in a policy is strictly weaker than no escape hatch. This is
    # the assertion that stops one being reintroduced "just for this one script".
    test "no nonce is issued, and nothing inline asks for one", %{conn: conn} do
      conn = get(conn, ~p"/")
      [policy] = get_resp_header(conn, "content-security-policy-report-only")
      body = html_response(conn, 200)

      refute policy =~ "nonce-"
      refute body =~ "nonce="
      refute conn.assigns[:csp_nonce]
    end

    # The theme must be on <html> before the body paints, so it cannot be part
    # of the deferred app.js bundle — and it must be a FILE, because an inline
    # script is exactly what the policy above no longer permits.
    test "the theme bootstrap is a render-blocking bundle, not inline or deferred",
         %{conn: conn} do
      body = conn |> get(~p"/") |> html_response(200)

      assert body =~ ~r|<script[^>]*src="/assets/js/theme\.js"|

      theme_tag = Regex.run(~r|<script[^>]*src="/assets/js/theme\.js"[^>]*>|, body) |> hd()

      refute theme_tag =~ "defer",
             "a deferred theme bootstrap lands after first paint and flashes"
    end

    test "the header is stable across requests now that nothing is per-request", %{conn: conn} do
      [p1] = get(conn, ~p"/") |> get_resp_header("content-security-policy-report-only")
      [p2] = get(conn, ~p"/") |> get_resp_header("content-security-policy-report-only")
      assert p1 == p2
    end
  end
end
