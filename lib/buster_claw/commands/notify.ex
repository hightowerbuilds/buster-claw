defmodule BusterClaw.Commands.Notify do
  @moduledoc """
  The `notify_*` command surface — how BusterClaw arms timers, alarms, and
  reminders from any entry point. Delegated to from `BusterClaw.Commands`.

  `notify_create` takes a friendly shape (`in_seconds` for a timer, `at` for an
  alarm) and resolves it to the absolute `fire_at` the store keeps, so the agent
  never computes timestamps itself.
  """

  import BusterClaw.Commands.Helpers

  alias BusterClaw.Notifications

  @default_snooze_seconds 300

  def notify_list(_args \\ %{}), do: {:ok, Notifications.upcoming()}

  def notify_get(%{"id" => id}), do: safe_get(Notifications, :get_notification!, id)

  def notify_create(args) do
    with {:ok, attrs} <- build_create_attrs(args) do
      Notifications.create_notification(attrs)
    end
  end

  def notify_snooze(%{"id" => id} = args) do
    seconds = positive_seconds(Map.get(args, "in_seconds"), @default_snooze_seconds)

    with_resource(Notifications, :get_notification!, id, fn notification ->
      Notifications.snooze(notification, seconds)
    end)
  end

  def notify_dismiss(%{"id" => id}) do
    with_resource(Notifications, :get_notification!, id, &Notifications.dismiss/1)
  end

  def notify_delete(%{"id" => id}) do
    with_resource(Notifications, :get_notification!, id, &Notifications.delete_notification/1)
  end

  # --- attrs ------------------------------------------------------------------

  defp build_create_attrs(args) do
    kind = Map.get(args, "kind", "reminder")
    label = args |> Map.get("label", "") |> to_string() |> String.trim()

    if label == "" do
      {:error, :missing_label}
    else
      with {:ok, fire_at} <- fire_at_from(kind, args) do
        {:ok,
         %{
           "kind" => kind,
           "label" => label,
           "fire_at" => fire_at,
           "status" => "pending",
           "source" => Map.get(args, "source", "manual"),
           "metadata" => Map.get(args, "metadata", %{})
         }}
      end
    end
  end

  # reminder fires now; timer is now + in_seconds; alarm is the given ISO-8601 moment.
  defp fire_at_from("reminder", _args), do: {:ok, now()}

  defp fire_at_from("timer", args) do
    case positive_seconds(Map.get(args, "in_seconds"), nil) do
      nil -> {:error, :missing_in_seconds}
      seconds -> {:ok, DateTime.add(now(), seconds, :second)}
    end
  end

  defp fire_at_from("alarm", args) do
    case Map.get(args, "at") do
      at when is_binary(at) ->
        case DateTime.from_iso8601(at) do
          {:ok, datetime, _offset} -> {:ok, DateTime.truncate(datetime, :second)}
          {:error, _reason} -> {:error, :invalid_at}
        end

      _ ->
        {:error, :missing_at}
    end
  end

  defp fire_at_from(_kind, _args), do: {:error, :invalid_kind}

  defp positive_seconds(value, _default) when is_integer(value) and value > 0, do: value

  defp positive_seconds(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {seconds, _rest} when seconds > 0 -> seconds
      _ -> default
    end
  end

  defp positive_seconds(_value, default), do: default

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
