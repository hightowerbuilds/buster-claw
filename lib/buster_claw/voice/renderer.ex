defmodule BusterClaw.Voice.Renderer do
  @moduledoc """
  One render at a time, cached by content, with progress on PubSub.

  ## Why a queue at all

  VoxCPM is a 2B model. Its best measured Apple figure is RTF ≈ 1.76 on an M4
  Pro, and a cold invocation pays a model load on top of that. Two of those
  running at once on a laptop that is also carrying a browser, the BEAM and an
  agent session do not take half the time each — they swap. **Serialising is not
  politeness, it is the difference between slow and unusable**, so this is a
  `GenServer` that runs exactly one child process and makes everything else wait.

  ## Why the cache is the actual feature

  Every job this app has for a speech engine renders a line that does not change:
  a notification chime, a phone greeting. Rendering "Your timer is up." twice is
  pure waste, and rendering it on the schedule path would put a multi-second model
  load between a timer firing and a sound.

  So a render is addressed by **what was asked for, not by when**: the SHA-256 of
  the exact argv, minus the output path. Identical asks resolve to the same file
  and skip the queue entirely — `render/2` returns `{:ok, path}` without waking
  this process. Change the text, the voice, the device or a flag, and it is a
  different file, because it is a different sound.

  ## What arrives from where

  A caller either gets a cache hit synchronously or a `{:queued, key}` and a
  message later on `subscribe/0`'s topic. Nothing blocks a LiveView on a render:
  minutes is a plausible duration here, and a `GenServer.call` that long is a
  crash waiting for a reason.
  """

  use GenServer

  require Logger

  alias BusterClaw.Library.Artifact
  alias BusterClaw.Voice.Engine

  @topic "voice:renders"

  # A cap rather than unbounded, because the queue holds work that takes minutes
  # each. Thirty-two is more than the whole chime set; anything past it is a bug
  # upstream, and saying so beats quietly accepting a backlog nobody will hear
  # the end of.
  @max_queue 32

  # A cold model load plus a long line. Generous on purpose — a timeout here
  # discards work that cost minutes.
  @job_timeout_ms :timer.minutes(10)

  defstruct queue: :queue.new(), size: 0, running: nil

  # ---------------------------------------------------------------------------
  # Public
  # ---------------------------------------------------------------------------

  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, :ok, name: opts[:name] || __MODULE__)

  @doc "Subscribe to `{:voice_render, key, {:ok, path} | {:error, reason}}`."
  def subscribe, do: Phoenix.PubSub.subscribe(BusterClaw.PubSub, @topic)

  @doc """
  Render `text`, or hand back the file if this exact ask has been rendered before.

  Returns `{:ok, path}` on a cache hit, `{:queued, key}` when work was accepted,
  or `{:error, reason}`. `opts` are `BusterClaw.Voice.Engine`'s, plus
  `:reference_audio` — present means clone, absent means design.
  """
  @spec render(String.t(), keyword()) ::
          {:ok, String.t()} | {:queued, String.t()} | {:error, term()}
  def render(text, opts \\ []) when is_binary(text) do
    with {:ok, args} <- args_for(text, opts) do
      key = key_for(args)
      path = cached_path(key)

      cond do
        File.regular?(path) -> {:ok, path}
        not Engine.available?() -> {:error, :engine_unavailable}
        true -> GenServer.call(__MODULE__, {:enqueue, key, args})
      end
    end
  end

  @doc "How many renders are waiting, not counting the one in flight."
  def queue_depth, do: GenServer.call(__MODULE__, :queue_depth)

  @doc "Where rendered lines are cached. Inside the workspace, so it is visible and backed up."
  def cache_dir, do: Artifact.workspace_path(["sounds", "voice"])

  @doc "Create the cache directory. Safe to call repeatedly."
  def ensure do
    File.mkdir_p(cache_dir())
    :ok
  end

  @doc """
  The cache path a given ask resolves to, whether or not it exists yet.

  Exposed so a caller can check for a hit without asking this process anything.
  """
  def path_for(text, opts \\ []) do
    with {:ok, args} <- args_for(text, opts), do: {:ok, cached_path(key_for(args))}
  end

  @doc """
  Take a file rendered outside this process and file it in the cache.

  **A line's identity is what was asked for, not how it was produced.** The
  engine's `batch` subcommand renders many lines in one model load — the only sane
  way to make a whole set — but it is a different invocation from the single
  render, so a naive cache key would file the same sentence in two places and
  re-render it the next time it was asked for singly. This puts a batch result
  under the *single-render* key, which is the canonical one.

  Copies rather than renames: the source may be a temp directory the caller still
  wants, and a cache entry must never be a file somebody else can move.
  """
  @spec adopt(String.t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def adopt(text, source, opts \\ []) when is_binary(text) and is_binary(source) do
    with {:ok, target} <- path_for(text, opts),
         {:ok, %File.Stat{size: size}} when size > 44 <- File.stat(source),
         :ok <- File.mkdir_p(Path.dirname(target)),
         :ok <- File.cp(source, target) do
      {:ok, target}
    else
      {:ok, %File.Stat{}} -> {:error, :empty_render}
      {:error, reason} -> {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Server
  # ---------------------------------------------------------------------------

  @impl true
  def init(:ok) do
    ensure()
    {:ok, %__MODULE__{}}
  end

  @impl true
  def handle_call({:enqueue, key, args}, _from, state) do
    cond do
      state.running == key or queued?(state, key) ->
        # The same line asked for twice while it is being made is one render, and
        # both callers hear about it on the topic.
        {:reply, {:queued, key}, state}

      state.size >= @max_queue ->
        {:reply, {:error, :queue_full}, state}

      true ->
        state = %{state | queue: :queue.in({key, args}, state.queue), size: state.size + 1}
        {:reply, {:queued, key}, maybe_start(state)}
    end
  end

  @impl true
  def handle_call(:queue_depth, _from, state), do: {:reply, state.size, state}

  @impl true
  def handle_info({:done, key, result}, state) do
    broadcast(key, result)
    {:noreply, maybe_start(%{state | running: nil})}
  end

  defp maybe_start(%__MODULE__{running: nil} = state) do
    case :queue.out(state.queue) do
      {{:value, {key, args}}, rest} ->
        run(key, args)
        %{state | queue: rest, size: state.size - 1, running: key}

      {:empty, _} ->
        state
    end
  end

  defp maybe_start(state), do: state

  # The work happens off this process so the queue stays answerable while a
  # ten-minute render is in flight.
  defp run(key, args) do
    server = self()

    Task.start(fn ->
      send(server, {:done, key, do_render(key, args)})
    end)
  end

  defp do_render(key, args) do
    path = Engine.resolve()
    target = cached_path(key)
    temp = Path.join(System.tmp_dir!(), "voice-#{key}.wav")
    args = args ++ ["--output", temp]

    task = Task.async(fn -> System.cmd(path, args, stderr_to_stdout: true) end)

    case Task.yield(task, @job_timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {_out, 0}} -> promote(temp, target)
      {:ok, {out, code}} -> fail(temp, {:exit, code, String.slice(out, -800, 800) || ""})
      nil -> fail(temp, :timeout)
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  # Atomic: the cache is only ever populated by a rename of a file that has
  # already been checked. A killed process must never leave a truncated WAV
  # sitting where a cache hit would find it and route a chime at it.
  defp promote(temp, target) do
    with {:ok, %File.Stat{size: size}} when size > 44 <- File.stat(temp),
         :ok <- File.mkdir_p(Path.dirname(target)),
         :ok <- File.rename(temp, target) do
      {:ok, target}
    else
      {:ok, %File.Stat{}} -> fail(temp, :empty_render)
      {:error, reason} -> fail(temp, reason)
    end
  end

  defp fail(temp, reason) do
    File.rm(temp)
    {:error, reason}
  end

  defp broadcast(key, result) do
    Phoenix.PubSub.broadcast(BusterClaw.PubSub, @topic, {:voice_render, key, result})
  end

  defp queued?(state, key) do
    state.queue |> :queue.to_list() |> Enum.any?(fn {queued, _} -> queued == key end)
  end

  # ---------------------------------------------------------------------------

  defp args_for(text, opts) do
    text = String.trim(text)

    cond do
      text == "" ->
        {:error, :empty_text}

      reference = opts[:reference_audio] ->
        if File.regular?(reference),
          do: {:ok, Engine.clone_args(text, "", reference, opts) |> drop_output()},
          else: {:error, :reference_missing}

      true ->
        {:ok, Engine.design_args(text, "", opts) |> drop_output()}
    end
  end

  # The output path is where the answer goes, not part of the question. Leaving
  # it in would give the same line a different cache key every time.
  defp drop_output(args) do
    case Enum.find_index(args, &(&1 == "--output")) do
      nil -> args
      index -> List.delete_at(List.delete_at(args, index), index)
    end
  end

  defp key_for(args) do
    :sha256
    |> :crypto.hash(Enum.join(args, " "))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 32)
  end

  defp cached_path(key), do: Path.join(cache_dir(), "#{key}.wav")
end
