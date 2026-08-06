defmodule BusterClaw.AgentBackend do
  @moduledoc """
  What each agent CLI ("harness") is, and how to invoke it non-interactively.

  Buster Claw has always had two backends in the code and only ever really had
  one. `AgentRunner.detect/0` fell back to `codex` on PATH order, and
  `default_args(:codex, prompt, _opts)` was `["exec", prompt]` — no model, no
  permission mode, no streaming. This module is the table that makes `codex` and
  `opencode` real, and it is where a fourth would be added.

  ## Measured, not recalled

  Every flag below came from running `--help` against the installed binary on
  08-03-26 (`claude` 2.1.220, `codex-cli` 0.146.0, `opencode` 1.18.3), because
  the roadmap this replaces asserted "`--model` is claude-only by construction"
  and was wrong — codex has taken `-m` all along. See
  `daily-growth/archive/08-04-26-agent-backend-roadmap.md` for the full probe log,
  including the event schemas and the two findings marked ⚠ there.

  ## The three ways a harness is confined

  This is the axis that matters, because it is the one the money surfaces care
  about and the one that differs most:

  - `:flags` (claude) — `--allowedTools` / `--disallowedTools` / `--mcp-config`,
    expressed per invocation. `--strict-mcp-config` scopes MCP to exactly the
    given file.
  - `:sandbox` (codex) — `-s read-only | workspace-write | danger-full-access`,
    an OS-level sandbox. Stronger than a flag allowlist for filesystem reach, but
    **it does not scope MCP**: `-c` merges into the operator's config and cannot
    remove servers, so a codex run also sees whatever MCP servers the operator
    has configured. There is no verified `--strict-mcp-config` equivalent.
  - `:agent_file` (opencode) — a `.opencode/agent/<name>.md` in the working
    directory, named at run time with `--agent`.

  **⚠ The opencode path fails OPEN.** A missing or misnamed agent file does not
  fail the run — opencode prints `agent "x" not found. Falling back to default
  agent` on stderr and runs anyway, at exit status 0, under the default `build`
  agent whose permission is `{"*", allow, "*"}`. Confinement that evaporates
  silently is worse than none, so `fallback_warning?/2` exists and callers on a
  confined surface must treat it as a failed run. It is not optional politeness.

  ## Model namespaces are not interchangeable

  `claude` and `codex` take a bare ID; `opencode` takes `provider/model`
  (`opencode-go/glm-5.1`). A model string is only meaningful inside its harness,
  which is why `ModelPolicy` keys models by `{backend, surface}` rather than
  storing one string per surface.

  Only opencode will enumerate (`opencode models` — 23 entries on the operator's
  machine, reflecting *their* authenticated providers, so it is per-machine and
  must be read live rather than shipped). claude and codex cannot enumerate, so
  they ship a fixed list instead — and free text stays available on every
  backend, because a shipped list is a convenience that goes stale and never a
  gate.
  """

  # Ordered: this is also the PATH-detection fallback order, so it is
  # behaviour, not presentation. claude first preserves what every existing
  # install does today; opencode is appended last so adding it cannot change
  # the backend on a machine that already had claude or codex.
  @order [:claude, :codex, :opencode]

  @backends %{
    claude: %{
      label: "Claude Code",
      executable: "claude",
      confinement: :flags,
      model_namespace: :bare,
      enumerates_models?: false,
      # CORRECTED 08-03. Both roadmaps said "the CLI does not report spend back to
      # us"; the tutorial and the summary repeated it. It was never true —
      # claude's `result` event carries `total_cost_usd`, `usage`, `num_turns`
      # and `modelUsage`, and `StreamEvent` has parsed the cost field the whole
      # time. Measured: `total_cost_usd = 0.0802325` on a one-word prompt.
      reports_usage: :cost,
      known_models: [
        "claude-fable-5",
        "claude-opus-5",
        "claude-sonnet-5",
        "claude-haiku-4-5"
      ]
    },
    codex: %{
      label: "Codex CLI",
      executable: "codex",
      confinement: :sandbox,
      model_namespace: :bare,
      enumerates_models?: false,
      # `turn.completed` carries a `usage` object but no dollar figure, and this
      # app owns no price table — a computed cost would be a number the operator
      # trusts and we invented.
      reports_usage: :tokens,
      # Added 08-04 at the operator's request, reversing "ship no list for a
      # harness that cannot enumerate". The reason for that rule — a fixed list
      # goes stale — is real but is covered by the free-text field, which stays;
      # the cost of NO list is that every codex user types an ID by hand.
      #
      # Codex does not validate the model up front (a nonsense ID is passed
      # straight through to the provider), so a wrong entry here fails late and
      # confusingly. Evidence for each, so the next person can tell what was
      # measured from what was inferred:
      #   gpt-5.6-sol   — the operator's own ~/.codex/config.toml
      #   gpt-5.6-luna  — present in `opencode models` as opencode-go/gpt-5.6-luna
      #   gpt-5.6-terra — named by the operator; follows the family pattern, NOT
      #                   independently verified against a catalog
      # Listed in the order the operator named them, not by capability: nothing
      # here ranks them, and inventing an order would imply knowledge we lack.
      known_models: [
        "gpt-5.6-sol",
        "gpt-5.6-terra",
        "gpt-5.6-luna"
      ]
    },
    opencode: %{
      label: "OpenCode",
      executable: "opencode",
      confinement: :agent_file,
      model_namespace: :provider_slash_model,
      enumerates_models?: true,
      # `step_finish` carries `tokens` AND a `cost` figure — the only backend
      # that tells us what a run actually cost.
      reports_usage: :cost,
      known_models: []
    }
  }

  # opencode's warning when `--agent` names something it cannot find. It then
  # runs UNCONFINED and exits 0, so this string is a safety control, not a log
  # line. Matched case-insensitively on a substring because the surrounding text
  # carries ANSI colour codes.
  @opencode_fallback "falling back to default agent"

  @doc "Backend keys, in PATH-detection fallback order."
  def order, do: @order

  @doc "True if `backend` is one this module knows how to invoke."
  def known?(backend), do: Map.has_key?(@backends, backend)

  @doc "The full descriptor for `backend`, or `nil`."
  def get(backend), do: Map.get(@backends, backend)

  @doc "Human label for the harness picker."
  def label(backend), do: fetch(backend, :label, to_string(backend))

  @doc "The executable name to look for on PATH."
  def executable(backend), do: fetch(backend, :executable, nil)

  @doc """
  How this harness expresses confinement — `:flags`, `:sandbox`, or
  `:agent_file`. See the moduledoc; this is the axis the money surfaces care
  about.
  """
  def confinement(backend), do: fetch(backend, :confinement, nil)

  @doc "`:bare` or `:provider_slash_model`. A model string is only valid in its own namespace."
  def model_namespace(backend), do: fetch(backend, :model_namespace, :bare)

  @doc "True if the CLI can list its own models (`opencode models`)."
  def enumerates_models?(backend), do: fetch(backend, :enumerates_models?, false)

  @doc "`:none`, `:tokens`, or `:cost` — what the CLI reports back about spend."
  def reports_usage(backend), do: fetch(backend, :reports_usage, :none)

  @doc """
  The models to offer for `backend` without asking the CLI.

  Empty for opencode on purpose: its real list is per-machine (it depends on
  which providers the operator has authenticated), so it is read live via
  `enumerate_models/1` rather than shipped. claude and codex ship fixed lists
  because neither can enumerate. Free text remains available on every backend.
  """
  def known_models(backend), do: fetch(backend, :known_models, [])

  @doc """
  True when `backend`'s executable is on PATH.

  A harness the operator does not have installed must read as *unavailable* in
  the picker rather than selectable-and-broken — choosing it would otherwise
  produce `{:error, :agent_unavailable}` at the moment a run was expected.
  """
  def available?(backend) do
    case executable(backend) do
      name when is_binary(name) -> System.find_executable(name) != nil
      _ -> false
    end
  end

  @doc "The subset of `order/0` actually installed on this machine."
  def installed, do: Enum.filter(order(), &available?/1)

  @doc """
  Ask `backend`'s CLI to list its own models.

  Only opencode can (`opencode models`); everything else returns `{:error,
  :not_enumerable}` and must fall back to `known_models/1` plus free text.

  **This shells out — never call it from a LiveView render or a GenServer's
  `init/1`.** Resolve it in a Task and cache the result. The list is also
  *per-machine*: it reflects which providers this operator has authenticated
  (23 entries on the author's machine), so it can be neither shipped nor shared.
  """
  def enumerate_models(backend, opts \\ []) do
    with true <- enumerates_models?(backend),
         name when is_binary(name) <- executable(backend),
         path when is_binary(path) <- System.find_executable(name) do
      run_enumerate(path, Keyword.get(opts, :timeout_ms, 15_000))
    else
      false -> {:error, :not_enumerable}
      _ -> {:error, :not_installed}
    end
  end

  defp run_enumerate(path, timeout_ms) do
    task =
      Task.async(fn ->
        System.cmd(path, ["models"], stderr_to_stdout: true)
      end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, 0}} -> {:ok, parse_model_lines(output)}
      {:ok, {_output, status}} -> {:error, {:exit_status, status}}
      _ -> {:error, :timeout}
    end
  rescue
    error -> {:error, {:enumerate_failed, Exception.message(error)}}
  end

  # `opencode models` prints one `provider/model` per line. Anything without a
  # slash is banner text or a warning, not a model — dropping it is safer than
  # offering the operator a model string the CLI would reject.
  defp parse_model_lines(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&String.contains?(&1, "/"))
    |> Enum.reject(&String.contains?(&1, " "))
    |> Enum.uniq()
  end

  @doc """
  A model string plausibly belongs to `backend`'s namespace.

  Deliberately permissive — it catches the one mistake that is unambiguous
  (a bare ID sent to opencode, which needs `provider/model`) and otherwise gets
  out of the way. It is a *hint for the UI*, never a gate: refusing a string we
  do not recognise would break the free-text escape hatch, and new providers
  appear faster than this table changes.
  """
  def plausible_model?(backend, model) when is_binary(model) do
    case model_namespace(backend) do
      :provider_slash_model -> String.contains?(model, "/")
      _ -> true
    end
  end

  def plausible_model?(_backend, _model), do: false

  @doc """
  The non-interactive argv for `backend`, excluding the binary itself.

  Options:

    * `:model` — the model string. `nil` **omits the flag entirely** rather than
      passing an empty one, so an unset policy leaves the CLI's own default in
      charge on every backend.
    * `:permission_mode` — claude's mode string, translated per backend by
      `permission_args/2`.
    * `:stream` — `true` adds the backend's structured-output flag.
    * `:agent` — opencode only; names a `.opencode/agent/<name>.md`.

  Order matters for codex: `exec`'s prompt is positional, so flags are emitted
  before it.
  """
  def argv(backend, prompt, opts \\ [])

  def argv(:claude, prompt, opts) do
    # `:duplex` drops the positional prompt: in streaming-input mode the prompt
    # arrives as JSONL on stdin, and `claude -p <prompt> --input-format
    # stream-json` would be giving it the first message twice. Everything else —
    # permission mode, model, confinement — is deliberately identical, so the
    # duplex path cannot quietly acquire a different posture than the one-shot
    # path it replaces.
    prompt_args = if Keyword.get(opts, :duplex, false), do: ["-p"], else: ["-p", prompt]

    prompt_args ++
      ["--permission-mode", permission_mode(opts)] ++
      model_args(:claude, opts) ++ stream_args(:claude, opts)
  end

  def argv(:codex, prompt, opts) do
    # `--skip-git-repo-check` is MANDATORY, not defensive: codex refuses to run
    # when its working root is not a git repository ("Not inside a trusted
    # directory…"), and the shipped workspace (~/Desktop/BusterClawCLI) is not
    # one. Without this, every codex run from the workspace fails.
    ["exec", "--skip-git-repo-check"] ++
      model_args(:codex, opts) ++
      permission_args(:codex, opts) ++
      stream_args(:codex, opts) ++
      [prompt]
  end

  def argv(:opencode, prompt, opts) do
    ["run"] ++
      model_args(:opencode, opts) ++
      agent_args(opts) ++
      permission_args(:opencode, opts) ++
      stream_args(:opencode, opts) ++
      [prompt]
  end

  # An unknown backend gets the prompt and nothing else — the same conservative
  # shape `AgentRunner` used before this module existed.
  def argv(_other, prompt, _opts), do: [prompt]

  @doc """
  The structured-output flag for `backend`, or `[]` when `:stream` is not set.

  Exposed separately because call sites currently hardcode claude's
  `--output-format stream-json --verbose` into `:extra_args`; they can ask here
  instead of knowing which harness they are on.
  """
  def stream_args(backend, opts \\ []) do
    cond do
      not Keyword.get(opts, :stream, false) -> []
      Keyword.get(opts, :duplex, false) -> do_duplex_args(backend)
      true -> do_stream_args(backend)
    end
  end

  # Streaming INPUT as well as output — the shape that lets a second user message
  # reach a turn that is already running. Measured on claude 2.1.222; see
  # `scripts/probe_claude_duplex.exs`.
  #
  # `--replay-user-messages` is not optional decoration: it is the only evidence
  # the harness accepted a message at all. Without it "accepted" would be an
  # assumption, and the UI would be free to claim STEERED for a message that
  # never landed.
  #
  # Only claude has this mode. codex and opencode get their ordinary streaming
  # flags rather than a flag they would reject — their live paths are servers
  # (Phases 3 and 4), not a duplex pipe.
  defp do_duplex_args(:claude),
    do: do_stream_args(:claude) ++ ["--input-format", "stream-json", "--replay-user-messages"]

  defp do_duplex_args(other), do: do_stream_args(other)

  defp do_stream_args(:claude), do: ["--output-format", "stream-json", "--verbose"]
  defp do_stream_args(:codex), do: ["--json"]
  defp do_stream_args(:opencode), do: ["--format", "json"]
  defp do_stream_args(_other), do: []

  @doc """
  Translate claude's permission-mode string into `backend`'s equivalent.

  The mapping is a judgement call and is therefore written down rather than
  inferred:

  | claude mode | codex | opencode |
  |---|---|---|
  | `dontAsk` | `-s read-only` | *(nothing — see below)* |
  | anything else, incl. `bypassPermissions` | `-s workspace-write` | `--auto` |

  `dontAsk` is the mode the trading surfaces use, and on claude it is paired with
  an explicit tool allowlist. codex's `read-only` sandbox is a genuine analogue
  for a *read* surface.

  **`bypassPermissions` deliberately does NOT become `-s danger-full-access`.**
  The literal translation is tempting — both mean "stop asking me" — but they are
  not the same thing. On claude, `bypassPermissions` waives the *approval prompt*
  while the tool allowlist still binds. codex's `danger-full-access` waives the
  *sandbox itself*. Mapping one to the other would silently escalate every
  existing headless run the moment its backend changed, which is precisely the
  class of surprise this roadmap exists to avoid. `workspace-write` keeps the
  no-prompting property, and an action outside the workspace is *refused* rather
  than hanging on an approval nobody can give. A caller that genuinely wants
  codex's full-access mode can pass it through `:extra_args`, where it is
  visible.

  **opencode has no read-only analogue at all** — its only run-level knob is
  `--auto` (approve everything), so confinement there must come from an agent
  file. Emitting nothing for `dontAsk` is correct: it leaves opencode's own
  permission records in charge rather than escalating to approve-all.
  """
  def permission_args(backend, opts \\ [])

  def permission_args(:codex, opts) do
    case permission_mode(opts) do
      "dontAsk" -> ["-s", "read-only"]
      _ -> ["-s", "workspace-write"]
    end
  end

  def permission_args(:opencode, opts) do
    case permission_mode(opts) do
      "bypassPermissions" -> ["--auto"]
      _ -> []
    end
  end

  def permission_args(_backend, _opts), do: []

  @doc """
  True when `output` shows opencode silently fell back to its default (unconfined)
  agent.

  **A confined surface must treat this as a failed run, not a warning.** opencode
  exits 0 in this case and the only signal is this line on stderr, which
  `AgentRunner` merges into stdout. Checking the exit status alone would accept a
  run that executed with `{"*", allow, "*"}` permissions.

  `backend` is taken so the check reads honestly at call sites on any harness;
  it is only ever true for opencode.
  """
  def fallback_warning?(backend, output)

  def fallback_warning?(:opencode, output) when is_binary(output),
    do: String.contains?(String.downcase(output), @opencode_fallback)

  def fallback_warning?(_backend, _output), do: false

  defp model_args(backend, opts) do
    case Keyword.get(opts, :model) do
      model when is_binary(model) and model != "" -> model_flag(backend) ++ [model]
      _ -> []
    end
  end

  # Every backend spells it `--model`, and every backend also accepts `-m`
  # except claude. Use the long form throughout: identical meaning, and an argv
  # that can be read in a log without a lookup table.
  defp model_flag(_backend), do: ["--model"]

  defp agent_args(opts) do
    case Keyword.get(opts, :agent) do
      name when is_binary(name) and name != "" -> ["--agent", name]
      _ -> []
    end
  end

  defp permission_mode(opts), do: Keyword.get(opts, :permission_mode, "bypassPermissions")

  defp fetch(backend, key, default) do
    case Map.get(@backends, backend) do
      %{} = descriptor -> Map.get(descriptor, key, default)
      _ -> default
    end
  end
end
