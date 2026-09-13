defmodule BusterClaw.Duty do
  @moduledoc """
  Going on and off duty from the app — THREE_DOORS Phase 2.

  Until 09-13 the only way to go on duty was `./buster-claw on-duty` in a
  terminal: nothing in the web layer called `start_shift`, and the setup wizard
  promised a "Stand down button in the bar at the bottom of the screen" that did
  not exist. This module is what the dock control and the Duty page call, so
  both surfaces make the same checks and record the same audit line.

  ## What "ready" means

  A shift that starts with nothing to receive is a shift that quietly does
  nothing. `readiness/1` names the three things a working shift needs, each with
  where to fix it, so the dock can refuse with a reason instead of a grey button:

  - an agent CLI on PATH (there is nothing to run without one);
  - a healthy Google account — connected, holding a refresh token, and not
    flagged for reconnect (the Duty page's own predicate, moved here so the two
    surfaces cannot disagree);
  - at least one trusted sender. The Manual calls this "the one thing you MUST
    configure", and until now nothing on the on-duty path checked it.

  ## Standing down is the latching one

  `stand_down/1` is `Orchestration.stand_down/1`: it engages the STOP file first
  and then stops the shift, so a run already in flight finishes and no new one
  starts. `Commands.shift_stop` does not latch; the CLI's `off-duty` uses that
  one. The dock and the Duty page use this one.
  """

  alias BusterClaw.{Google, Orchestration, Sentinel, Setup, TrustedSenders}

  @type blocker :: %{key: atom(), label: String.t(), href: String.t()}

  @doc """
  `%{ready?: boolean, blockers: [blocker]}`. Blockers are in fix order.

  `opts[:agent_cli?]` overrides the PATH probe, because the machine running the
  suite may or may not have `claude` installed and a readiness test must not
  depend on that.
  """
  @spec readiness(keyword()) :: %{ready?: boolean(), blockers: [blocker()]}
  def readiness(opts \\ []) do
    agent_cli? = Keyword.get(opts, :agent_cli?, Setup.agent_cli_available?())

    blockers =
      [
        {agent_cli?, %{key: :agent, label: "Install an agent CLI", href: "/settings"}},
        {email_ready?(), %{key: :email, label: "Connect Google", href: "/settings?tab=google"}},
        {TrustedSenders.list_entries() != [],
         %{key: :senders, label: "Add a trusted sender", href: "/"}}
      ]
      |> Enum.reject(fn {ok?, _} -> ok? end)
      |> Enum.map(fn {_, blocker} -> blocker end)

    %{ready?: blockers == [], blockers: blockers}
  end

  @doc "True when at least one Google account can actually receive mail."
  def email_ready? do
    Enum.any?(Google.list_account_summaries(), &account_ready?/1)
  end

  @doc "The Duty page's predicate for one account summary."
  def account_ready?(account) do
    account.enabled and account.has_refresh_token and not account.reconnect_needed
  end

  @doc """
  Start an unattended shift from an app surface. Clears the kill switch first
  (a latched STOP from the last stand-down would otherwise stall the new shift
  at once), and records who asked on the Security feed.

  Refuses with `{:error, {:not_ready, blockers}}` rather than starting a shift
  that can receive nothing.
  """
  @spec go_on_duty(atom(), keyword()) :: {:ok, Orchestration.Shift.t()} | {:error, term()}
  def go_on_duty(source, opts \\ []) when is_atom(source) do
    case readiness(opts) do
      %{ready?: false, blockers: blockers} ->
        {:error, {:not_ready, blockers}}

      %{ready?: true} ->
        Orchestration.clear_kill_switch()

        with {:ok, shift} <- Orchestration.start_shift(unattended: true) do
          Sentinel.observe(:command_invoke, "Shift started by the operator (#{source})", %{
            command: "shift_start",
            source: source,
            shift_id: shift.id
          })

          {:ok, shift}
        end
    end
  end

  @doc "Latch STOP, stop the shift, and say so on the Security feed."
  @spec stand_down(atom()) :: {:ok, term()} | {:error, term()}
  def stand_down(source) when is_atom(source) do
    with {:ok, result} <- Orchestration.stand_down("stood down from the #{source}") do
      Sentinel.observe(:security_block, "Shift stopped by the operator (#{source})", %{
        source: source
      })

      {:ok, result}
    end
  end
end
