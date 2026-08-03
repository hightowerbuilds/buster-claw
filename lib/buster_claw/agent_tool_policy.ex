defmodule BusterClaw.AgentToolPolicy do
  @moduledoc """
  The built-in tools a confined agent run is refused — the one list `Trading`,
  `Research`, and `TradingOrder` all deny from.

  A leaf on purpose (CODE_QUALITY_REFACTOR_ROADMAP Phase 1): `Trading` and
  `Research` used to share this by calling each other, which made them a
  dependency cycle for the sake of a word list.

  Named explicitly rather than emptied with `--tools ""`, which also silences
  MCP (measured 07-28: `--tools ""` produced 0 broker tool calls in 4 runs).
  A confined run has no business touching the filesystem, the shell, or the
  web; `--disallowedTools` is what actually refuses built-ins under `dontAsk`
  — an allowlist alone is approval, not confinement.
  """

  @denied_builtins ~w(
    Bash BashOutput KillShell
    Edit Write NotebookEdit
    Read Glob Grep
    Task WebFetch WebSearch
    TodoWrite SlashCommand ExitPlanMode
  )

  @doc "Every built-in tool a confined run is refused."
  def denied_builtins, do: @denied_builtins
end
