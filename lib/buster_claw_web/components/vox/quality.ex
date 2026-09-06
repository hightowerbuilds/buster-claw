defmodule BusterClawWeb.Vox.Quality do
  @moduledoc """
  What a recording is like, and what a line will cost — the two numbers Vox2B
  shows *before* the operator commits to a wait.

  Its own module because both belong to one question the surface did not answer
  until 09-06: **is this going to work, and how long will it take?** On that day
  a five-word line ran nine and a half minutes and then failed, and the page had
  said nothing beforehand about the recording that made it slow or the wait it
  implied.

  Split out rather than added to `Vox.Create`, which the file-size gate holds at
  a size the roadmap signed off. A new feature landing whole inside a capped
  panel is exactly what that gate exists to catch, and "extract" is the answer it
  asks for first.

  ## The promise the copy keeps

  `BusterClaw.Voice.ReferenceQuality` grades the **recording** — level, silence,
  noise, length — and never the clone. Nothing here says a render will sound
  good or bad, because nothing has measured that. See that module.
  """
  use BusterClawWeb, :html

  alias BusterClaw.Voice.Calibration
  alias BusterClaw.Voice.Reference
  alias BusterClaw.Voice.ReferenceQuality

  @doc "The grade for the reference in use, with what to do about it."
  attr :quality, :any, default: nil

  def grade(assigns) do
    ~H"""
    <div :if={@quality} class="flex flex-col gap-1 border-t border-base-content/10 pt-2">
      <div class="flex flex-wrap items-center gap-2 font-mono text-[0.6875rem]">
        <span class={[
          "rounded-sm px-1.5 py-0.5 font-bold uppercase tracking-wide",
          @quality.grade == :good && "bg-success/20 text-success",
          @quality.grade == :fair && "bg-warning/20 text-warning",
          @quality.grade == :poor && "bg-error/20 text-error"
        ]}>
          {ReferenceQuality.headline(@quality)}
        </span>
        <span class="text-base-content/55">
          {fmt(@quality.duration_s)}s · {fmt(@quality.rms_dbfs)} dB · {round(
            @quality.speech_ratio * 100
          )}% speech
        </span>
      </div>

      <ul :if={@quality.notes != []} class="flex flex-col gap-0.5">
        <li :for={note <- @quality.notes} class="text-[0.6875rem] leading-snug">
          <span class={[
            "font-medium",
            note.severity == :bad && "text-error",
            note.severity == :warn && "text-warning"
          ]}>
            {note.text}.
          </span>
          <span class="text-base-content/55">{note.fix}</span>
        </li>
      </ul>
    </div>
    """
  end

  @doc "The estimated wait, next to the button that starts it."
  attr :quote, :string, default: nil

  def quote_note(assigns) do
    ~H"""
    <span :if={@quote} class="ic-vox-note font-mono text-[0.6875rem]">
      ≈ {@quote} on this machine
    </span>
    """
  end

  @doc """
  Grade the reference at `path`, or `nil` when there is nothing to grade.

  A file that cannot be read grades as nothing rather than as bad: the operator
  has enough to act on without the app inventing a verdict from a failed read.
  """
  @spec analyse(String.t() | nil) :: ReferenceQuality.t() | nil
  def analyse(nil), do: nil

  def analyse(path) do
    case ReferenceQuality.analyse(path) do
      {:ok, quality} -> quality
      {:error, _reason} -> nil
    end
  end

  @doc """
  The phrase for what `text` will cost, or `nil` when there is no line to price.

  An empty box gets no quote. A price for nothing reads as a price for
  something, and the fixed half of a render's cost is large enough that quoting
  it against an empty textarea would be actively misleading.
  """
  @spec phrase(String.t() | nil, number(), pos_integer() | nil) :: String.t() | nil
  def phrase(text, reference_seconds, steps) do
    if String.trim(text || "") == "" do
      nil
    else
      Calibration.phrase(text, reference_seconds || 0.0, steps)
    end
  end

  @doc """
  Put the reference's length and grade on the socket.

  The length is kept because every quote needs it — cloning conditions on the
  reference, so its seconds are paid on every render. Read here rather than per
  keystroke: `Reference.duration_seconds/1` is header-only, but the grade behind
  it decodes the file, and re-grading on each character typed would be a strange
  way to make renders feel faster.
  """
  def assign_reference(socket, path) do
    socket
    |> assign(:reference_seconds, Reference.duration_seconds(path))
    |> assign(:reference_quality, analyse(path))
  end

  @doc """
  Put the quote for the current draft on the socket.

  An ASSIGN, never a call from the template. `Calibration` reads a Settings row,
  and the Vox surface renders inside StatusLive — which re-renders on every
  streamed chat token, so a quote computed in markup would be a database read
  per token of an unrelated conversation.
  """
  def assign_quote(socket) do
    config = socket.assigns[:engine_config]

    assign(
      socket,
      :clip_quote,
      phrase(
        socket.assigns[:clip_text],
        socket.assigns[:reference_seconds],
        config && config.inference_timesteps
      )
    )
  end

  defp fmt(number), do: :erlang.float_to_binary(number * 1.0, decimals: 1)
end
