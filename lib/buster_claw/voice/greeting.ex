defmodule BusterClaw.Voice.Greeting do
  @moduledoc """
  What a stranger hears when they phone the number.

  Today the Edge Function speaks it with `<Say voice="Polly.Matthew">` — every
  caller hears Amazon. This renders it locally instead, in whatever voice the
  operator chose, and publishes the audio for Twilio to `<Play>`.

  ## It is one recording, not two

  The greeting and the access-code instructions are a **single `<Say>` element**
  in `supabase/functions/voice/index.ts`. That is not an aesthetic detail, it is
  the mechanism: they are one utterance or none. A greeting in the operator's own
  voice followed by Polly saying "enter it now, then press pound" is worse than
  all-Polly, and the TwiML gives no way to have it both ways without splitting the
  element. So the editable text below is the *whole line*, instructions included.

  ## Drift is tracked, because audio cannot be diffed

  Editing the line does not change what callers hear — publishing does. A stored
  digest of the text that was actually published is the only way to tell the
  operator "what you are reading is not what your callers get", which is a state
  they would otherwise discover from a friend.

  ## Publishing is a real change to the outside world

  This is the one thing in the app that changes what **other people** experience,
  and it happens on a phone number that strangers dial. It is a deliberate,
  operator-initiated act with a confirmation in front of it — never something that
  happens as a side effect of editing a text field.
  """

  alias BusterClaw.Settings
  alias BusterClaw.Telephony.Relay
  alias BusterClaw.Voice.Renderer

  @text_key "voice_greeting_text"
  @published_key "voice_greeting_published_digest"

  # The instructions half is quoted from the Edge Function's own `<Say>`, because
  # a recording that omits them leaves callers with no idea a PIN exists.
  @default_text "You've reached Buster Claw. If you have an access code, enter it now, then press pound. Otherwise, stay on the line to leave a message."

  @doc "The seeded greeting, before any edit."
  @spec default_text() :: String.t()
  def default_text, do: @default_text

  @doc "The current greeting text — the whole spoken line, instructions included."
  @spec text() :: String.t()
  def text do
    case Settings.get(@text_key) do
      value when is_binary(value) and value != "" -> value
      _ -> @default_text
    end
  end

  @doc """
  Change the greeting. Does **not** change what callers hear — `publish/1` does.

  A blank line resets to the default rather than storing nothing: a phone number
  that answers with silence is worse than one that answers with Polly.
  """
  @spec put_text(String.t()) :: :ok | {:error, term()}
  def put_text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> reset()
      trimmed -> with {:ok, _} <- Settings.put(@text_key, trimmed), do: :ok
    end
  end

  @doc "Put the greeting back to its seeded text."
  @spec reset() :: :ok | {:error, term()}
  def reset do
    with {:ok, _} <- Settings.put(@text_key, @default_text), do: :ok
  end

  @doc """
  Render the current greeting in the operator's voice.

  `{:ok, path}` on a cache hit, `{:queued, key}` while it is being made.
  """
  @spec render(keyword()) :: {:ok, String.t()} | {:queued, String.t()} | {:error, term()}
  def render(opts \\ []), do: Renderer.render(text(), opts)

  @doc "Where the current greeting's audio will be, whether or not it exists yet."
  @spec rendered_path(keyword()) :: {:ok, String.t()} | {:error, term()}
  def rendered_path(opts \\ []), do: Renderer.path_for(text(), opts)

  @doc """
  Upload the rendered audio so callers hear it.

  Reads the file first and refuses an empty one: publishing silence to a phone
  number is the worst failure this function has, and it is indistinguishable from
  success once it is done.
  """
  @spec publish(String.t(), keyword()) :: :ok | {:error, term()}
  def publish(path, opts \\ []) when is_binary(path) do
    with {:ok, bytes} <- read_audio(path),
         :ok <- Relay.upload_greeting(bytes, opts),
         {:ok, _} <- Settings.put(@published_key, digest(text())) do
      :ok
    end
  end

  @doc """
  Take the greeting down. Callers go back to the synthesized voice.

  The Edge Function falls back on its own when the object is absent, so this
  cannot leave the phone line silent.
  """
  @spec unpublish(keyword()) :: :ok | {:error, term()}
  def unpublish(opts \\ []) do
    case Relay.delete_greeting(opts) do
      result when result in [:ok, {:ok, :gone}] ->
        Settings.put(@published_key, "")
        :ok

      {:error, _reason} = error ->
        error
    end
  end

  @doc """
  What callers currently get, versus what the operator is looking at.

  `published?` asks storage rather than trusting the local flag. `stale?` is true
  when the text has been edited since it was last published — the published audio
  still plays, it just no longer matches the words on screen.
  """
  @spec status(keyword()) :: %{published?: boolean(), stale?: boolean()}
  def status(opts \\ []) do
    published? = Relay.configured?() and Relay.greeting_published?(opts)

    %{
      published?: published?,
      stale?: published? and Settings.get(@published_key) != digest(text())
    }
  end

  defp read_audio(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, size: size}} when size > 44 -> File.read(path)
      {:ok, %File.Stat{}} -> {:error, :empty_audio}
      {:error, reason} -> {:error, reason}
    end
  end

  defp digest(value), do: :sha256 |> :crypto.hash(value) |> Base.encode16(case: :lower)
end
