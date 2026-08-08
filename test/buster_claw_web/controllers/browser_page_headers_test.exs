defmodule BusterClawWeb.BrowserPageHeadersTest do
  @moduledoc """
  The `/browser/*` page scope's security headers, and the property that lets it
  have them at all.

  Until 08-08 this scope had **no pipeline**, so it received no CSP and no
  `nosniff` — the one part of the app `ContentSecurityPolicy`'s
  `script-src 'self'` did not reach, on the surface that renders the most
  outside-shaped content (bookmarks, history, workspace files). It had no
  pipeline because it could not survive one: four pages ran on inline
  `<script>` and two forms on inline `onsubmit=`, all of which `script-src
  'self'` forbids.

  So there are two things to hold, and the second is the one that rots:

  1. the headers are actually sent, and
  2. **no page in this scope carries inline script**, because the day one does,
     CSP is report-only in dev and test and enforced only in prod — so the page
     works everywhere the author looks and is broken in the shipped app.
  """
  use BusterClawWeb.ConnCase, async: true

  alias BusterClaw.Bookmarks
  alias BusterClaw.BrowserHistory

  # Every GET in the `/browser` page scope that returns HTML.
  @pages ["/browser/chrome", "/browser/home", "/browser/pages", "/browser/history"]

  setup do
    # Give home and history something to render, so the assertions run against
    # populated pages rather than empty states that skip half the markup.
    Bookmarks.add("https://example.com", "Example", ["news"])
    BrowserHistory.record("https://example.com", "example.com")
    :ok
  end

  describe "security headers" do
    # Two CSP headers arrive here in dev and test, and that is not a bug:
    # `put_secure_browser_headers` sends its own minimal `base-uri` /
    # `frame-ancestors` policy under the ENFORCE name, and our plug sends the
    # real one under the REPORT-ONLY name (`:csp_mode` is unset outside prod).
    # In prod both use the enforce name and `put_resp_header/3` replaces, so one
    # header ships. Either way the browser enforces the intersection, and the
    # directive that matters is only ever in ours — so assert on the policy that
    # carries `script-src`, not on there being exactly one.
    test "every page carries a script-src policy and nosniff", %{conn: conn} do
      for path <- @pages do
        resp = get(conn, path)

        policies =
          get_resp_header(resp, "content-security-policy") ++
            get_resp_header(resp, "content-security-policy-report-only")

        assert Enum.any?(policies, &(&1 =~ "script-src 'self'")),
               "#{path} sent no policy carrying script-src 'self' — got #{inspect(policies)}"

        assert ["nosniff"] = get_resp_header(resp, "x-content-type-options"),
               "#{path} sent no X-Content-Type-Options: nosniff"
      end
    end

    test "the POST endpoints in the same scope get them too", %{conn: conn} do
      resp = post(conn, "/browser/history?url=https://x.test&label=x")

      assert ["nosniff"] = get_resp_header(resp, "x-content-type-options")
    end
  end

  describe "no inline script survives" do
    # This is the assertion that keeps the headers above applicable. It fails
    # the moment someone adds a <script> block or an on* handler back, rather
    # than in prod, where it would silently be the page that stopped working.
    test "no page ships an inline <script> block", %{conn: conn} do
      for path <- @pages do
        body = conn |> get(path) |> response(200)

        refute body =~ "<script>",
               "#{path} has an inline <script> — CSP is enforced in prod and will block it"
      end
    end

    test "no page ships an inline event handler", %{conn: conn} do
      for path <- @pages, handler <- ~w(onclick onsubmit oninput onload onchange onerror) do
        body = conn |> get(path) |> response(200)

        refute body =~ "#{handler}=",
               "#{path} has an inline #{handler}= handler — CSP will block it in prod"
      end
    end
  end
end
