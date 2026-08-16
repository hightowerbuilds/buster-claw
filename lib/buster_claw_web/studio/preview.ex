defmodule BusterClawWeb.Studio.Preview do
  @moduledoc """
  Scratch audio the operator can play back, and the version that stops the
  browser replaying the last one.

  Two surfaces render a preview and they arrived a few hours apart: the Voice
  Library builds a sentence from a phrase, and the Mix's clip inspector renders
  one clip through its effect chain. Both write to a **fixed filename** and both
  need the client to know the bytes changed.

  ## The version is not decoration

  `voice_audition.js` caches decoded buffers by URL, because auditioning is
  repetitive — you play four takes of one word from the same two files. A preview
  that keeps one name would therefore be fetched once and **replayed forever**:
  real audio, of a real phrase or a real chain, just not the current one. That is
  the convincing way to be wrong, and it was caught by reasoning about the cache
  rather than by hearing it, which means nothing would have caught it later.

  So the version is part of the contract, and it lives here rather than in each
  surface. Both had their own `next_version/1` — identical, six lines, and one
  edit away from disagreeing about the thing that makes previews trustworthy.

  ## Why a fixed name at all

  A preview is scratch: not a take, not a render, not part of any corpus.
  Numbering the files would leave `preview-1.wav … preview-40.wav` in the
  studio's source list within an afternoon, and every one of them would be
  addable as a clip. One name, overwritten, is the honest shape.
  """

  alias BusterClaw.Notifications.SoundStudio

  @typedoc "What a surface assigns after a successful render."
  @type t :: %{name: String.t(), version: pos_integer()}

  @doc """
  Write `clip` to the studio folder under `name`, returning the assign to store.

  Takes the PREVIOUS preview so the version increments; pass `nil` the first
  time. Returns `{:error, reason}` untouched — a surface that cannot write its
  preview should say so, not render a play button for a file that is not there.
  """
  @spec write(SoundStudio.t(), String.t(), t() | nil) :: {:ok, t()} | {:error, term()}
  def write(%SoundStudio{} = clip, name, previous) when is_binary(name) do
    File.mkdir_p(SoundStudio.dir())

    case SoundStudio.write(clip, Path.join(SoundStudio.dir(), name)) do
      :ok -> {:ok, %{name: name, version: next(previous)}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "The next version number for a preview, given whatever the surface holds."
  @spec next(t() | nil | term()) :: pos_integer()
  def next(%{version: n}) when is_integer(n) and n > 0, do: n + 1
  def next(_previous), do: 1
end
