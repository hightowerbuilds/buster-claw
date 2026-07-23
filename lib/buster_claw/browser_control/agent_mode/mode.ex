defmodule BusterClaw.BrowserControl.AgentMode.Mode do
  @moduledoc """
  The Agent Mode state machine (BROWSER_ENGINE_ROADMAP Phase 4).

  The mode switch is the product: a user who can watch will trust it, a user who
  can't won't. The machine is tiny and pure so the UI (the hazard-accent frame,
  the mode banner) is a faithful projection of one authoritative value rather
  than its own second source of truth.

      idle ─start→ agent_working ─need_human/take_wheel→ awaiting_human
                        │  ↑                                    │
                   complete │ └──────────── resume ─────────────┘
                        ↓  stop/halt                        stop
                       done   stopped   halted            stopped

  `agent_working` is the **only** state in which the agent may act. Every other
  state — including `awaiting_human`, where the human has the wheel — means the
  agent's hands are off. `done`, `stopped`, and `halted` are terminal.
  """

  @modes ~w(idle agent_working awaiting_human done stopped halted)a
  @terminal ~w(done stopped halted)a

  @type t :: :idle | :agent_working | :awaiting_human | :done | :stopped | :halted
  @type event :: :start | :need_human | :take_wheel | :resume | :complete | :stop | :halt

  @doc "All modes."
  def modes, do: @modes

  @doc "Terminal modes — no transition leaves them."
  def terminal?(mode), do: mode in @terminal

  @doc "Only `agent_working` permits the agent to execute an action."
  def acting_allowed?(:agent_working), do: true
  def acting_allowed?(_), do: false

  @doc """
  Apply `event` to `mode`: `{:ok, next}` or `{:error, :invalid_transition}`.
  The legal graph is exhaustive here — an unlisted pair is always an error, so a
  new event or state can't silently do the wrong thing.
  """
  def transition(:idle, :start), do: {:ok, :agent_working}
  def transition(:agent_working, :need_human), do: {:ok, :awaiting_human}
  def transition(:agent_working, :take_wheel), do: {:ok, :awaiting_human}
  def transition(:agent_working, :complete), do: {:ok, :done}
  def transition(:agent_working, :stop), do: {:ok, :stopped}
  def transition(:agent_working, :halt), do: {:ok, :halted}
  def transition(:awaiting_human, :resume), do: {:ok, :agent_working}
  def transition(:awaiting_human, :take_wheel), do: {:ok, :awaiting_human}
  def transition(:awaiting_human, :stop), do: {:ok, :stopped}
  def transition(_mode, _event), do: {:error, :invalid_transition}
end
