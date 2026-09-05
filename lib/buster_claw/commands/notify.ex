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
  alias BusterClaw.Voice.Clips
  alias BusterClaw.Voice.Messages

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

  # --- spoken messages -----------------------------------------------------------
  #
  # Thin: `Voice.Messages` owns the rendering, the manifest and the install; these
  # only shape arguments and answers for the wire. See its moduledoc for why a
  # spoken message is "a notification whose sound is a rendered line".

  def voice_message_create(%{"name" => name, "text" => text}) do
    Messages.create(name, text)
  end

  def voice_message_create(%{"name" => _}), do: {:error, :missing_text}
  def voice_message_create(_args), do: {:error, :missing_name}

  # --- clips: an ad-hoc phrase, not a named notification -----------------------
  #
  # `Messages` and `Clips` both render a line in the operator's voice and are
  # deliberately different things. A message is NAMED and installed as a
  # notification sound; a clip is a phrase somebody asked for. Forcing a slug on
  # "say the build is done" would be friction invented by the data model, which
  # is why these are their own verbs rather than an option on the message ones.
  def voice_clip_make(%{"text" => text}) when is_binary(text) do
    case Clips.make(text) do
      # A cache hit: this exact line, with these exact engine settings, has been
      # rendered before. The file is on disk right now.
      {:ok, path} ->
        {:ok, %{status: "ready", text: String.trim(text), path: path}}

      # The normal case. Minutes, not seconds — the shape of the reply says so,
      # because a model that reports this as done sends the operator to look for
      # a file that is not there yet.
      {:queued, key} ->
        {:ok,
         %{
           status: "queued",
           key: key,
           text: String.trim(text),
           note:
             "Rendering. This takes minutes on this machine — it is NOT ready yet. " <>
               "It appears under Vox2B → Files when it lands; voice_clip_list says when."
         }}

      # Refusals reach the model as a SENTENCE, not a bare atom. A model handed
      # `{:error, :queue_full}` has to guess; handed the reason it can tell the
      # operator something true and decide whether to retry. `:queue_full` in
      # particular is temporary and self-clearing, and nothing else in the reply
      # would say so.
      {:error, reason} ->
        {:error, clip_refusal(reason)}
    end
  end

  def voice_clip_make(_args), do: {:error, :missing_text}

  defp clip_refusal(:queue_full),
    do:
      "The render queue is full (32 waiting). Nothing is lost — wait for it to drain " <>
        "and ask again; renders run one at a time and take minutes each."

  defp clip_refusal(:engine_unavailable),
    do:
      "No speech engine installed. VoxCPM is bring-your-own — the operator installs " <>
        "it from Vox2B → Engine, and nothing here can do it for them."

  defp clip_refusal(:reference_missing),
    do:
      "The reference recording is gone, so there is no voice to clone. The operator " <>
        "records a new one on Vox2B → Create."

  defp clip_refusal(:empty_text), do: "There were no words to say."
  defp clip_refusal(other), do: other

  def voice_clip_list(_args \\ %{}) do
    clips = Clips.list()
    {:ok, %{count: length(clips), clips: clips}}
  end

  def voice_clip_delete(%{"path" => path}) when is_binary(path) do
    Clips.forget(path)
    {:ok, %{forgotten: path}}
  end

  def voice_clip_delete(_args), do: {:error, :missing_path}

  def voice_message_list(_args \\ %{}) do
    messages = Messages.list()
    {:ok, %{count: length(messages), messages: messages}}
  end

  def voice_message_fire(%{"name" => name} = args) when is_binary(name) do
    Messages.fire(name, Map.take(args, ["in_seconds", "at"]))
  end

  def voice_message_fire(_args), do: {:error, :missing_name}

  def voice_message_delete(%{"name" => name}) when is_binary(name) do
    with :ok <- Messages.delete(name), do: {:ok, %{deleted: name}}
  end

  def voice_message_delete(_args), do: {:error, :missing_name}

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
