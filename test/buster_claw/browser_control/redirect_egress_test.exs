defmodule BusterClaw.BrowserControl.RedirectEgressTest do
  @moduledoc """
  The second-order half of Finding 6 (07-25), which is the half that leaks.

  `AgentMode` sets `current_host` from the navigation origin, and `Egress`
  resolves the per-host redaction level from that host. While the gate
  authorized only the *requested* URL, a cross-host redirect left `current_host`
  pointing at the previous site — so a host that is `:structure_only` by policy
  (banking, health, government) had its free text read at `:full` simply by
  being redirected to. The gate halting is not enough on its own: the fix is
  that the origin describes where the browser LANDED.
  """
  use BusterClaw.DataCase, async: false

  alias BusterClaw.BrowserControl.{AgentMode, Scope}
  alias BusterClaw.BrowserControl.AgentMode.Trajectory

  # Records navigations and scripts the landing, standing in for Session. The
  # page read answers with free text so the egress level is observable: at
  # :full it survives into the payload, at :structure_only it is dropped.
  defmodule FakeSession do
    use Agent

    @redirects %{
      "https://portal.example.com/sso" => "https://chase.com/accounts/summary"
    }

    def start_link, do: Agent.start_link(fn -> [] end)

    def navigate(pid, url) do
      Agent.update(pid, &[url | &1])
      :ok
    end

    def command(pid, "Runtime.evaluate", %{"expression" => js}) do
      value =
        if js =~ "text: (document.body" or js =~ "innerText: (document.body" do
          %{
            "url" => landed(pid),
            "title" => "Account summary",
            "text" => "Balance 12345 and other private free text",
            "links" => []
          }
        else
          %{"url" => landed(pid), "title" => "Account summary"}
        end

      {:ok, %{"result" => %{"value" => value}}}
    end

    defp landed(pid) do
      requested = Agent.get(pid, &List.first/1)
      Map.get(@redirects, requested, requested)
    end
  end

  setup do
    {:ok, session} = FakeSession.start_link()

    # Both hosts are in scope, so the gate does NOT halt — this test is about
    # what happens on a redirect the scope legitimately allows.
    scope = Scope.new("check the statement", ["example.com", "chase.com"], id: "redirect_egress")

    {:ok, run} =
      AgentMode.start_link(
        scope: scope,
        session: session,
        session_mod: FakeSession,
        clock: fn -> 0 end
      )

    {:ok, :agent_working} = AgentMode.start_run(run)
    %{run: run}
  end

  test "an in-scope redirect moves the egress host to where the browser landed", %{run: run} do
    assert {:ok, origin} = AgentMode.navigate(run, "https://portal.example.com/sso")
    assert origin.host == "chase.com"

    assert {:ok, _payload} = AgentMode.act(run, :read, %{})

    report =
      run
      |> AgentMode.trajectory()
      |> Trajectory.steps()
      |> Enum.find_value(& &1.egress)

    # The level must come from the landed host. chase.com is sensitive-by-default,
    # so free text is dropped; before the fix this reported example.com/:full.
    assert report.host == "chase.com"
    assert report.level == :structure_only
  end

  test "the free text of the landed page never reaches the model payload", %{run: run} do
    assert {:ok, _} = AgentMode.navigate(run, "https://portal.example.com/sso")
    assert {:ok, payload} = AgentMode.act(run, :read, %{})

    refute inspect(payload) =~ "Balance 12345"
  end

  test "the trajectory names the redirect rather than reading as a direct visit", %{run: run} do
    assert {:ok, _} = AgentMode.navigate(run, "https://portal.example.com/sso")

    summary =
      run
      |> AgentMode.trajectory()
      |> Trajectory.steps()
      |> Enum.find_value(&if(&1.type == :navigate, do: &1.summary))

    assert summary =~ "redirect"
    assert summary =~ "https://chase.com/accounts/summary"
  end
end
