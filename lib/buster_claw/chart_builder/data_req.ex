defmodule BusterClaw.ChartBuilder.DataReq do
  @moduledoc """
  The channel Chart Build asks the app for numbers through
  (`CHART_BUILD_WEB_DATA_ROADMAP` Phase 2).

  The model may search the web but may not plot what it reads there. This is the
  other half of that rule: when it needs figures, it emits a fenced ` ```datareq `
  block naming a source and a series, the app fetches them through a real
  adapter, and the result comes back as the **next turn** carrying `source` and
  `as_of`. Only numbers that arrive this way (or from `CACHED_DATA`) are
  plottable.

      ```datareq
      {"source": "bls", "series": "CUUR0000SA0", "start_year": 2020}
      ```

  ## Why a turn, and not a fresh system prompt

  `Chat.ensure_started/2` captures its options once, at process start, and the
  `--resume` session id lives in that process. Re-injecting data by restarting
  the chat would therefore **discard the conversation** — the model would lose
  the request it just made. Delivering as a turn threads through `--resume`
  untouched, which is why this mirrors `SvgViewer`'s fence-in-the-message design
  rather than inventing a side channel.

  ## Discipline, all of it enforced here rather than requested in a prompt

    * **Allowlisted sources only.** `sources/0` is the whole surface. An unknown
      name is refused with the list of real ones, never fetched.
    * **Bounded.** `@max_observations` per delivery, and the delivery says so
      when it truncates. Every number transits a language model, so payload size
      is a correctness parameter, not a performance one (the rule `Trading`
      states for its own parsers).
    * **One request per message.** Extra blocks are refused with a note, so a
      model cannot fan out.
    * **Failure is a real answer.** Upstream down, unknown series, empty result —
      each comes back as its own reason. A model told "unavailable" stops; a
      model told nothing invents.

  The loop guard lives in the caller (`TradingLive`), because only the caller
  knows what has already been delivered in this conversation.
  """

  alias BusterClaw.Finance.BLS
  alias BusterClaw.Finance.Sources

  @fence ~r/```datareq\s*(.*?)```/s
  @max_observations 400

  # Which registry keys this channel can actually FETCH. Two conditions, and
  # both matter: the source needs an adapter here, and `Sources` must call it
  # `:verified`. The registry lists far more than this — candidates nobody has
  # called, a `:blocked` FRED, an `:unsanctioned` Yahoo — and listing is not
  # permission. A source becomes fetchable by someone writing an adapter and
  # adding a line here, never by being described.
  @adapters %{"bls" => BLS}

  @doc """
  The fetchable sources, keyed, joined to their registry entry.

  Derived from `Sources` rather than duplicated, so a source cannot be
  documented one way here and another way there.
  """
  def sources do
    for %{key: key} = source <- Sources.verified(),
        Map.has_key?(@adapters, key),
        into: %{},
        do: {key, source}
  end

  @doc "Source keys a request may name."
  def source_keys, do: sources() |> Map.keys() |> Enum.sort()

  @doc "Max observations a single delivery carries."
  def max_observations, do: @max_observations

  @doc """
  Split assistant text into its prose and any `datareq` blocks.

  Mirrors `SvgViewer.extract/1`: `{clean_text, requests}`. A malformed or
  unauthorised block still comes back as a request — as `{:invalid, reason}` —
  because the model needs to be TOLD it was malformed. Dropping it silently is
  how a conversation deadlocks with the model waiting for data that will never
  arrive.
  """
  def extract(text) when is_binary(text) do
    requests =
      @fence
      |> Regex.scan(text, capture: :all_but_first)
      |> Enum.map(fn [body] -> parse(body) end)

    clean = @fence |> Regex.replace(text, "") |> String.trim()
    {clean, requests}
  end

  def extract(other), do: {other, []}

  @doc "A stable signature for a request, so a caller can spot a repeat."
  def signature({:invalid, reason}), do: "invalid:#{inspect(reason)}"

  def signature(%{source: source, series: series, start_year: from, end_year: to}),
    do: "#{source}:#{series}:#{from}:#{to}"

  @doc """
  Parse one block body into a validated request, or `{:invalid, reason}`.
  """
  def parse(body) when is_binary(body) do
    case body |> String.trim() |> Jason.decode() do
      {:ok, json} when is_map(json) -> validate(json)
      {:ok, _other} -> {:invalid, :not_an_object}
      {:error, _reason} -> {:invalid, :malformed_json}
    end
  end

  defp validate(json) do
    source = json |> Map.get("source") |> to_string() |> String.trim() |> String.downcase()
    series = json |> Map.get("series") |> to_string() |> String.trim()

    cond do
      not Map.has_key?(sources(), source) -> {:invalid, unfetchable(source)}
      series == "" -> {:invalid, :missing_series}
      true -> {:ok_request, source, series, json}
    end
    |> case do
      {:ok_request, source, series, json} ->
        %{
          source: source,
          series: series,
          start_year: year(Map.get(json, "start_year")),
          end_year: year(Map.get(json, "end_year"))
        }

      invalid ->
        invalid
    end
  end

  # "In the registry but not fetchable" and "never heard of it" are different
  # answers and deserve different refusals. A model told only "unknown source"
  # after naming `bea` reasonably concludes it got the spelling wrong and tries
  # again; told the entry exists and why it is not fetchable, it stops guessing
  # and reports the real limit to the operator. The registry documents far more
  # than this channel can reach, on purpose — that is what makes it a record of
  # decisions rather than a to-do list.
  defp unfetchable(name) do
    case Sources.get(name) do
      %{status: status} -> {:unfetchable_source, name, status}
      nil -> {:unknown_source, name}
    end
  end

  defp year(nil), do: nil
  defp year(value) when is_integer(value), do: value

  defp year(value) do
    case value |> to_string() |> Integer.parse() do
      {parsed, _rest} -> parsed
      :error -> nil
    end
  end

  @doc """
  Fetch a validated request. Returns `{:ok, payload}` or `{:error, reason}`.

  `opts` are passed to the adapter (the `:req_options` test seam).
  """
  def fulfill(%{source: "bls"} = request, opts \\ []) do
    fetch_opts =
      opts
      |> maybe_put(:start_year, request.start_year)
      |> maybe_put(:end_year, request.end_year)

    case BLS.observations(request.series, fetch_opts) do
      {:ok, result} -> {:ok, bound(result)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  # Keep the TAIL when truncating: a chart of a long series wants the recent end,
  # and silently dropping the recent end would be the wrong half. The count of
  # what went is carried so the delivery can say it — a bounded payload that
  # looks complete is the failure this whole roadmap is written against.
  defp bound(%{observations: observations} = result) do
    total = length(observations)

    if total > @max_observations do
      result
      |> Map.put(:observations, Enum.take(observations, -@max_observations))
      |> Map.put(:truncated, total - @max_observations)
    else
      Map.put(result, :truncated, 0)
    end
  end

  @doc """
  Render the turn that goes back to the model.

  Always returns a string: a success carries the data plus its provenance, and
  every failure carries a reason the model can act on. There is no path here
  that returns nothing, because silence is the one response that makes a model
  invent.
  """
  def deliver({:ok, payload}) do
    """
    [buster-claw data delivery — #{payload.source}]

    These figures were fetched by the application, not by you. They are
    plottable. Put the source and the as-of in the chart's subtitle, and label
    the span under `covered` — never the span that was requested.
    #{truncation_line(payload)}#{aggregate_line(payload)}
    ```json
    #{Jason.encode!(payload_json(payload))}
    ```
    """
    |> String.trim()
  end

  def deliver({:error, reason}), do: failure_text(reason)

  @doc "The turn for a block the app would not even attempt."
  def refuse({:invalid, {:unknown_source, name}}) do
    """
    [buster-claw data delivery — refused]

    "#{name}" is not a source this application can fetch. Nothing was requested.

    Available sources: #{Enum.join(source_keys(), ", ")}.
    #{source_lines()}
    Ask again naming one of those, or tell the operator plainly that the data
    they want has no source wired up yet.
    """
    |> String.trim()
  end

  def refuse({:invalid, {:unfetchable_source, name, status}}) do
    """
    [buster-claw data delivery — refused]

    "#{name}" is a source this application knows about, but it is
    #{status_reason(status)} Nothing was requested, and nothing will be until
    that changes — this is not something you can retry into working.

    Available sources: #{Enum.join(source_keys(), ", ")}.
    #{source_lines()}
    Either ask again naming one of those, or tell the operator that the numbers
    they want come from #{name} and that we cannot fetch it. Naming the reason is
    more useful to them than a chart drawn from somewhere else.
    """
    |> String.trim()
  end

  def refuse({:invalid, :missing_series}),
    do:
      "[buster-claw data delivery — refused]\n\nThe request named no `series`. " <>
        "Include the publisher's series id, e.g. " <>
        ~s({"source": "bls", "series": "CUUR0000SA0"}.)

  def refuse({:invalid, :malformed_json}),
    do:
      "[buster-claw data delivery — refused]\n\nThat datareq block was not valid " <>
        "JSON, so nothing was fetched. Emit one JSON object inside the fence."

  def refuse({:invalid, :not_an_object}),
    do:
      "[buster-claw data delivery — refused]\n\nA datareq block must contain one " <>
        "JSON object, not a list or a bare value."

  def refuse({:invalid, reason}),
    do: "[buster-claw data delivery — refused]\n\nThat request was rejected: #{inspect(reason)}."

  @doc "The turn for extra blocks in one message — one request at a time."
  def refuse_extra(count) do
    "[buster-claw data delivery — note]\n\n#{count} additional datareq block(s) " <>
      "in that message were ignored. Ask for one series at a time; the first " <>
      "was processed."
  end

  @doc """
  The turn for a request the caller refuses to run again — the loop brake.
  """
  def refuse_repeat(signature) do
    """
    [buster-claw data delivery — refused]

    You have already asked for this and it failed for the same reason
    (#{signature}). Asking a third time will not change the answer.

    Stop requesting it. Tell the operator what is missing and what you would
    need, and draw only what the data you already have can honestly support.
    """
    |> String.trim()
  end

  @doc "The turn for a conversation that has spent its delivery budget."
  def refuse_budget do
    """
    [buster-claw data delivery — refused]

    This conversation has reached its data-request limit. No further fetches
    will run.

    Work with what you have, or tell the operator what is still missing so they
    can decide. Do not emit another datareq block.
    """
    |> String.trim()
  end

  # --- internals ---

  defp payload_json(payload) do
    %{
      source: payload.source,
      source_url: payload.source_url,
      as_of: payload.as_of,
      series_id: payload.series_id,
      title: payload.title,
      units: payload.units,
      frequency: payload.frequency,
      requested: payload.requested,
      covered: covered_json(payload.covered),
      observation_count: length(payload.observations),
      observations:
        Enum.map(payload.observations, &%{date: Date.to_iso8601(&1.date), value: &1.value})
    }
  end

  defp covered_json(nil), do: nil

  defp covered_json(%{from: from, to: to}),
    do: %{from: Date.to_iso8601(from), to: Date.to_iso8601(to)}

  defp truncation_line(%{truncated: 0}), do: ""

  defp truncation_line(%{truncated: n}),
    do:
      "\n#{n} older observation(s) were trimmed to bound this payload — " <>
        "say so in the subtitle rather than implying full coverage.\n"

  defp aggregate_line(%{note: nil}), do: ""
  defp aggregate_line(%{note: note}), do: "\n#{note}\n"
  defp aggregate_line(_payload), do: ""

  # Each of these is a recorded decision, not a stage in a pipeline. `Sources`'
  # moduledoc is the long form.
  defp status_reason(:candidate),
    do: "documented but never actually called, so nothing here knows the shape of its answer."

  defp status_reason(:blocked),
    do: "blocked: its terms forbid the way this application would use it."

  defp status_reason(:unsanctioned),
    do: "unsanctioned: there is no licence permitting us to use it."

  defp status_reason(:dead), do: "dead: it used to work and no longer does."

  # `:verified` reaching here means the registry trusts it and no adapter has
  # been written yet — a gap in this module, not in the source.
  defp status_reason(:verified), do: "verified, but no adapter has been written for it yet."
  defp status_reason(other), do: "marked #{other}, which is not a fetchable state."

  defp source_lines do
    Enum.map_join(sources(), "", fn {key, meta} ->
      "\n  - #{key}: #{meta.answers}. Series is #{meta.series_hint}.\n"
    end)
  end

  # Every failure names what happened AND what to do about it. A reason with no
  # instruction is how a model ends up retrying the same broken request.
  defp failure_text({:bls_error, _status, messages}) do
    detail = messages |> List.wrap() |> Enum.join("; ")

    "[buster-claw data delivery — failed]\n\nThe source rejected the request: " <>
      "#{detail}. Check the series id, or tell the operator this series is not " <>
      "available. Do not repeat the identical request."
  end

  defp failure_text({:invalid_series_id, id}),
    do:
      "[buster-claw data delivery — failed]\n\n\"#{id}\" is not a valid series id " <>
        "for that source. Series ids are alphanumeric, e.g. CUUR0000SA0."

  defp failure_text({:http_error, status, _body}),
    do:
      "[buster-claw data delivery — failed]\n\nThe source answered HTTP #{status}. " <>
        "This is an upstream problem, not something you can fix by rewording the " <>
        "request. Tell the operator the fetch failed."

  defp failure_text(reason),
    do:
      "[buster-claw data delivery — failed]\n\nThe fetch failed (#{inspect(reason)}). " <>
        "Nothing was retrieved. Do not plot anything for this series; say it is " <>
        "unavailable."
end
