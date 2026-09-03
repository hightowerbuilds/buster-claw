defmodule BusterClaw.Voice.Messages do
  @moduledoc """
  Messages the operator leaves for themselves, in their own voice, fired as
  notifications.

  "Stand up." "The build is done." "Call your mother." Each is a named line,
  rendered once through the speech engine — in the reference voice if one is
  recorded — and then it is a *sound* the notification layer already knows how
  to play. That is the whole design: **a spoken message is a notification whose
  sound is a rendered line.** No new playback path, no new scheduler; the modal,
  the snooze, the sound toggle and the audit feed all come for free because a
  fired message is just a fired notification.

  ## How the sound reaches the notification

  A rendered line is installed into the sound library as `message-<name>.wav`,
  and the notification carries that filename in `metadata["sound"]`.
  `Sound.for_notification/1` honours it ahead of the routing walk — a message
  says what it says regardless of which chime the `reminder` key is routed to.

  ## Renders are slow, so nothing here waits

  On this hardware a line takes minutes. `create/2` asks the renderer and returns
  at once; the row remembers where the audio *will* land, and readiness is read
  off the disk each time rather than tracked. Installing into the library happens
  lazily, the first time a ready message is listed or fired. There is no process
  listening for the render to finish, which means nothing to supervise and
  nothing that can be left half-done.

  ## The agent can reach all of this

  Four verbs — `voice_message_create`, `_list`, `_fire`, `_delete` — so the model
  can leave the operator a message in the operator's own voice: "I finished the
  report you asked for." Firing accepts the same `in_seconds` / `at` shapes as
  `notify_create`, so it can also be "…at nine tomorrow."
  """

  alias BusterClaw.Notifications
  alias BusterClaw.Notifications.Sound
  alias BusterClaw.Voice.{Config, Engine, Renderer}

  @manifest "messages.json"
  @name_re ~r/^[a-z0-9][a-z0-9-]{0,40}$/

  @type row :: %{
          name: String.t(),
          text: String.t(),
          path: String.t(),
          at: String.t(),
          ready?: boolean(),
          installed?: boolean(),
          sound: String.t()
        }

  @doc "The library filename a message is installed under."
  @spec sound_name(String.t()) :: String.t()
  def sound_name(name), do: "message-#{name}.wav"

  @doc """
  Normalise a human name into a slug: lowercased, spaces to dashes, nothing but
  `[a-z0-9-]`. Returns `{:error, :invalid_name}` when nothing usable is left.
  """
  @spec slug(term()) :: {:ok, String.t()} | {:error, :invalid_name}
  def slug(value) when is_binary(value) do
    candidate =
      value
      |> String.downcase()
      |> String.trim()
      |> String.replace(~r/[\s_]+/, "-")
      |> String.replace(~r/[^a-z0-9-]/, "")
      |> String.trim("-")

    if Regex.match?(@name_re, candidate), do: {:ok, candidate}, else: {:error, :invalid_name}
  end

  def slug(_), do: {:error, :invalid_name}

  @doc """
  Create (or re-render) a message. Returns at once; `ready?` says whether the
  audio exists yet. A message with the same name is replaced.
  """
  @spec create(term(), term(), keyword()) :: {:ok, row()} | {:error, term()}
  def create(name, text, opts \\ []) do
    text = text |> to_string() |> String.trim()
    opts = Keyword.merge(Config.render_opts(), opts)

    with {:ok, name} <- slug(name),
         :ok <- present(text),
         true <- Engine.available?() || {:error, :engine_unavailable},
         {:ok, path} <- Renderer.path_for(text, opts),
         result when result != :error <- start_render(text, opts) do
      row = %{
        "name" => name,
        "text" => text,
        "path" => path,
        "at" => DateTime.to_iso8601(DateTime.utc_now())
      }

      write([row | Enum.reject(read(), &(&1["name"] == name))])
      {:ok, describe(row)}
    else
      false -> {:error, :engine_unavailable}
      {:error, _} = error -> error
    end
  end

  @doc "Every message, newest first, with readiness read off the disk."
  @spec list() :: [row()]
  def list, do: Enum.map(read(), &describe/1)

  @doc "One message by name."
  @spec get(String.t()) :: row() | nil
  def get(name) when is_binary(name) do
    Enum.find_value(read(), fn row -> if row["name"] == name, do: describe(row) end)
  end

  @doc """
  Copy a ready message's audio into the sound library so a notification can
  name it. Idempotent; refuses a message whose render has not landed.
  """
  @spec ensure_installed(String.t()) ::
          {:ok, String.t()} | {:error, :not_found | :not_ready | term()}
  def ensure_installed(name) when is_binary(name) do
    case get(name) do
      nil ->
        {:error, :not_found}

      %{ready?: false} ->
        {:error, :not_ready}

      %{path: path, sound: sound, installed?: installed?} ->
        target = Path.join(Sound.dir(), sound)

        if installed? and newer?(target, path) do
          {:ok, sound}
        else
          with :ok <- File.mkdir_p(Sound.dir()), :ok <- File.cp(path, target), do: {:ok, sound}
        end
    end
  end

  @doc """
  Fire a message as a notification: now by default, or `in_seconds` from now, or
  `at` an ISO-8601 moment. The notification's label is the spoken text, so the
  modal shows what the room just heard.
  """
  @spec fire(String.t(), map()) :: {:ok, Notifications.Notification.t()} | {:error, term()}
  def fire(name, args \\ %{}) when is_binary(name) do
    with %{text: text} = message <- get(name) || {:error, :not_found},
         {:ok, sound} <- ensure_installed(message.name),
         {:ok, kind, fire_at} <- when_to_fire(args) do
      Notifications.create_notification(%{
        "kind" => kind,
        "label" => text,
        "fire_at" => fire_at,
        "status" => "pending",
        "source" => "manual",
        "metadata" => %{"sound" => sound, "voice_message" => message.name}
      })
    end
  end

  @doc "Remove a message and its library sound. The render cache keeps its file."
  @spec delete(String.t()) :: :ok | {:error, :not_found}
  def delete(name) when is_binary(name) do
    case get(name) do
      nil ->
        {:error, :not_found}

      %{sound: sound} ->
        File.rm(Path.join(Sound.dir(), sound))
        write(Enum.reject(read(), &(&1["name"] == name)))
    end
  end

  # ---------------------------------------------------------------------------

  defp start_render(text, opts) do
    case Renderer.render(text, opts) do
      {:ok, _path} -> :hit
      {:queued, _key} -> :queued
      {:error, _} = error -> error
    end
  end

  defp describe(row) do
    sound = sound_name(row["name"])

    %{
      name: row["name"],
      text: row["text"],
      path: row["path"],
      at: row["at"],
      ready?: File.regular?(row["path"]),
      installed?: sound in Sound.list(),
      sound: sound
    }
  end

  defp when_to_fire(args) do
    cond do
      is_binary(args["at"]) ->
        case DateTime.from_iso8601(args["at"]) do
          {:ok, dt, _} -> {:ok, "alarm", DateTime.truncate(dt, :second)}
          _ -> {:error, :invalid_at}
        end

      seconds = positive(args["in_seconds"]) ->
        {:ok, "timer",
         DateTime.add(DateTime.utc_now() |> DateTime.truncate(:second), seconds, :second)}

      true ->
        {:ok, "reminder", DateTime.utc_now() |> DateTime.truncate(:second)}
    end
  end

  defp positive(n) when is_integer(n) and n > 0, do: n

  defp positive(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} when n > 0 -> n
      _ -> nil
    end
  end

  defp positive(_), do: nil

  defp newer?(target, source) do
    with {:ok, %{mtime: t}} <- File.stat(target), {:ok, %{mtime: s}} <- File.stat(source) do
      t >= s
    else
      _ -> false
    end
  end

  defp present(""), do: {:error, :empty_text}
  defp present(_), do: :ok

  defp manifest_path, do: Path.join(Renderer.cache_dir(), @manifest)

  defp read do
    with {:ok, json} <- File.read(manifest_path()),
         {:ok, rows} when is_list(rows) <- Jason.decode(json) do
      Enum.filter(
        rows,
        &(is_map(&1) and is_binary(&1["name"]) and is_binary(&1["text"]) and is_binary(&1["path"]))
      )
    else
      _ -> []
    end
  end

  defp write(rows) do
    File.mkdir_p(Renderer.cache_dir())
    File.write(manifest_path(), Jason.encode!(rows))
  end
end
