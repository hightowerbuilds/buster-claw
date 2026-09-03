defmodule BusterClaw.Voice.Reference do
  @moduledoc """
  The operator's own voice, recorded in the app, kept as the clip every render
  is cloned from.

  ## There is no training step

  VoxCPM clones zero-shot: hand it a few seconds of someone speaking and it
  speaks as them. "Have the model learn my voice" is therefore not a job this
  module runs — it is a file this module saves. Saving a take sets
  `Voice.Config`'s reference clip, and from that moment every chime, clip and
  greeting is rendered in it. Fine-tuning exists upstream and is deliberately not
  here: zero-shot has to be measured first, or we would be tuning something we
  never established was insufficient.

  ## Why the microphone is opened in the WebView and decoded here

  Entitlements do not cross process boundaries. The process that opens the mic
  is the one that needs the TCC grant, and that is the signed Tauri app — not the
  BEAM. So `VoiceRecorder` captures raw Float32 frames in the page and pushes
  them up; `Capture.Take.decode/2` turns them into a clip and measures it. That
  decoder was written for the Studio's corpus recorder and is the one piece of
  that machinery this depends on; when the Studio is spun out, `decode/2` stays.

  ## A take can be refused

  Silence is refused (`:silent_take` — a muted device produces a file of zeros
  with exit 0, which is worse than an error), and anything under two seconds is
  refused (`:too_short`). A reference clip is what the engine has to go on; a
  half-second of "uh" gives it nothing to clone, and the result is not a bad
  render, it is a stranger's voice with no warning.
  """

  alias BusterClaw.Library.Artifact
  alias BusterClaw.Notifications.Capture.Take
  alias BusterClaw.Notifications.SoundStudio
  alias BusterClaw.Voice.Config

  # Zero-shot cloning wants a few seconds. Ten is comfortable; below two the
  # engine has heard a syllable, not a voice.
  @min_ms 2_000

  @doc "Where recordings live: beside the render cache, inside the workspace."
  def dir, do: Artifact.workspace_path(["sounds", "voice", "reference"])

  @doc "Create the directory. Safe to repeat."
  def ensure do
    File.mkdir_p(dir())
    :ok
  end

  @doc """
  Decode a take from the recorder, write it as a WAV, and make it the reference
  clip. Returns what was measured so the page can show it.
  """
  @spec save(term(), term()) ::
          {:ok,
           %{
             name: String.t(),
             path: String.t(),
             duration_ms: float(),
             peak: float(),
             clipped?: boolean(),
             sample_rate: pos_integer()
           }}
          | {:error, term()}
  def save(pcm, sample_rate) do
    with {:ok, take} <- Take.decode(pcm, sample_rate),
         :ok <- long_enough(take),
         :ok <- ensure(),
         name = filename(),
         path = Path.join(dir(), name),
         :ok <- SoundStudio.write(take.clip, path),
         :ok <- Config.put(%{"reference_audio" => path}) do
      {:ok,
       %{
         name: name,
         path: path,
         duration_ms: take.duration_ms,
         peak: take.peak,
         clipped?: take.clipped?,
         sample_rate: take.sample_rate
       }}
    end
  end

  @doc "Every recording, newest first, with which one is in use."
  @spec list() :: [%{name: String.t(), path: String.t(), current?: boolean(), bytes: integer()}]
  def list do
    current = Config.get().reference_audio

    case File.ls(dir()) do
      {:ok, names} ->
        names
        |> Enum.filter(&String.ends_with?(&1, ".wav"))
        |> Enum.sort(:desc)
        |> Enum.map(fn name ->
          path = Path.join(dir(), name)

          bytes =
            case File.stat(path),
              do: (
                {:ok, %{size: s}} -> s
                _ -> 0
              )

          %{name: name, path: path, current?: path == current, bytes: bytes}
        end)

      _ ->
        []
    end
  end

  @doc "Make an earlier recording the reference clip again."
  @spec use(String.t()) :: :ok | {:error, term()}
  def use(name) when is_binary(name) do
    case resolve(name) do
      nil -> {:error, :not_found}
      path -> Config.put(%{"reference_audio" => path})
    end
  end

  @doc """
  Delete a recording. If it was the reference clip, the clip is cleared too —
  renders fall back to a designed voice rather than to a file that is gone.
  """
  @spec delete(String.t()) :: :ok | {:error, term()}
  def delete(name) when is_binary(name) do
    case resolve(name) do
      nil ->
        {:error, :not_found}

      path ->
        if Config.get().reference_audio == path, do: Config.put(%{"reference_audio" => ""})
        File.rm(path)
    end
  end

  @doc """
  A recording's path from its basename, or `nil`.

  Allowlist over the real directory listing — the name is never joined into a
  path unless a file by that exact name is already there.
  """
  @spec resolve(String.t()) :: String.t() | nil
  def resolve(name) when is_binary(name) do
    if name in (File.ls(dir()) |> elem_ok()) and String.ends_with?(name, ".wav"),
      do: Path.join(dir(), name)
  end

  defp elem_ok({:ok, list}), do: list
  defp elem_ok(_), do: []

  defp long_enough(%{duration_ms: ms}) when ms >= @min_ms, do: :ok
  defp long_enough(_take), do: {:error, :too_short}

  # Sortable by name, so `list/0` needs no stat to order by time.
  defp filename do
    stamp =
      DateTime.utc_now()
      |> DateTime.truncate(:second)
      |> DateTime.to_iso8601(:basic)
      |> String.replace(~r/[^0-9TZ]/, "")

    "reference-#{stamp}.wav"
  end
end
