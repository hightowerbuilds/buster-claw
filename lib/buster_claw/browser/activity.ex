defmodule BusterClaw.Browser.Activity do
  @moduledoc """
  Durable receipts for the shared browser bridge and Agent Mode trajectories.

  Captures only action, outcome, timing, and a sanitized page address. Never
  stores a bridge payload, page text, selectors, input values, or trajectory
  summaries. Recording is best-effort: an unavailable database cannot stop a
  browser action. The graph reads a bounded, chronologically ordered window.
  """
  import Ecto.Query
  require Logger

  alias BusterClaw.Browser.ActivityEvent
  alias BusterClaw.BrowserControl.Egress.Redactor
  alias BusterClaw.Repo

  @limit 200

  def capture_shared(action, payload, result, context, duration_ms) do
    capture(%{
      source: "shared",
      action: to_string(action),
      outcome: outcome(result),
      url: shared_url(action, payload, result, context),
      duration_ms: duration_ms
    })
  end

  def capture_agent(run_id, step, url) do
    capture(%{
      source: "agent",
      run_id: run_id,
      action: to_string(step.type),
      outcome: to_string(step.outcome),
      url: url
    })
  end

  defp capture(attrs) do
    if Application.get_env(:buster_claw, :browser_activity_enabled, true),
      do: record(attrs),
      else: :ok
  end

  @doc "Persist a minimal receipt. All addresses are sanitized before storage."
  def record(attrs) do
    attrs = Map.update(attrs, :url, nil, &sanitize_url/1)
    %ActivityEvent{} |> ActivityEvent.changeset(attrs) |> Repo.insert()
  rescue
    error ->
      Logger.warning("Browser activity receipt unavailable: #{inspect(error.__struct__)}")
      {:error, :unavailable}
  end

  @doc "Newest 200 matching receipts, returned oldest first."
  def snapshot(params \\ %{}) do
    events =
      ActivityEvent
      |> filter_source(params["source"])
      |> filter_run(params["run_id"])
      |> order_by(desc: :id)
      |> limit(^(@limit + 1))
      |> Repo.all()

    %{
      events: events |> Enum.take(@limit) |> Enum.reverse(),
      truncated: length(events) > @limit,
      runs: recent_runs(),
      limit: @limit
    }
  end

  defp recent_runs do
    from(event in ActivityEvent,
      where: not is_nil(event.run_id),
      group_by: event.run_id,
      order_by: [desc: max(event.id)],
      limit: 30,
      select: event.run_id
    )
    |> Repo.all()
  end

  defp filter_source(query, source) when source in ["shared", "agent"],
    do: where(query, [event], event.source == ^source)

  defp filter_source(query, _source), do: query

  defp filter_run(query, run_id) when is_binary(run_id) and run_id != "",
    do: where(query, [event], event.run_id == ^run_id)

  defp filter_run(query, _run_id), do: query

  @doc "Only HTTP(S) locations; user info, query strings, and fragments never reach disk."
  def sanitize_url(url) when is_binary(url) do
    case URI.new(url) do
      {:ok, %URI{scheme: scheme, host: host} = uri}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        clean = URI.to_string(%{uri | userinfo: nil, query: nil, fragment: nil})
        {redacted, _counts} = Redactor.redact(clean)
        String.slice(redacted, 0, 1_000)

      _ ->
        nil
    end
  end

  def sanitize_url(_url), do: nil

  defp shared_url(action, payload, result, context) do
    result_url(result) ||
      if(action in [:navigate, :open_tab, :render], do: payload["url"]) || context["url"]
  end

  defp result_url({:ok, %{url: url}}) when is_binary(url), do: url

  defp result_url({:ok, %{data: data}}) when is_binary(data) do
    case Jason.decode(data) do
      {:ok, %{"url" => url}} -> url
      _ -> nil
    end
  end

  defp result_url(_result), do: nil

  defp outcome({:ok, %{data: data}}) when is_binary(data) do
    case Jason.decode(data) do
      {:ok, %{"error" => _}} -> "error"
      {:ok, %{"ok" => false}} -> "error"
      _ -> "ok"
    end
  end

  defp outcome({:ok, _}), do: "ok"
  defp outcome(_result), do: "error"
end
