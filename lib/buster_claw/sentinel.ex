defmodule BusterClaw.Sentinel do
  @moduledoc """
  The security audit + notify spine (Phase 1).

  `observe/4` is the single front door: it classifies an event into a severity,
  redacts secrets out of its metadata, persists it to the append-only
  `security_events` table, and broadcasts `{:security_event, event}` on the
  `"security_alerts"` PubSub topic (the same topic the Phase 0
  `BusterClaw.Sentinel.Pending` stub already uses). The live alert center
  (`BusterClawWeb.SecurityLive`) subscribes to that topic.

  Observation is best-effort and must never break the action it records — a
  persistence failure is logged and swallowed. Call `observe/4` from the
  *caller's* process (e.g. inside `Commands.call/3`) so it shares the request's
  Ecto sandbox connection in tests.

  ## Categories

  - `:security_block` — a restricted command refused for an untrusted caller
  - `:command_invoke` — a consequential command dispatched via the command surface
  - `:outbound_send` — something left the box (delivery, hook)
  - `:untrusted_ingest` — untrusted external content pulled in (web/RSS)

  ## Severity rubric

  `:info < :notice < :warning < :critical`. See `classify/2`.
  """

  import Ecto.Query

  require Logger

  alias BusterClaw.Repo
  alias BusterClaw.Sentinel.Event
  alias Phoenix.PubSub

  @topic "security_alerts"
  @sensitive_fragments ~w(token secret password api_key apikey authorization auth credential private_key client_secret refresh_token access_token cookie)

  # Value-shape redaction (in addition to key-name redaction): a secret carried
  # under a benign key (an OAuth `code`, a token in a `url` query string, a card
  # number in free text) must not persist cleartext. These heuristics are kept
  # deliberately conservative to avoid mangling ordinary prose:
  #
  #   * @secret_prefix_re — values with well-known credential prefixes
  #     (Bearer/Basic, sk-/pk-, GitHub ghp_/github_pat_, Slack xox*, AWS AKIA,
  #     JWT eyJ). Requires a prefix, so false positives are near zero.
  #   * @long_token_re — a single unbroken 40+ char run mixing letters AND
  #     digits (opaque API keys). 40 is above a canonical UUID (36) to spare them.
  #   * card numbers — 13–19 digit runs that also pass a Luhn check.
  @secret_prefix_re ~r/(?:Bearer\s+|Basic\s+|sk-|pk-|ghp_|gho_|ghs_|ghu_|ghr_|github_pat_|xox[baprs]-|AKIA|eyJ)[A-Za-z0-9._\/+=-]{8,}/
  @long_token_re ~r/(?=[A-Za-z0-9_-]*[0-9])(?=[A-Za-z0-9_-]*[A-Za-z])[A-Za-z0-9_-]{40,}/
  @card_run_re ~r/\d(?:[ -]?\d){12,18}/

  @doc "The PubSub topic security events are broadcast on."
  def topic, do: @topic

  @doc "Subscribe the calling process to the security-event feed."
  def subscribe, do: PubSub.subscribe(BusterClaw.PubSub, @topic)

  @doc """
  Record a security event. Returns `{:ok, event}` or `{:error, reason}`; callers
  generally ignore the result. `opts` may override `:severity` and `:caller`.
  """
  def observe(category, message, meta \\ %{}, opts \\ [])
      when is_atom(category) and is_binary(message) do
    attrs = %{
      category: Atom.to_string(category),
      severity: to_string(opts[:severity] || classify(category, meta)),
      message: message,
      caller:
        normalize_caller(opts[:caller] || meta_get(meta, :caller) || meta_get(meta, "caller")),
      metadata: redact(meta)
    }

    case %Event{} |> Event.changeset(attrs) |> Repo.insert() do
      {:ok, event} ->
        PubSub.broadcast(BusterClaw.PubSub, @topic, {:security_event, event})
        {:ok, event}

      {:error, reason} = err ->
        Logger.warning("Sentinel.observe failed to persist #{category}: #{inspect(reason)}")
        err
    end
  rescue
    # Recording must never break the action it observes (incl. callers that run
    # outside an Ecto sandbox in tests).
    error ->
      Logger.warning("Sentinel.observe crashed for #{category}: #{inspect(error)}")
      {:error, error}
  end

  @doc "List recent events, newest first."
  def list_events(opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)

    Event
    |> order_by(desc: :inserted_at, desc: :id)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc "Count events not yet acknowledged."
  def count_unacknowledged do
    Event
    |> where([e], is_nil(e.acknowledged_at))
    |> Repo.aggregate(:count)
  end

  @doc "Mark a single event acknowledged."
  def acknowledge(id) do
    case Repo.get(Event, id) do
      nil -> {:error, :not_found}
      event -> event |> Ecto.Changeset.change(acknowledged_at: now()) |> Repo.update()
    end
  end

  @doc "Mark every unacknowledged event acknowledged. Returns `{:ok, count}`."
  def acknowledge_all do
    {count, _} =
      Event
      |> where([e], is_nil(e.acknowledged_at))
      |> Repo.update_all(set: [acknowledged_at: now()])

    {:ok, count}
  end

  # ---- Classification ----

  @doc false
  def classify(:security_block, _meta), do: :critical
  def classify(:outbound_send, _meta), do: :warning
  def classify(:untrusted_ingest, _meta), do: :notice

  def classify(:command_invoke, meta) do
    if tier(meta) == "restricted", do: :warning, else: :notice
  end

  # Settings edits are :notice by default; callers escalate to :warning via the
  # severity override when the change alters what would actually execute
  # (e.g. a terminal cmd-list command string).
  def classify(:settings_change, _meta), do: :notice

  def classify(_other, _meta), do: :info

  defp tier(meta) when is_map(meta), do: to_string(meta[:tier] || meta["tier"] || "")
  defp tier(_meta), do: ""

  # ---- Helpers ----

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  defp normalize_caller(nil), do: nil
  defp normalize_caller(caller), do: to_string(caller)

  defp meta_get(meta, key) when is_map(meta), do: meta[key]
  defp meta_get(_meta, _key), do: nil

  # Coerce metadata into JSON-safe, secret-redacted values. Sentinel runs on the
  # hot path of every recorded action, so this must never raise.
  defp redact(meta) when is_map(meta) and not is_struct(meta) do
    Map.new(meta, fn {k, v} -> {to_string(k), redact_value(k, v)} end)
  end

  defp redact(other), do: %{"value" => safe_scalar(other)}

  defp redact_value(key, value) do
    cond do
      sensitive_key?(key) -> "[redacted]"
      is_map(value) and not is_struct(value) -> redact(value)
      is_list(value) -> Enum.map(value, &redact_value(key, &1))
      is_binary(value) -> value |> mask_secret_values() |> safe_scalar()
      true -> safe_scalar(value)
    end
  end

  # Mask secret-shaped substrings regardless of the key that carries them. Runs
  # on every recorded action, so it must never raise; all ops here are on plain
  # binaries.
  defp mask_secret_values(value) do
    value
    |> mask_cards()
    |> then(&Regex.replace(@secret_prefix_re, &1, "[redacted]"))
    |> then(&Regex.replace(@long_token_re, &1, "[redacted]"))
  end

  defp mask_cards(value) do
    Regex.replace(@card_run_re, value, fn match ->
      digits = String.replace(match, ~r/[ -]/, "")
      if luhn_valid?(digits), do: "[redacted]", else: match
    end)
  end

  defp luhn_valid?(digits) do
    len = String.length(digits)

    if len < 13 or len > 19 do
      false
    else
      digits
      |> String.to_charlist()
      |> Enum.reverse()
      |> Enum.with_index()
      |> Enum.reduce(0, fn {char, idx}, acc ->
        d = char - ?0
        d = if rem(idx, 2) == 1, do: d * 2, else: d
        d = if d > 9, do: d - 9, else: d
        acc + d
      end)
      |> rem(10)
      |> Kernel.==(0)
    end
  end

  defp safe_scalar(v) when is_binary(v) do
    if byte_size(v) > 200, do: binary_part(v, 0, 200) <> "…", else: v
  end

  defp safe_scalar(v) when is_number(v) or is_boolean(v) or is_nil(v), do: v
  defp safe_scalar(v) when is_atom(v), do: Atom.to_string(v)
  defp safe_scalar(v), do: inspect(v)

  defp sensitive_key?(key) do
    k = key |> to_string() |> String.downcase()
    Enum.any?(@sensitive_fragments, &String.contains?(k, &1))
  end
end
