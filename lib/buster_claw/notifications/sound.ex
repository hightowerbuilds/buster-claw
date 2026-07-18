defmodule BusterClaw.Notifications.Sound do
  @moduledoc """
  The notification chime — an audio file the operator drops in the workspace, so
  a fired notification is audible without touching the OS.

  Resolution (first match wins): `<workspace>/sounds/notify.<ext>`, then the first
  audio file in `<workspace>/sounds/` alphabetically. `nil` when the folder holds
  no audio — in which case a fired notification is silent (the modal still shows).

  Served by `NotifySoundController` at `/notify/sound` and played by the
  `NotifySound` hook when `NotifyLive` sees a notification fire.
  """

  require Logger

  alias BusterClaw.Library.Artifact

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

  @doc "Absolute path to the `sounds/` folder in the active workspace."
  def dir, do: Artifact.workspace_path(@subdir)

  @doc """
  Absolute path to the chime to play, or `nil` when none is present. Prefers a
  file explicitly named `notify.<ext>`; otherwise the first audio file in the
  folder.
  """
  def path do
    named_notify() || first_audio()
  end

  @doc "True when a chime is available to play."
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

  defp readme_body do
    """
    # Notification sound

    Drop an audio file here and it plays when a notification fires — no OS
    notification involved.

    - Preferred name: `notify.mp3` (also `.wav`, `.ogg`, `.m4a`, `.aac`).
    - Any audio file works: if there's no `notify.*`, the first audio file in this
      folder (alphabetically) is used.
    - No file here? Notifications still show their modal — just silently.
    """
  end
end
