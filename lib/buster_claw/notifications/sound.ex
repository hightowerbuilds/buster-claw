defmodule BusterClaw.Notifications.Sound do
  @moduledoc """
  The notification sound library — audio files in `<workspace>/sounds/` that
  play when a notification fires, so an alarm is audible without touching the OS.

  Which file plays is routed per event via a map stored in `Settings`
  (`notify_sound_map`, JSON): keys are notification *sources* (chat, terminal,
  email, voicemail, manual), *kinds* (timer, alarm, reminder), or `"default"`.
  Resolution for a fired notification, first match wins: source → kind →
  default → the legacy fallback (`notify.<ext>`, else the first audio file
  alphabetically). Source outranks kind so "a voicemail's timer" sounds like
  voicemail. No sounds at all → the fired modal still shows, silently.

  Served by `NotifySoundController` at `/notify/sound` (resolved default) and
  `/notify/sound/:name` (a specific library file — the name is validated
  against `list/0`, never joined from raw input). Played by the `NotifySound`
  hook when `NotifyLive` sees a notification fire; auditioned by the
  `SoundPreview` hook in Settings → Notify.
  """

  require Logger

  alias BusterClaw.Library.Artifact
  alias BusterClaw.Settings

  @subdir "sounds"
  @preferred "notify"
  @exts ~w(.mp3 .wav .ogg .m4a .aac)
  @content_types %{
    ".mp3" => "audio/mpeg",
    ".wav" => "audio/wav",
    ".ogg" => "audio/ogg",
    ".m4a" => "audio/mp4",
    ".aac" => "audio/aac"
  }

  @map_key "notify_sound_map"
  # Routing keys the map accepts: sources outrank kinds; "default" is the floor.
  @route_keys ~w(chat terminal email voicemail manual timer alarm reminder default)

  @doc "Absolute path to the `sounds/` folder in the active workspace."
  def dir, do: Artifact.workspace_path(@subdir)

  @doc "Audio file extensions the library accepts."
  def accepted_extensions, do: @exts

  @doc "Routing keys the sound map accepts."
  def route_keys, do: @route_keys

  # ---------------------------------------------------------------------------
  # Library
  # ---------------------------------------------------------------------------

  @doc "Sorted basenames of every audio file in the library."
  def list do
    case File.ls(dir()) do
      {:ok, entries} ->
        entries
        |> Enum.sort()
        |> Enum.filter(fn name ->
          String.downcase(Path.extname(name)) in @exts and
            File.regular?(Path.join(dir(), name))
        end)

      _ ->
        []
    end
  end

  @doc """
  Absolute path for a library sound by basename, or `nil` when the name isn't
  in the library. Membership in `list/0` is the allowlist — a name that isn't a
  real directory entry never resolves, so there is no traversal surface.
  """
  def path_for(name) when is_binary(name) do
    if name in list(), do: Path.join(dir(), name)
  end

  def path_for(_), do: nil

  @doc "Remove a sound file and any map entries routing to it."
  def delete(name) when is_binary(name) do
    case path_for(name) do
      nil ->
        {:error, :not_found}

      path ->
        with :ok <- File.rm(path) do
          prune_map_value(name)
          :ok
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Per-event routing
  # ---------------------------------------------------------------------------

  @doc """
  The event→sound map (`%{"voicemail" => "wilhelm.wav", ...}`). Entries whose
  sound file no longer exists are dropped on read.
  """
  def sound_map do
    sounds = list()

    Settings.get(@map_key)
    |> decode_map()
    |> Map.filter(fn {key, value} -> key in @route_keys and value in sounds end)
  end

  @doc """
  Route `key` (a source, kind, or `"default"`) to a library sound. `nil` or
  `""` clears the entry so the key inherits again.
  """
  def assign(key, name) when key in @route_keys do
    cond do
      name in [nil, ""] ->
        persist_map(Map.delete(sound_map(), key))

      name in list() ->
        persist_map(Map.put(sound_map(), key, name))

      true ->
        {:error, :unknown_sound}
    end
  end

  def assign(_key, _name), do: {:error, :unknown_key}

  @doc """
  The library sound name to play for a fired notification (source → kind →
  default → legacy fallback), or `nil` when the library is empty.
  """
  def for_notification(%{source: source, kind: kind}) do
    map = sound_map()
    map[source] || map[kind] || map["default"] || default_name()
  end

  @doc "The sound name a routing key currently resolves to, walking inheritance."
  def resolved(key) when key in @route_keys do
    map = sound_map()

    cond do
      map[key] -> map[key]
      key != "default" and map["default"] -> map["default"]
      true -> default_name()
    end
  end

  defp default_name do
    case path() do
      nil -> nil
      resolved -> Path.basename(resolved)
    end
  end

  # ---------------------------------------------------------------------------
  # Legacy single-chime resolution (the routing floor)
  # ---------------------------------------------------------------------------

  @doc """
  Absolute path to the fallback chime, or `nil` when none is present. Prefers a
  file explicitly named `notify.<ext>`; otherwise the first audio file in the
  folder.
  """
  def path do
    named_notify() || first_audio()
  end

  @doc "True when at least one chime is available to play."
  def available?, do: path() != nil

  @doc "The audio content-type for a resolved sound path."
  def content_type(sound_path) do
    Map.get(@content_types, sound_path |> Path.extname() |> String.downcase(), "audio/mpeg")
  end

  @doc """
  Create the `sounds/` folder and a README explaining how to wire a chime, so the
  feature is discoverable. Best-effort — never raises. No audio is bundled; the
  chime is operator-provided.
  """
  def ensure do
    File.mkdir_p(dir())
    readme = Path.join(dir(), "README.md")
    unless File.exists?(readme), do: File.write(readme, readme_body())
    :ok
  rescue
    error ->
      Logger.warning("Notifications.Sound.ensure failed: #{Exception.message(error)}")
      :ok
  end

  defp named_notify do
    Enum.find_value(@exts, fn ext ->
      candidate = Path.join(dir(), @preferred <> ext)
      if File.regular?(candidate), do: candidate
    end)
  end

  defp first_audio do
    case File.ls(dir()) do
      {:ok, entries} ->
        entries
        |> Enum.sort()
        |> Enum.map(&Path.join(dir(), &1))
        |> Enum.find(fn candidate ->
          File.regular?(candidate) and String.downcase(Path.extname(candidate)) in @exts
        end)

      _ ->
        nil
    end
  end

  defp decode_map(nil), do: %{}

  defp decode_map(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, %{} = map} -> Map.filter(map, fn {k, v} -> is_binary(k) and is_binary(v) end)
      _ -> %{}
    end
  end

  defp persist_map(map) when map == %{} do
    Settings.delete(@map_key)
    :ok
  end

  defp persist_map(map) do
    case Settings.put(@map_key, Jason.encode!(map)) do
      {:ok, _} -> :ok
      {:error, _} = error -> error
    end
  end

  defp prune_map_value(name) do
    pruned = Map.reject(sound_map(), fn {_key, value} -> value == name end)
    persist_map(pruned)
  end

  defp readme_body do
    """
    # Notification sounds

    Audio files here are the notification sound library, managed from
    Settings → Notify — pick which sound plays for each kind of notification,
    preview them, and add more.

    - Accepted: `.mp3`, `.wav`, `.ogg`, `.m4a`, `.aac`.
    - With no routing configured, `notify.<ext>` (else the first audio file
      alphabetically) plays for everything.
    - No file here? Notifications still show their modal — just silently.
    """
  end
end
