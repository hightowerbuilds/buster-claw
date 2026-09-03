defmodule BusterClaw.Voice.Chimes do
  @moduledoc """
  The machine's spoken notifications: one short line per routing key.

  A synthesized chime tells you *that* something happened. A spoken one tells you
  **what**, from across the room, without going to look — which is the whole
  argument for putting a speech engine anywhere near the notification layer.

  ## Why these are rendered once and kept

  Every line here is fixed. "Your timer is up." does not vary, so it is rendered
  the first time and cached forever by `BusterClaw.Voice.Renderer`. That matters
  more than it sounds: rendering on the schedule path would put a multi-second
  model load between a timer firing and a sound, which is not a chime, it is a
  delayed apology.

  ## The lines are the operator's, not ours

  They are seeded, and every one is editable. This is the machine talking to the
  person who owns it; a sentence he cannot change is a sentence he will stop
  hearing. Defaults live in code, overrides in Settings, and `reset/1` puts a key
  back.

  ## Nothing spoken is bundled

  Rendering at build time would ship *somebody's* voice inside the DMG, which is
  the opposite of the point and about 1.6 MB of it. The spoken set is rendered on
  the operator's machine, into his workspace, in whatever voice he chose.
  """

  alias BusterClaw.Notifications.Sound
  alias BusterClaw.Settings
  alias BusterClaw.Voice.Engine
  alias BusterClaw.Voice.Renderer

  @settings_key "voice_chime_lines"

  # One per live routing key. Short on purpose: a spoken chime competes with
  # whatever the person is already doing, and a sentence is already long.
  #
  # `order` is deliberately absent — it is a Trading leftover whose routing slot
  # survives but which `SoundBoard.event_key/1` can no longer emit, so a line for
  # it would be a line nobody will ever hear.
  @defaults %{
    "default" => "Something needs you.",
    "timer" => "Your timer is up.",
    "alarm" => "Alarm.",
    "reminder" => "Reminder.",
    "chat" => "New message.",
    "terminal" => "The terminal wants you.",
    "email" => "Mail arrived.",
    "voicemail" => "You have a voicemail.",
    "sms" => "A text arrived.",
    "manual" => "Here you go.",
    "confirm" => "I need a confirmation.",
    "shift" => "The shift is over.",
    "blocked" => "I'm blocked.",
    "web" => "The browser needs you.",
    "security" => "Security event.",
    "boot" => "Buster Claw is up."
  }

  @doc "The seeded lines, before any of the operator's edits."
  @spec defaults() :: %{String.t() => String.t()}
  def defaults, do: @defaults

  @doc "Every routing key that has a spoken line, in the order they are shown."
  @spec keys() :: [String.t()]
  def keys do
    Sound.route_keys() |> Enum.filter(&Map.has_key?(@defaults, &1))
  end

  @doc "The current lines: the defaults with the operator's edits over the top."
  @spec lines() :: %{String.t() => String.t()}
  def lines, do: Map.merge(@defaults, stored())

  @doc "The line for one key."
  @spec line(String.t()) :: String.t() | nil
  def line(key) when is_binary(key), do: Map.get(lines(), key)

  @doc """
  Change a line.

  A blank line resets the key to its default rather than storing an empty string:
  silence is expressed by routing the key at nothing, not by a chime that says
  nothing.
  """
  @spec put_line(String.t(), String.t()) :: :ok | {:error, term()}
  def put_line(key, text) when is_binary(key) and is_binary(text) do
    cond do
      key not in keys() -> {:error, :unknown_key}
      String.trim(text) == "" -> reset(key)
      true -> persist(Map.put(stored(), key, String.trim(text)))
    end
  end

  @doc "Put one key back to its seeded line."
  @spec reset(String.t()) :: :ok | {:error, term()}
  def reset(key) when is_binary(key) do
    if key in keys(), do: persist(Map.delete(stored(), key)), else: {:error, :unknown_key}
  end

  @doc "Put every line back."
  @spec reset_all() :: :ok | {:error, term()}
  def reset_all, do: persist(%{})

  @doc """
  Ask for one key's line to be rendered.

  `{:ok, path}` when it is already in the cache, `{:queued, render_key}` when it
  went to the queue and will arrive on `Renderer.subscribe/0`'s topic.
  """
  @spec render(String.t(), keyword()) ::
          {:ok, String.t()} | {:queued, String.t()} | {:error, term()}
  def render(key, opts \\ []) when is_binary(key) do
    case line(key) do
      nil -> {:error, :unknown_key}
      text -> Renderer.render(text, opts)
    end
  end

  @doc """
  Ask for the whole set, one `Renderer` job per line.

  Correct but wasteful: each job is its own process and pays the model load
  again. **Measured on the Intel dev machine 09-02-26: 2 min 29 s of warm-up
  before any audio.** Sixteen of those is forty minutes spent loading the same
  weights. Prefer `render_set/1`, which is the same work in one invocation.

  This stays because it is the path that reports progress per line — the queue
  broadcasts each result as it lands, so a surface can fill in rather than wait.
  """
  @spec render_all(keyword()) :: [{String.t(), term()}]
  def render_all(opts \\ []) do
    Enum.map(keys(), fn key -> {key, render(key, opts)} end)
  end

  @doc """
  Render the whole set in **one** engine invocation — one model load for sixteen
  lines instead of sixteen.

  Blocking and slow by nature; call it from a task, not a render.

  ## The mapping, read out of `voxcpm/cli.py` rather than guessed

  `batch` writes `output_001.wav`, `output_002.wav`, … into `--output-dir`, and
  the number is the **position of the line in the input file**. Two properties of
  its loop make that safe to rely on, and both were checked in the source:

  * blank lines are dropped *before* indexing, so a blank would shift every file
    after it — this writes no blank lines, and refuses if a line is empty;
  * a line that raises still advances the counter, so a failure leaves a **gap**
    rather than shifting the rest. A missing file is a missing chime, never the
    wrong chime under the right name.

  That second property is the whole reason this is safe to do positionally. Get
  it wrong and a timer plays "Security event."
  """
  @spec render_set(keyword()) ::
          {:ok, [{String.t(), {:ok, String.t()} | {:error, term()}}]} | {:error, term()}
  def render_set(opts \\ []) do
    ordered = Enum.map(keys(), fn key -> {key, line(key)} end)

    if Enum.any?(ordered, fn {_key, text} -> blank?(text) end) do
      {:error, :blank_line}
    else
      {cached, missing} = Enum.split_with(ordered, fn {_key, text} -> cached?(text, opts) end)

      cond do
        missing == [] -> {:ok, merge(ordered, cached_results(cached, opts), [])}
        not Engine.available?() -> {:error, :engine_unavailable}
        true -> batch_missing(ordered, cached, missing, opts)
      end
    end
  end

  # Only the lines that are not already made. Editing one chime and pressing the
  # button again must cost one render, not sixteen — and on this hardware the
  # difference between those is about forty minutes.
  defp batch_missing(ordered, cached, missing, opts) do
    case run_batch(missing, opts) do
      {:ok, rendered} -> {:ok, merge(ordered, cached_results(cached, opts), rendered)}
      {:error, _reason} = error -> error
    end
  end

  defp cached?(text, opts) do
    match?({:ok, path} when is_binary(path), Renderer.path_for(text, opts)) and
      Renderer.path_for(text, opts) |> elem(1) |> File.regular?()
  end

  defp cached_results(cached, opts) do
    Enum.map(cached, fn {key, text} ->
      {:ok, path} = Renderer.path_for(text, opts)
      {key, {:ok, path}}
    end)
  end

  # Put the answers back in `keys()` order, whichever half they came from.
  defp merge(ordered, from_cache, from_engine) do
    answers = Map.new(from_cache ++ from_engine)

    Enum.map(ordered, fn {key, _text} -> {key, Map.get(answers, key, {:error, :not_rendered})} end)
  end

  defp run_batch(ordered, opts) do
    dir = Path.join(System.tmp_dir!(), "voice-set-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    input = Path.join(dir, "lines.txt")
    File.write!(input, Enum.map_join(ordered, "\n", fn {_key, text} -> text end) <> "\n")

    args = Engine.batch_args(input, dir, opts)

    case System.cmd(Engine.resolve(), args, stderr_to_stdout: true) do
      {_output, 0} ->
        {:ok, collect(ordered, dir, opts)}

      {output, code} ->
        {:error, {:exit, code, String.slice(output, -800, 800) || ""}}
    end
  end

  # Each output is filed in the render cache under its single-render key, so the
  # next press of the button finds it rather than making it again. The temp
  # directory this batch wrote into is not somewhere a chime should live.
  defp collect(ordered, dir, opts) do
    ordered
    |> Enum.with_index(1)
    |> Enum.map(fn {{key, text}, index} ->
      path = Path.join(dir, "output_#{String.pad_leading(to_string(index), 3, "0")}.wav")

      # `adopt/3` checks the size, so a file that is present and empty is a
      # failure rather than a chime nobody can hear.
      case Renderer.adopt(text, path, opts) do
        {:ok, cached} -> {key, {:ok, cached}}
        {:error, _reason} -> {key, {:error, :not_rendered}}
      end
    end)
  end

  defp blank?(text), do: not is_binary(text) or String.trim(text) == ""

  @doc """
  Install a rendered line as the chime for `key`, and route the key at it.

  Overwrites in place, deliberately: re-rendering a line after editing it must
  replace that chime, not leave the old one behind under a freed-up name and
  quietly keep playing it.
  """
  @spec install(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def install(key, path) when is_binary(key) and is_binary(path) do
    name = installed_name(key)

    with true <- key in keys() || {:error, :unknown_key},
         true <- File.regular?(path) || {:error, :not_found},
         :ok <- File.mkdir_p(Sound.dir()),
         :ok <- File.cp(path, Path.join(Sound.dir(), name)),
         :ok <- Sound.assign(key, name) do
      {:ok, name}
    else
      {:error, _reason} = error -> error
      false -> {:error, :unknown_key}
      other -> other
    end
  end

  @doc "The library filename a key's spoken chime is installed under."
  @spec installed_name(String.t()) :: String.t()
  def installed_name(key), do: "voice-#{key}.wav"

  @doc "True when `key` is currently routed at its spoken chime."
  @spec installed?(String.t()) :: boolean()
  def installed?(key), do: Sound.sound_map()[key] == installed_name(key)

  # ---------------------------------------------------------------------------

  defp stored do
    case Settings.get(@settings_key) do
      nil ->
        %{}

      json ->
        case Jason.decode(json) do
          {:ok, map} when is_map(map) ->
            Map.filter(map, fn {k, v} -> is_binary(k) and is_binary(v) end)

          _ ->
            %{}
        end
    end
  end

  defp persist(map) when map == %{} do
    with {:ok, _} <- Settings.put(@settings_key, "{}"), do: :ok
  end

  defp persist(map) do
    with {:ok, _} <- Settings.put(@settings_key, Jason.encode!(map)), do: :ok
  end
end
