defmodule BusterClaw.Voice.Engine do
  @moduledoc """
  Finding VoxCPM on this machine, and building the commands to drive it.

  The engine is **BYO** — discovered at runtime like `ffmpeg`, never bundled. The
  weights alone are larger than the whole DMG, and shipping somebody's voice model
  inside a 28 MB app is not a trade this product makes.

  This module answers two questions and deliberately stops there: *is there an
  engine* (`probe/0`) and *what would we run* (`design_args/3`, `clone_args/4`,
  `batch_args/3`). **It does not render.** The queue that owns
  one-render-at-a-time, the cache and the PubSub progress belong above this.

  **There is no liveness check.** `verify/0` — which ran the binary and reported
  whether it answered — was deleted 09-05 along with the "Run it" button that was
  its only caller. The operator's verdict on that button: you clicked it and read
  "It answered", which is not an experience. The information a person actually
  wants is one act further down the Vox2B surface, where typing a line and hearing
  it back is the real proof — and a broken install reports itself in the render
  note of the first thing you ask for. It is in git if a support-shaped "engine
  doctor" ever wants it.

  ## Facts read out of voxcpm 2.0.3 itself, 09-02-26 — do not re-derive

  Taken from the published wheel's `voxcpm/cli.py`, not from documentation:

  * **There is no `--version`.** Zero occurrences in the parser. A probe that
    shells `voxcpm --version` gets an argparse error and a non-zero exit, and
    would report a perfectly good install as broken. There is no version in the
    struct below for exactly this reason.
  * **There is no `--seed`** either, though it is easy to assume there is.
  * `design`, `clone`, `batch` and `validate` are the subcommands. `--output`,
    `--output-dir`, `--reference-audio`, `--prompt-audio`, `--prompt-text`,
    `--control`, `--cfg-value`, `--inference-timesteps`, `--model-path` all take
    values; `--normalize`, `--local-files-only` and `--no-denoiser` are
    `store_true` switches.
  * **`--device` defaults to `auto`.** Left alone, the device is chosen silently
    on a machine under memory pressure, so every command this module builds names
    one. Valid values are `auto`, `cpu`, `mps`, `cuda`, `cuda:N`.
  * **Running the binary at all is expensive.** `cli.py` imports only argparse,
    but the console script is `voxcpm.cli:main`, so Python imports the `voxcpm`
    package first — `__init__` → `core` → numpy, huggingface_hub and the torch
    model modules. Even `--help` pays a full torch import. **That is why `probe/0`
    never spawns anything** — and why the deleted `verify/0` could never have been
    folded into it or run automatically on page load, which is the shape the 09-05
    removal considered first and rejected on exactly this paragraph.

  ## Why resolution is not `System.find_executable/1`

  A double-clicked `.app` inherits launchd's `PATH`, which is roughly
  `/usr/bin:/bin:/usr/sbin:/sbin`. **This is not hypothetical**: the 08-15 signed
  build reported `claude`, `codex` and `opencode` all missing on a machine
  carrying all three, because detection asked the process instead of the user's
  login shell (`DMG-review-8-15`). `BusterClaw.ShellPath` exists to close that,
  and VoxCPM is a worse case than those three — it lives in a venv or a pip
  prefix, which launchd has never heard of.

  The one hardcoded candidate is `~/.buster-claw/voxcpm/bin/voxcpm`, and it is not
  a guess: it is the path the install instructions tell the operator to use. Every
  other location is the shell's business.
  """

  alias BusterClaw.ShellPath
  alias BusterClaw.Voice.Config

  @enforce_keys [:available?, :device]
  defstruct available?: false, path: nil, device: "cpu", reason: nil

  @type t :: %__MODULE__{
          available?: boolean(),
          path: String.t() | nil,
          device: String.t(),
          reason: nil | :not_installed | :not_executable
        }

  @cache_key {__MODULE__, :probe}

  # Long rather than short, and the explicit `refresh/0` is what makes that safe.
  # `:persistent_term` writes trigger a global scan, so a value re-written every
  # few seconds by a rendering LiveView is the one thing it is documented not to
  # be for. An operator who has just finished installing presses re-check; nobody
  # else needs a fresher answer than this.
  @ttl_ms :timer.minutes(5)

  # Generous on purpose: the process being timed imports torch before it prints
  # its own usage text.

  @doc """
  Where VoxCPM is, or `nil`.

  Resolved per call rather than at compile time — an operator can install it
  after the app boots, and a build that baked in "absent" would say so forever.
  """
  @spec resolve() :: String.t() | nil
  def resolve do
    # A configured path is AUTHORITATIVE — set it and nothing else is consulted,
    # even when it points at nothing.
    #
    # It used to be first-among-candidates instead, which was wrong in a way that
    # only showed up once an engine was genuinely installed on the dev machine:
    # a test setting the override to a nonexistent path fell *through* to the real
    # venv and ran the actual model, hanging for a minute. A suite whose result
    # depends on whether the developer happens to have VoxCPM installed is not a
    # suite. "Use this one" has to mean this one.
    case configured() do
      nil ->
        # The operator's own setting comes before the guesses and after the
        # app-env override (which is how tests and config files pin it). Read
        # fail-soft inside `Config.get/0`, because this runs from processes with
        # no database connection.
        [Config.engine_path(), installed_venv(), ShellPath.find_executable("voxcpm")]
        |> Enum.find(&regular_file?/1)

      path ->
        if regular_file?(path), do: path
    end
  end

  @doc """
  Cheap availability, cached for #{div(@ttl_ms, 60_000)} minutes.

  Spawns nothing. Answers from the filesystem, so it is safe to call while
  rendering. It reports what is *installed*, never whether it *runs* — nothing in
  the app answers that question any more; see the moduledoc.
  """
  @spec probe() :: t()
  def probe do
    case :persistent_term.get(@cache_key, nil) do
      {%__MODULE__{} = cached, at} ->
        if fresh?(at), do: cached, else: store(measure())

      _ ->
        store(measure())
    end
  end

  @doc "True when an engine binary is present. Sugar over `probe/0`."
  @spec available?() :: boolean()
  def available?, do: probe().available?

  @doc """
  Drop the cached probe so the next call looks again.

  This is the "I just installed it" button, and it is the reason the TTL above
  can afford to be long.
  """
  @spec refresh() :: t()
  def refresh do
    :persistent_term.erase(@cache_key)
    probe()
  end

  @doc """
  The device to name explicitly, because `auto` decides silently.

  Apple silicon gets `mps`; everything else gets `cpu`. Overridable with
  `config :buster_claw, :voxcpm_device`.
  """
  @spec device() :: String.t()
  def device do
    Application.get_env(:buster_claw, :voxcpm_device) ||
      if apple_silicon?(), do: "mps", else: "cpu"
  end

  @doc "The line to show an operator who has no engine."
  @spec install_hint() :: String.t()
  def install_hint do
    "python3 -m venv ~/.buster-claw/voxcpm && ~/.buster-claw/voxcpm/bin/pip install voxcpm"
  end

  # ---------------------------------------------------------------------------
  # Command construction — pure, so the flags are testable without an engine
  # ---------------------------------------------------------------------------

  @doc """
  Argv for `voxcpm design` — speech in a voice described by `--control`, or the
  model's default when no control is given.
  """
  @spec design_args(String.t(), String.t(), keyword()) :: [String.t()]
  def design_args(text, output, opts \\ []) do
    ["design", "--text", text, "--output", output]
    |> maybe_value("--control", opts[:control])
    |> common(opts)
  end

  @doc "Argv for `voxcpm clone` — speech in the voice of `reference_audio`."
  @spec clone_args(String.t(), String.t(), String.t(), keyword()) :: [String.t()]
  def clone_args(text, output, reference_audio, opts \\ []) do
    ["clone", "--text", text, "--output", output, "--reference-audio", reference_audio]
    |> maybe_value("--prompt-audio", opts[:prompt_audio])
    |> maybe_value("--prompt-text", opts[:prompt_text])
    |> common(opts)
  end

  @doc """
  Argv for `voxcpm batch` — many lines, one model load.

  This is the shape that makes a whole spoken chime set cheap: the cost is
  dominated by loading the model, so eighteen lines in one invocation is close to
  the price of one.
  """
  @spec batch_args(String.t(), String.t(), keyword()) :: [String.t()]
  def batch_args(input_file, output_dir, opts \\ []) do
    ["batch", "--input", input_file, "--output-dir", output_dir]
    |> maybe_value("--reference-audio", opts[:reference_audio])
    |> maybe_value("--control", opts[:control])
    |> common(opts)
  end

  # Every command names a device, and asks for no network once weights are
  # cached. `--local-files-only` defaults ON here: a render that silently reaches
  # for huggingface is a render that hangs on a plane.
  defp common(args, opts) do
    args
    |> Kernel.++(["--device", opts[:device] || device()])
    |> maybe_value("--model-path", opts[:model_path])
    |> maybe_value("--cfg-value", opts[:cfg_value])
    |> maybe_value("--inference-timesteps", opts[:inference_timesteps])
    |> maybe_switch("--normalize", opts[:normalize])
    |> maybe_switch("--no-denoiser", opts[:no_denoiser])
    |> maybe_switch("--local-files-only", Keyword.get(opts, :local_files_only, true))
  end

  defp maybe_value(args, _flag, nil), do: args
  defp maybe_value(args, flag, value), do: args ++ [flag, to_string(value)]

  # `store_true` in argparse: the flag's presence is the value, so a false or
  # absent option must add nothing rather than add `--flag false`, which argparse
  # would read as a positional argument.
  defp maybe_switch(args, flag, true), do: args ++ [flag]
  defp maybe_switch(args, _flag, _), do: args

  # ---------------------------------------------------------------------------

  defp configured, do: Application.get_env(:buster_claw, :voxcpm_path)

  # Expanded per call, never at compile time: `~` baked at build time is the
  # build machine's home, which is nobody's.
  defp installed_venv, do: Path.expand("~/.buster-claw/voxcpm/bin/voxcpm")

  defp regular_file?(nil), do: false
  defp regular_file?(path) when is_binary(path), do: File.regular?(path)
  defp regular_file?(_other), do: false

  defp measure do
    case resolve() do
      nil ->
        %__MODULE__{available?: false, device: device(), reason: :not_installed}

      path ->
        if executable?(path) do
          %__MODULE__{available?: true, path: path, device: device()}
        else
          %__MODULE__{available?: false, path: path, device: device(), reason: :not_executable}
        end
    end
  end

  # A file on disk that nobody can run is a different problem from one that is
  # not there, and it deserves a different sentence in the UI.
  defp executable?(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, mode: mode}} -> Bitwise.band(mode, 0o111) != 0
      _ -> false
    end
  end

  defp store(%__MODULE__{} = probe) do
    :persistent_term.put(@cache_key, {probe, System.monotonic_time(:millisecond)})
    probe
  end

  defp fresh?(at), do: System.monotonic_time(:millisecond) - at < @ttl_ms

  defp apple_silicon? do
    :system_architecture
    |> :erlang.system_info()
    |> to_string()
    |> String.starts_with?("aarch64")
  end
end
