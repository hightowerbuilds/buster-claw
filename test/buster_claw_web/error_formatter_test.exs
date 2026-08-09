defmodule BusterClawWeb.ErrorFormatterTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias BusterClawWeb.ErrorFormatter

  describe "format/1 known shapes" do
    test "Ecto.Changeset → field-level error string" do
      changeset =
        {%{}, %{url: :string, name: :string}}
        |> Ecto.Changeset.cast(%{}, [:url, :name])
        |> Ecto.Changeset.validate_required([:url, :name])

      result = ErrorFormatter.format(changeset)
      assert result =~ "url"
      assert result =~ "can't be blank"
      assert result =~ "name"
    end

    test "well-known atoms get humanized strings" do
      assert ErrorFormatter.format(:not_found) == "not found"
      assert ErrorFormatter.format(:unauthorized) == "unauthorized"
      assert ErrorFormatter.format(:econnrefused) == "connection refused"
      assert ErrorFormatter.format(:nxdomain) == "domain not found"
    end

    test "unknown atom is humanized rather than inspected" do
      assert ErrorFormatter.format(:some_weird_atom) == "some weird atom"
    end

    test "{:bad_status, n} returns HTTP status" do
      assert ErrorFormatter.format({:bad_status, 502}) == "HTTP 502"
      assert ErrorFormatter.format({:bad_status, 500, "body"}) == "HTTP 500"
      assert ErrorFormatter.format({:http_error, 404, "body"}) == "HTTP 404"
    end

    test "Google OAuth errors surface safe provider details" do
      assert ErrorFormatter.format(
               {:google_oauth_error, 401,
                %{"error" => "invalid_client", "error_description" => "Unauthorized"}}
             ) ==
               "Google OAuth HTTP 401: invalid client. Re-check that the client ID and client secret came from the same Desktop app OAuth client. Google said: Unauthorized"
    end

    test "{:missing_config, key} surfaces the missing key" do
      assert ErrorFormatter.format({:missing_config, :api_key}) == "missing config: api_key"
    end

    test "binary passes through" do
      assert ErrorFormatter.format("plain message") == "plain message"
    end

    test "Req.TransportError reason is formatted, full struct is not" do
      err = %{__struct__: Req.TransportError, reason: :econnrefused}
      assert ErrorFormatter.format(err) == "transport error: connection refused"
    end
  end

  describe "format/1 unknown shapes" do
    test "returns generic message and logs the term" do
      weird = %{some: "weird", nested: %{shape: 1}}

      {result, log} =
        with_log([level: :warning], fn ->
          ErrorFormatter.format(weird)
        end)

      assert result == "unexpected error"
      assert log =~ "[error_formatter] unknown error shape"
    end

    # FIELD-FOUND 08-08 (browser-control book errand). The desktop JS bridge
    # POSTs a real error string on failure; `browser_command_controller` wraps
    # it as `{:browser_failed, msg}` — deliberately truncated to 200 chars for
    # exactly this purpose. There was no clause for that tuple, so every
    # desktop-side browser failure hit the fallback and became the same
    # five-syllable shrug, indistinguishable from every other one. The message
    # survived only as a :warning on stdout, which under `tauri dev` is terminal
    # scrollback rather than a file. It cost the operator a multi-probe
    # investigation and a detour onto Agent Mode.
    test "a desktop bridge failure keeps its diagnosis instead of collapsing" do
      assert ErrorFormatter.format({:browser_failed, "Target closed"}) ==
               "browser: Target closed"
    end

    test "a bridge failure is not logged as an unknown shape" do
      {result, log} =
        with_log([level: :warning], fn ->
          ErrorFormatter.format({:browser_failed, "no active tab"})
        end)

      assert result == "browser: no active tab"

      refute log =~ "unknown error shape",
             "the clause matched but the fallback still ran"
    end

    test "does not leak Authorization-style secrets into the formatted output" do
      weird = %{
        __struct__: SomeUnknownErrorStruct,
        headers: [{"authorization", "Bearer SUPER_SECRET_TOKEN"}]
      }

      result =
        with_log([level: :warning], fn ->
          ErrorFormatter.format(weird)
        end)
        |> elem(0)

      refute result =~ "SUPER_SECRET_TOKEN"
      refute result =~ "authorization"
      assert result == "unexpected error"
    end
  end
end
