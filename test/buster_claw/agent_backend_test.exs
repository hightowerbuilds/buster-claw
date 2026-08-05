defmodule BusterClaw.AgentBackendTest do
  use ExUnit.Case, async: true

  alias BusterClaw.AgentBackend

  describe "the catalog" do
    test "every ordered backend has a full descriptor" do
      for backend <- AgentBackend.order() do
        assert AgentBackend.known?(backend)
        assert is_binary(AgentBackend.label(backend))
        assert is_binary(AgentBackend.executable(backend))
        assert AgentBackend.confinement(backend) in [:flags, :sandbox, :agent_file]
        assert AgentBackend.model_namespace(backend) in [:bare, :provider_slash_model]
        assert AgentBackend.reports_usage(backend) in [:none, :tokens, :cost]
      end
    end

    # The detection order IS behaviour: appending opencode must not change which
    # backend an install that already has claude or codex resolves to.
    test "claude is first and opencode is last in the fallback order" do
      assert List.first(AgentBackend.order()) == :claude
      assert List.last(AgentBackend.order()) == :opencode
    end

    test "an unknown backend is not known and yields safe defaults" do
      refute AgentBackend.known?(:gemini)
      assert AgentBackend.known_models(:gemini) == []
      assert AgentBackend.argv(:gemini, "hi") == ["hi"]
      assert AgentBackend.permission_args(:gemini) == []
    end

    # Shipping a stale list is worse than shipping none: codex cannot enumerate,
    # and opencode's real list depends on which providers the operator has
    # authenticated, so it is per-machine and must be read live.
    # The harnesses that cannot enumerate ship a fixed list; the one that can does
    # not, because its real list is per-machine.
    test "the non-enumerating harnesses ship a list, and the enumerating one does not" do
      assert AgentBackend.known_models(:claude) != []
      assert AgentBackend.known_models(:codex) != []
      assert AgentBackend.known_models(:opencode) == []
      assert AgentBackend.enumerates_models?(:opencode)
      refute AgentBackend.enumerates_models?(:claude)
      refute AgentBackend.enumerates_models?(:codex)
    end

    # Every shipped ID must be usable as-is. Codex does NOT validate the model up
    # front — a nonsense string is passed straight to the provider — so a typo
    # here fails late and confusingly rather than at the picker.
    test "every shipped model is a plausible ID for its own harness" do
      for backend <- AgentBackend.order(), model <- AgentBackend.known_models(backend) do
        assert AgentBackend.plausible_model?(backend, model),
               "#{model} is not valid in #{backend}'s namespace"

        refute String.contains?(model, " "), "#{model} has whitespace in it"
      end
    end

    test "codex's list is the gpt-5.6 family the operator named" do
      assert AgentBackend.known_models(:codex) == [
               "gpt-5.6-sol",
               "gpt-5.6-terra",
               "gpt-5.6-luna"
             ]
    end
  end

  describe "argv/3 — claude" do
    # The claude path must be byte-identical to what AgentRunner built before
    # this module existed, or introducing it changes every run on every install.
    test "is unchanged from the pre-existing shape" do
      assert AgentBackend.argv(:claude, "do a thing") ==
               ["-p", "do a thing", "--permission-mode", "bypassPermissions"]
    end

    test "honors an explicit permission mode and model" do
      argv =
        AgentBackend.argv(:claude, "p", permission_mode: "dontAsk", model: "claude-opus-5")

      assert argv == ["-p", "p", "--permission-mode", "dontAsk", "--model", "claude-opus-5"]
    end
  end

  describe "argv/3 — codex" do
    # Not defensive: codex refuses a non-repo working root, and the shipped
    # workspace is not a repo. Without this flag every workspace run fails.
    test "always passes --skip-git-repo-check" do
      assert "--skip-git-repo-check" in AgentBackend.argv(:codex, "p")
    end

    test "puts the prompt last, after the flags" do
      argv = AgentBackend.argv(:codex, "the prompt", model: "gpt-5.1-codex")
      assert List.last(argv) == "the prompt"
      assert List.first(argv) == "exec"
      assert "--model" in argv
    end

    test "dontAsk becomes the read-only sandbox" do
      assert AgentBackend.permission_args(:codex, permission_mode: "dontAsk") ==
               ["-s", "read-only"]
    end

    # The literal translation of bypassPermissions is danger-full-access, and
    # taking it would silently waive codex's sandbox for every existing headless
    # run the moment a backend changed. workspace-write keeps the no-prompting
    # property without that escalation.
    test "bypassPermissions does NOT waive the sandbox" do
      argv = AgentBackend.argv(:codex, "p", permission_mode: "bypassPermissions")

      assert AgentBackend.permission_args(:codex, permission_mode: "bypassPermissions") ==
               ["-s", "workspace-write"]

      refute "danger-full-access" in argv
      refute "--dangerously-bypass-approvals-and-sandbox" in argv
    end
  end

  describe "argv/3 — opencode" do
    test "names an agent file when one is given" do
      argv = AgentBackend.argv(:opencode, "p", agent: "trading-read")
      assert "--agent" in argv
      assert "trading-read" in argv
    end

    test "omits --agent when none is given" do
      refute "--agent" in AgentBackend.argv(:opencode, "p")
    end

    # opencode's only run-level knob approves everything. For a confining mode,
    # emitting nothing leaves its own permission records in charge; emitting
    # --auto would escalate.
    test "dontAsk emits nothing rather than escalating to --auto" do
      assert AgentBackend.permission_args(:opencode, permission_mode: "dontAsk") == []

      assert AgentBackend.permission_args(:opencode, permission_mode: "bypassPermissions") ==
               ["--auto"]
    end
  end

  describe "the model flag" do
    # The whole additive promise rests on this: unset means the CLI's own default
    # stays in charge, on every backend, not `--model ""`.
    test "nil, empty, and non-string models omit the flag entirely" do
      for backend <- AgentBackend.order(), model <- [nil, "", :opus, 5] do
        argv = AgentBackend.argv(backend, "p", model: model)

        refute "--model" in argv,
               "#{backend} emitted --model for #{inspect(model)}"

        refute "" in argv
      end
    end

    test "a real model reaches argv on every backend" do
      for backend <- AgentBackend.order() do
        argv = AgentBackend.argv(backend, "p", model: "some-model")
        assert "--model" in argv, "#{backend} dropped the model"
        assert "some-model" in argv
      end
    end
  end

  describe "stream_args/2" do
    test "each backend has its own structured-output flag" do
      assert AgentBackend.stream_args(:claude, stream: true) ==
               ["--output-format", "stream-json", "--verbose"]

      assert AgentBackend.stream_args(:codex, stream: true) == ["--json"]
      assert AgentBackend.stream_args(:opencode, stream: true) == ["--format", "json"]
    end

    test "nothing is emitted unless streaming was asked for" do
      for backend <- AgentBackend.order(), do: assert(AgentBackend.stream_args(backend) == [])
    end
  end

  describe "model namespaces" do
    test "opencode needs provider/model; the others take a bare id" do
      assert AgentBackend.model_namespace(:opencode) == :provider_slash_model
      assert AgentBackend.plausible_model?(:opencode, "opencode-go/glm-5.1")
      refute AgentBackend.plausible_model?(:opencode, "glm-5.1")
      assert AgentBackend.plausible_model?(:claude, "claude-opus-5")
      assert AgentBackend.plausible_model?(:codex, "anything-at-all")
    end

    test "a non-string is never plausible" do
      refute AgentBackend.plausible_model?(:claude, nil)
      refute AgentBackend.plausible_model?(:claude, :opus)
    end
  end

  # The single most important behaviour in this module. opencode does not fail
  # when `--agent` names a file it cannot find: it prints a warning to stderr,
  # falls back to the default `build` agent whose permission is {"*", allow, "*"},
  # runs the task UNCONFINED, and exits 0. Probed 08-03 against opencode 1.18.3.
  describe "fallback_warning?/2 — the fail-open guard" do
    @real_warning ~s(\e[93m\e[1m! \e[0m agent "trading-read" not found. Falling back to default agent)

    test "detects the real warning, ANSI codes and all" do
      assert AgentBackend.fallback_warning?(:opencode, @real_warning)
    end

    test "detects it when buried in a stream of JSON output" do
      output = @real_warning <> "\n" <> ~s({"type":"step_start","sessionID":"ses_1"}) <> "\n"
      assert AgentBackend.fallback_warning?(:opencode, output)
    end

    test "is quiet on a clean run" do
      refute AgentBackend.fallback_warning?(:opencode, ~s({"type":"text","part":{"text":"OK"}}))
      refute AgentBackend.fallback_warning?(:opencode, "")
    end

    test "never fires for a backend that cannot fail this way" do
      refute AgentBackend.fallback_warning?(:claude, @real_warning)
      refute AgentBackend.fallback_warning?(:codex, @real_warning)
    end

    test "tolerates a non-binary output rather than raising mid-run" do
      refute AgentBackend.fallback_warning?(:opencode, nil)
    end
  end
end
