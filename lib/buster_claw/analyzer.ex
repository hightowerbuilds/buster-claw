defmodule BusterClaw.Analyzer do
  @moduledoc """
  Self-improvement, detection half (Phase 3). Reads recent `command_invoke` audit
  events, groups them into sessions (consecutive commands by the same caller within
  a time gap), and counts repeated consecutive command sub-sequences. Any sequence
  seen at least `:analyzer_min_occurrences` times is filed as a **proposed**
  composition skill via `Skills.Suggestions` — never auto-enabled.

  Heuristic-only (no LLM): "ran A→B→C 12× this week" → propose a skill A→B→C.
  """
  import Ecto.Query

  require Logger

  alias BusterClaw.Repo
  alias BusterClaw.Sentinel.Event
  alias BusterClaw.Skills.Suggestions

  @doc """
  Scan recent command history and file suggestions for repeated sequences. Returns
  `%{scanned: event_count, filed: [%{signature, occurrences}]}`.
  """
  def scan(opts \\ []) do
    min_occ = opt(opts, :analyzer_min_occurrences, 3)
    events = recent_command_events(opt(opts, :analyzer_event_limit, 500))

    counts =
      events
      |> sessions(opt(opts, :analyzer_session_gap_s, 180))
      |> Enum.flat_map(&ngrams(&1, opt(opts, :analyzer_max_ngram, 3)))
      |> Enum.frequencies()

    filed =
      counts
      |> Enum.filter(fn {_seq, n} -> n >= min_occ end)
      |> Enum.sort_by(fn {_seq, n} -> n end, :desc)
      |> Enum.flat_map(fn {seq, n} -> file(seq, n) end)

    %{scanned: length(events), filed: filed}
  end

  # --- reading -----------------------------------------------------------

  # `command_invoke` events carry the command name + caller in metadata. Pull the
  # most recent N (newest-first) and flip to chronological for sequence detection.
  defp recent_command_events(limit) do
    Event
    |> where([e], e.category == "command_invoke")
    |> order_by([e], desc: e.inserted_at, desc: e.id)
    |> limit(^limit)
    |> Repo.all()
    |> Enum.reverse()
    |> Enum.flat_map(&to_step/1)
  end

  # Keep only events that name a real command (skip skill-invoke events, which carry
  # `skill` not `command`, and the Dispatcher's run-level events, which carry neither
  # — we don't propose skills made of skills or of opaque runs).
  defp to_step(%Event{metadata: %{"command" => cmd}} = e) when is_binary(cmd),
    do: [%{command: cmd, caller: e.caller, at: e.inserted_at}]

  defp to_step(_event), do: []

  # --- sessionizing ------------------------------------------------------

  # Split the chronological stream into sessions: a new session starts when the
  # caller changes or the gap since the previous command exceeds `gap_s` seconds.
  defp sessions(steps, gap_s) do
    steps
    |> Enum.chunk_while(
      nil,
      fn step, acc -> chunk(step, acc, gap_s) end,
      fn
        nil -> {:cont, []}
        {cmds, _} -> {:cont, Enum.reverse(cmds), nil}
      end
    )
  end

  defp chunk(step, nil, _gap_s), do: {:cont, {[step.command], step}}

  defp chunk(step, {cmds, prev}, gap_s) do
    if step.caller == prev.caller and seconds_between(prev.at, step.at) <= gap_s do
      {:cont, {[step.command | cmds], step}}
    else
      {:cont, Enum.reverse(cmds), {[step.command], step}}
    end
  end

  defp seconds_between(a, b), do: abs(DateTime.diff(b, a, :second))

  # --- n-grams -----------------------------------------------------------

  # Every consecutive sub-sequence of length 2..max within a session that has at
  # least two *distinct* commands (a single command repeated is a loop, not a
  # composition worth proposing).
  defp ngrams(session, max_n) do
    for n <- 2..max_n,
        window <- chunk_every_consecutive(session, n),
        length(window) == n,
        Enum.uniq(window) |> length() >= 2,
        do: window
  end

  defp chunk_every_consecutive(list, n) when length(list) < n, do: []
  defp chunk_every_consecutive(list, n), do: Enum.chunk_every(list, n, 1, :discard)

  # --- filing ------------------------------------------------------------

  defp file(commands, occurrences) do
    signature = Enum.join(commands, ">")

    attrs = %{
      signature: signature,
      name: gen_name(commands),
      description: "Repeated sequence: #{Enum.join(commands, " → ")} (seen #{occurrences}×).",
      steps: Enum.map(commands, &%{"command" => &1}),
      occurrences: occurrences
    }

    case Suggestions.record(attrs) do
      {:ok, _suggestion} ->
        [%{signature: signature, occurrences: occurrences}]

      {:error, reason} ->
        Logger.warning("Analyzer could not file #{signature}: #{inspect(reason)}")
        []
    end
  end

  # A valid, readable skill name from the sequence, e.g. ["gmail_read","drive_upload"]
  # → "auto-gmail-read-drive-upload" (sanitized, length-capped).
  defp gen_name(commands) do
    body =
      commands
      |> Enum.join("-")
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")
      |> String.slice(0, 60)

    "auto-" <> body
  end

  defp opt(opts, key, default) do
    Keyword.get(opts, key, Application.get_env(:buster_claw, key, default))
  end
end
