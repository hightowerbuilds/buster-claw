defmodule BusterClaw.Commands.Telephony do
  @moduledoc """
  BusterPhone commands — the agent's half of the Message Machine. Delegated to
  from `BusterClaw.Commands`.

  Without these the phone is a UI the agent cannot see: a voicemail lands in
  SQLite and renders in `/phone`, but nothing on the command surface can read it.
  These are what let an on-duty agent actually work a `voicemail-triage` item —
  pull the transcript, act, mark it heard.

  Note `phone_get` deliberately does **not** mark an event heard. Reading is not
  hearing: the blinking light is the operator's, and an agent skimming the log
  must not clear it behind their back. `phone_mark_heard` is the explicit,
  audited verb.
  """

  alias BusterClaw.Telephony
  alias BusterClaw.TrustedNumbers

  @kinds ~w(voicemail sms call)

  def phone_list(args) do
    with {:ok, kind} <- parse_kind(Map.get(args, "kind")) do
      events =
        Telephony.list_events(
          kind: kind,
          unheard_only: Map.get(args, "unheard_only") == true,
          limit: limit(args)
        )

      {:ok, Enum.map(events, &summarize/1)}
    end
  end

  def phone_get(%{"id" => id}) do
    case Telephony.get_event(id) do
      nil -> {:error, :not_found}
      event -> {:ok, detail(event)}
    end
  end

  def phone_get(_args), do: {:error, :missing_id}

  def phone_stats(_args \\ %{}), do: {:ok, Telephony.stats()}

  def phone_mark_heard(%{"id" => id}) do
    case Telephony.get_event(id) do
      nil ->
        {:error, :not_found}

      event ->
        with {:ok, updated} <- Telephony.mark_heard(event) do
          {:ok, summarize(updated)}
        end
    end
  end

  def phone_mark_heard(_args), do: {:error, :missing_id}

  def phone_trusted_list(_args \\ %{}), do: {:ok, TrustedNumbers.list_entries()}

  def phone_trusted_add(%{"number" => number}) when is_binary(number) do
    TrustedNumbers.add_entry(number)
  end

  def phone_trusted_add(_args), do: {:error, :missing_number}

  def phone_trusted_remove(%{"number" => number}) when is_binary(number) do
    with :ok <- TrustedNumbers.remove_entry(number), do: {:ok, :removed}
  end

  def phone_trusted_remove(_args), do: {:error, :missing_number}

  defp parse_kind(nil), do: {:ok, nil}
  defp parse_kind(kind) when kind in @kinds, do: {:ok, kind}
  defp parse_kind(_kind), do: {:error, :invalid_kind}

  defp limit(args) do
    case Map.get(args, "limit", 25) do
      n when is_integer(n) and n > 0 -> min(n, 200)
      _ -> 25
    end
  end

  defp summarize(event) do
    %{
      id: event.id,
      kind: event.kind,
      direction: event.direction,
      from: event.from_number,
      to: event.to_number,
      occurred_at: event.occurred_at,
      duration_seconds: event.duration_seconds,
      heard: event.heard_at != nil,
      # The transcript is the payload an agent triages on — but it is a stranger's
      # words. Surface it, don't hide it; the caller is already marked untrusted.
      has_transcript: is_binary(event.transcript) and event.transcript != "",
      trusted_caller: TrustedNumbers.trusted?(event.from_number)
    }
  end

  defp detail(event) do
    event
    |> summarize()
    |> Map.merge(%{
      transcript: event.transcript,
      body: event.body,
      recording_path: event.recording_path
    })
  end
end
