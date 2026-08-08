defmodule BusterClaw.AgentToolPolicy do
  @moduledoc """
  The built-in tools a confined agent run is refused — the one place a confined
  surface gets its denial list.

  A leaf on purpose (CODE_QUALITY_REFACTOR_ROADMAP Phase 1): the
  since-deleted `Research` used to share this by calling each other, which made
  them a dependency cycle for the sake of a word list.

  Named explicitly rather than emptied with `--tools ""`, which also silences
  MCP (measured 07-28: `--tools ""` produced 0 broker tool calls in 4 runs).
  A confined run has no business touching the filesystem or the shell;
  `--disallowedTools` is what actually refuses built-ins under `dontAsk` — an
  allowlist alone is approval, not confinement.

  ## Why `WebFetch` is denied to everything, permanently

  **Measured 08-03** (`claude` 2.1.220, `CHART_BUILD_WEB_DATA_ROADMAP` §1.0):
  the CLI's `WebFetch` **resolves and connects from the local machine**. Asked
  for `127.0.0.1:4000` with the BEAM listening it returned `read ECONNRESET`;
  asked for `127.0.0.1:4999` with nothing listening it returned
  `connect ECONNREFUSED` — a pair only a host that can see this machine's
  listening sockets produces.

  So `WebFetch` is a live SSRF path into our own command API, and `URLGuard` —
  which exists precisely to stop a prompt-injected document pivoting to our
  endpoints — is nowhere in it. The only thing between it and `/api/run` today
  is that the tool force-upgrades `http://` to `https://` while our endpoint is
  plain HTTP. That is two implementation details lining up, not a guard: serve
  TLS on loopback, or ship a CLI that drops the upgrade, and the hole opens with
  nothing in this repo changing.

  **`WebFetch` therefore appears in no profile's allowlist and is subtracted by
  no profile.** `web_capable_builtins/0` is `WebSearch` alone, and a test asserts
  it — because a lone missing entry reads as an oversight to whoever finds it
  next, and the reason lives here rather than in the diff.
  """

  # `SlashCommand` is not a tool the CLI recognises — it answered
  # `Permission deny rule "SlashCommand" matches no known tool` during the 08-03
  # probe, while validating every other name here. Kept deliberately rather than
  # tidied away: it denies nothing today, and if a future CLI introduces the
  # tool, removing the line now would silently permit it. A dead deny is free; a
  # missing one is not.
  @denied_builtins ~w(
    Bash BashOutput KillShell
    Edit Write NotebookEdit
    Read Glob Grep
    Task WebFetch WebSearch
    TodoWrite SlashCommand ExitPlanMode
  )

  # The only built-in a profile may subtract. Deliberately not `~w(WebFetch
  # WebSearch)` — see the moduledoc.
  @web_capable_builtins ~w(WebSearch)

  @doc """
  Every built-in tool a confined run is refused.

  This is the strict default: no filesystem, no shell, no web at all.
  """
  def denied_builtins, do: @denied_builtins

  @doc """
  The denial list for a named profile.

  No profile subtracts anything today — `:chartbuild`, the only one that did,
  left with Chart Build on 08-08. The arity stays so a future web-capable
  profile has a place to be declared rather than a new mechanism to invent.
  """
  def denied_builtins(_profile), do: @denied_builtins

  @doc """
  The built-ins a web-capable profile may run — the exact set subtracted by
  a web-capable profile's `denied_builtins/1`, so deny list and allowlist never
  drift apart.

  `WebSearch` only. `WebFetch` is not here and must not be added without
  re-running the §1.0 probe and finding a different answer.
  """
  def web_capable_builtins, do: @web_capable_builtins
end
