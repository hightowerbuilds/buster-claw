defmodule BusterClaw.ChartBuilderTest do
  use BusterClaw.DataCase, async: false

  alias BusterClaw.{ChartBuilder, MarketData, Skills}

  test "the chat profile is confined to search, and carries the honesty contract" do
    opts = ChartBuilder.chat_opts()
    prompt = Keyword.fetch!(opts, :append_system_prompt)
    extra = Keyword.fetch!(opts, :extra_cli_args)

    assert Keyword.fetch!(opts, :permission_mode) == "dontAsk"
    assert "--disallowedTools" in extra

    denied = Enum.at(extra, Enum.find_index(extra, &(&1 == "--disallowedTools")) + 1)
    assert denied =~ "Bash"
    assert denied =~ "Read"
    assert denied =~ "Task"

    # WebFetch stays denied even though this profile is the web-capable one. It
    # reaches loopback — see AgentToolPolicy's moduledoc for the 08-03 probe.
    # Deleting this line is how the SSRF path gets re-opened by someone tidying
    # up what looks like an inconsistency.
    assert denied =~ "WebFetch"
    refute denied =~ "WebSearch"

    # The allowlist only stops WebSearch prompting under dontAsk. It confines
    # nothing on its own — the deny list above is the control.
    allowed = Enum.at(extra, Enum.find_index(extra, &(&1 == "--allowedTools")) + 1)
    assert allowed == "WebSearch"

    assert prompt =~ "Drawn by AI"
    assert prompt =~ "Missing dates are gaps"
    assert prompt =~ "CACHED_DATA (JSON)"

    # The prompt used to promise "no broker, web, shell, or filesystem tools",
    # which became false the moment search was granted. The replacement states
    # the split as a rule, and these are the load-bearing halves of it.
    refute prompt =~ "no broker, web, shell, or filesystem tools"
    assert prompt =~ "may not TRANSCRIBE"
    assert prompt =~ "You do NOT have web fetch"
    assert prompt =~ "no broker, shell, or filesystem tools"
  end

  test "cached daily closes are included without a broker read" do
    assert {2, ["AAPL"]} =
             MarketData.store_bars(%{
               "AAPL" => [
                 %{bar_on: ~D[2026-07-30], close: 210.25},
                 %{bar_on: ~D[2026-07-31], close: 212.50}
               ]
             })

    data = ChartBuilder.cached_data()

    assert "AAPL" in data.cached_market_symbols
    assert [first, second] = data.daily_closes["AAPL"]
    assert first == %{day: "2026-07-30", close: 210.25}
    assert second == %{day: "2026-07-31", close: 212.5}
    assert data.portfolio.range == "ALL"
  end

  # The series order is the colourblind-safety mechanism, not a style choice:
  # these five hexes in this sequence were validated against the #111315 canvas
  # (worst adjacent CVD ΔE 16.0, normal-vision ΔE 23.4, all slots >= 3:1).
  # Changing a hex or reordering a slot invalidates that run — re-validate, then
  # update this test deliberately.
  test "the chart-builder playbook carries the validated palette in slot order" do
    # Seed into a scratch workspace: `Skills.ensure/0` never overwrites, so
    # reading the operator's real skills dir would test whatever is stale there.
    root = Path.join(System.tmp_dir!(), "bc_chart_#{System.unique_integer([:positive])}")
    prev = Application.get_env(:buster_claw, :workspace_root)
    Application.put_env(:buster_claw, :workspace_root, root)

    on_exit(fn ->
      Application.put_env(:buster_claw, :workspace_root, prev)
      File.rm_rf(root)
    end)

    assert :ok = Skills.ensure()
    assert {:ok, %{handler_kind: :reference, body: body}} = Skills.load("chart-builder")

    slots = ~w(#ff4407 #00a1ce #9417ff #e10095 #ac9000)

    positions =
      Enum.map(slots, fn hex ->
        assert body =~ hex, "series slot #{hex} missing from the playbook"
        :binary.match(body, hex) |> elem(0)
      end)

    assert positions == Enum.sort(positions), "series slots are out of order in the playbook"

    # The direction pair is reserved, and slot 1 collides with it (ΔE 8.2).
    assert body =~ "#43d17a"
    assert body =~ "#ff5c70"
    assert body =~ "does not use slot 1"

    # Rules that only hold because the SVG is sanitized and has no hover layer.
    assert body =~ "You have no hover layer"
    assert body =~ "One y-axis"
  end
end
