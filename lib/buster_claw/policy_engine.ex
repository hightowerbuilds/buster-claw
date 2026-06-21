defmodule BusterClaw.PolicyEngine do
  @moduledoc """
  Declarative authorization for the command surface — the enforcement half of the
  Sentinel layer (Phase 1B).

  Every dispatch (native command *or* composition-skill step) passes through
  `check/1` before it runs. The decision has two layers:

  1. **Baseline** — non-overridable safe defaults that generalize the original
     hardcoded `Commands.authorize/2`:
       - `:agent` / `:mcp` callers may run only `:safe`-tier commands.
       - `:agent_untrusted` may not run a `gated` (outbound/irreversible) command.
     A baseline denial is a `{:confirm, meta}` — the action is *surfaced for human
     approval* (recorded via `Sentinel.Pending`), not hard-refused.

  2. **Operator rules** — `deny` / `allow` lines an operator writes in
     `<workspace>/memory/policy.md`, evaluated *after* the baseline passes. Operator
     rules may only **tighten** (add denials); they can never loosen a baseline
     protection. A matching `deny` is a `{:block, meta}` — a hard refusal (the
     operator said no; there is nothing to confirm).

  ## policy.md format

  Freeform markdown; the parser reads bullet lines of the form:

      - deny <pattern> for <caller>
      - allow <pattern> for <caller>
      - deny <pattern>                # `for any` is implied

  `<pattern>` is a command/skill name or a `*` glob (`gmail_*`, `*_delete`, `*`).
  `<caller>` is `trusted | agent_untrusted | agent | mcp | any`. Among operator
  rules the **most specific pattern wins**; ties break toward `deny`. The default
  action (no matching operator rule) is allow, so an empty file = baseline only,
  which exactly preserves the pre-policy behavior.

  A missing/empty file means no operator rules (safe — baseline still applies).
  """
  require Logger

  alias BusterClaw.Library.Artifact

  @policy_file "policy.md"
  @callers ~w(trusted agent_untrusted agent mcp)a

  @type decision :: :allow | {:confirm, map()} | {:block, map()}

  @type request :: %{
          required(:name) => String.t(),
          required(:caller) => atom(),
          optional(:tier) => :safe | :restricted | nil,
          optional(:gated) => boolean(),
          optional(:source) => :native | :composition
        }

  @doc """
  Authorize a request. Returns `:allow`, `{:confirm, meta}` (baseline gate —
  surface for human approval), or `{:block, meta}` (operator `deny` — hard refusal).
  """
  @spec check(request) :: decision
  def check(%{caller: caller} = request) do
    case baseline(request, caller) do
      :allow -> operator_decision(request)
      confirm -> confirm
    end
  end

  @doc "The parsed operator rules (for inspection/UI). Each: `%{action, pattern, caller}`."
  def rules, do: cached_rules()

  @doc "Re-read `policy.md` from disk into the cache. Call after editing the file."
  def reload do
    :persistent_term.put(cache_key(), load_rules())
    :ok
  end

  # --- baseline (non-overridable) ---------------------------------------

  defp baseline(request, caller) when caller in [:agent, :mcp] do
    if Map.get(request, :tier) == :restricted,
      do: {:confirm, meta(request, :baseline, "restricted command for #{caller} caller")},
      else: :allow
  end

  defp baseline(request, :agent_untrusted) do
    if Map.get(request, :gated, false),
      do: {:confirm, meta(request, :baseline, "gated command for agent_untrusted caller")},
      else: :allow
  end

  defp baseline(_request, _caller), do: :allow

  # --- operator rules ----------------------------------------------------

  defp operator_decision(%{name: name, caller: caller} = request) do
    case most_specific_match(name, caller) do
      %{action: :deny} = rule ->
        {:block, meta(request, :operator, "denied by policy rule: #{describe(rule)}")}

      _ ->
        :allow
    end
  end

  # The rule whose pattern most specifically matches wins; among equally specific
  # patterns a `deny` beats an `allow` (fail safe). Specificity = pattern length
  # with the wildcard discounted, so `gmail_search` (exact) beats `gmail_*`.
  defp most_specific_match(name, caller) do
    cached_rules()
    |> Enum.filter(&rule_matches?(&1, name, caller))
    |> Enum.sort_by(&{specificity(&1.pattern), action_rank(&1.action)}, :desc)
    |> List.first()
  end

  defp rule_matches?(%{pattern: pattern, caller: rule_caller}, name, caller) do
    (rule_caller == :any or rule_caller == caller) and glob_matches?(pattern, name)
  end

  defp glob_matches?(pattern, name) do
    Regex.match?(glob_regex(pattern), name)
  end

  # Compiled glob → anchored regex, cached per distinct pattern so a hot dispatch
  # path doesn't recompile on every check.
  defp glob_regex(pattern) do
    key = {__MODULE__, :glob, pattern}

    case :persistent_term.get(key, :miss) do
      :miss ->
        regex =
          pattern
          |> Regex.escape()
          |> String.replace("\\*", ".*")
          |> then(&Regex.compile!("\\A#{&1}\\z"))

        :persistent_term.put(key, regex)
        regex

      regex ->
        regex
    end
  end

  defp specificity(pattern), do: String.length(String.replace(pattern, "*", ""))

  defp action_rank(:deny), do: 1
  defp action_rank(:allow), do: 0

  defp describe(%{action: action, pattern: pattern, caller: caller}),
    do: "#{action} #{pattern} for #{caller}"

  defp meta(request, source, reason) do
    %{
      command: request.name,
      caller: request.caller,
      tier: Map.get(request, :tier),
      source: Map.get(request, :source, :native),
      policy: source,
      reason: reason
    }
  end

  # --- parsing + cache (mirrors TrustedSenders) -------------------------

  defp load_rules do
    case File.read(policy_path()) do
      {:ok, contents} -> parse_rules(contents)
      _ -> []
    end
  end

  @doc false
  def parse_rules(contents) do
    contents
    # Drop fenced code blocks and HTML-comment blocks first, so illustrative or
    # commented-out example lines are never parsed as live rules.
    |> String.replace(~r/```.*?```/s, "")
    |> String.replace(~r/<!--.*?-->/s, "")
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.flat_map(&parse_line/1)
  end

  defp parse_line(line) do
    line = line |> String.trim_leading("-") |> String.trim() |> strip_comment()

    cond do
      # Documentation/placeholder lines (`deny <pattern> for <caller>`) are never
      # real rules — a command/caller token can't contain angle brackets. Skip
      # them silently so prose and templates don't spam warnings.
      String.contains?(line, ["<", ">"]) ->
        []

      true ->
        parse_rule_tokens(line)
    end
  end

  defp parse_rule_tokens(line) do
    case String.split(line) do
      [action, pattern | rest] when action in ["deny", "allow"] ->
        case parse_caller(rest) do
          {:ok, caller} ->
            [%{action: String.to_atom(action), pattern: pattern, caller: caller}]

          :error ->
            Logger.warning("PolicyEngine: ignoring rule with bad caller: #{inspect(line)}")
            []
        end

      _ ->
        []
    end
  end

  # `<action> <pattern>` (no `for`) implies any caller; `<action> <pattern> for <caller>`.
  defp parse_caller([]), do: {:ok, :any}
  defp parse_caller(["for", caller]), do: normalize_caller(caller)
  defp parse_caller(_other), do: :error

  defp normalize_caller(caller) when is_binary(caller) do
    cond do
      caller in ["any", "all", "*"] -> {:ok, :any}
      (atom = to_known_caller(caller)) != nil -> {:ok, atom}
      true -> :error
    end
  end

  defp to_known_caller(caller) do
    Enum.find(@callers, &(Atom.to_string(&1) == caller))
  end

  defp strip_comment(line) do
    line |> String.split("#", parts: 2) |> List.first() |> String.trim()
  end

  defp cache_key, do: {__MODULE__, :rules, policy_path()}

  defp cached_rules do
    case :persistent_term.get(cache_key(), :miss) do
      :miss ->
        rules = load_rules()
        :persistent_term.put(cache_key(), rules)
        rules

      rules ->
        rules
    end
  end

  defp policy_path, do: Path.join([Artifact.workspace_root(), "memory", @policy_file])

  @doc "The default `policy.md` seed (baseline-only; examples are commented out)."
  def default_policy do
    """
    # Command policy

    Declarative authorization for Buster Claw's command surface. The built-in
    **baseline** always applies and cannot be loosened here:

    - `agent` / `mcp` callers may run only `safe`-tier commands.
    - `agent_untrusted` may not run a gated (outbound/irreversible) command.

    Rules below can only **tighten** that — add denials, never grant more. Each
    rule is a bullet:

    ```
    - deny <pattern> for <caller>
    - allow <pattern> for <caller>
    ```

    `<pattern>` is a command or skill name, or a `*` glob (`gmail_*`, `*_delete`).
    `<caller>` is one of: trusted, agent_untrusted, agent, mcp, any. The most
    specific pattern wins; ties favor deny. Examples (commented out):

    <!--
    - deny *_delete for any
    - deny gmail_* for agent_untrusted
    - allow gmail_search for agent_untrusted
    -->
    """
  end
end
