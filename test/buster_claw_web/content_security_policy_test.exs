defmodule BusterClawWeb.ContentSecurityPolicyTest do
  use BusterClawWeb.ConnCase

  describe "browser CSP header" do
    test "home page carries a Report-Only CSP with a strict script-src and a nonce", %{conn: conn} do
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

      # script-src is the RCE control: own bundle + a per-request nonce, and
      # crucially NO 'unsafe-inline'.
      assert policy =~ "script-src 'self' 'nonce-"
      refute policy =~ "script-src 'self' 'unsafe-inline'"
      assert policy =~ "object-src 'none'"
      assert policy =~ "base-uri 'self'"

      # The inline theme bootstrap must carry the same nonce the header allows,
      # so a future enforce flip doesn't break theming.
      nonce = Regex.run(~r/script-src 'self' 'nonce-([^']+)'/, policy) |> Enum.at(1)
      assert is_binary(nonce)
      assert html_response(conn, 200) =~ ~s(nonce="#{nonce}")
    end

    test "each response gets a fresh nonce", %{conn: conn} do
      [p1] = get(conn, ~p"/") |> get_resp_header("content-security-policy-report-only")
      [p2] = get(conn, ~p"/") |> get_resp_header("content-security-policy-report-only")
      assert p1 != p2
    end
  end
end
