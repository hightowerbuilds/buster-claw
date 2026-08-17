defmodule BusterClaw.BuildInfoTest do
  use ExUnit.Case, async: true

  alias BusterClaw.BuildInfo

  describe "version/0" do
    # The load-bearing one. `UPDATE_ROADMAP` D4: the updater compares the running
    # version against the feed's, so a build that disagrees with its own VERSION
    # file is either an update loop or a permanent "up to date" — both silent.
    #
    # Deliberately compared against the FILE rather than a literal. A literal
    # would have to be edited on every release, which makes it a chore that gets
    # updated reflexively rather than a check; and it would assert the version is
    # 0.1.0 rather than what this test is actually for — that the chain
    # VERSION → mix.exs → app spec → BuildInfo is unbroken.
    test "is exactly what the repo-root VERSION file says" do
      from_file =
        [__DIR__, "..", "..", "VERSION"]
        |> Path.join()
        |> File.read!()
        |> String.trim()

      assert BuildInfo.version() == from_file
      refute BuildInfo.version() == "unknown"
    end

    test "is a plain string, not a charlist" do
      # `Application.spec/2` hands back a charlist, and this is NOT about
      # rendering: HEEx renders `~c"0.1.0"` as "0.1.0", correctly — measured, not
      # assumed, after this comment first claimed the opposite.
      #
      # It is about comparison. The updater compares the running version against
      # a string parsed out of `latest.json`, and `~c"0.1.0" == "0.1.0"` is
      # **false**. A charlist here does not look wrong anywhere; it makes the
      # update check answer the same way forever — an update loop or a permanent
      # "up to date", which is exactly the pair `UPDATE_ROADMAP` D4 warns is
      # silent.
      assert is_binary(BuildInfo.version())
    end
  end

  describe "architecture/0" do
    test "is the bare token, with the vendor and OS stripped" do
      arch = BuildInfo.architecture()

      assert is_binary(arch)
      assert arch != ""

      # `:erlang.system_info(:system_architecture)` reads like
      # "x86_64-apple-darwin23.6.0". Everything from the first hyphen on is the
      # vendor/OS triple, and Phase 1's per-architecture feed keys off the head.
      refute String.contains?(arch, "-"),
             "expected a bare token, got #{inspect(arch)} — the split did not happen"
    end

    test "matches the architecture the VM actually reports" do
      expected =
        :system_architecture
        |> :erlang.system_info()
        |> to_string()
        |> String.split("-", parts: 2)
        |> List.first()

      assert BuildInfo.architecture() == expected
    end
  end

  describe "architecture_label/0" do
    test "carries the raw token as well as the friendly name" do
      # Both halves are shown on purpose: the name is what an operator
      # recognises, the token is what they read back and what names the artifact
      # they should have downloaded. A label that dropped the token would make
      # the second of those impossible.
      assert BuildInfo.architecture_label() =~ BuildInfo.architecture()
    end

    test "names the two architectures Buster Claw actually ships" do
      assert BuildInfo.architecture_label() in [
               "Apple Silicon (aarch64)",
               "Apple Silicon (arm64)",
               "Intel (x86_64)"
             ],
             """
             Unexpected architecture label: #{inspect(BuildInfo.architecture_label())}.

             Buster Claw ships one build per architecture and never a universal binary
             (APPLE_ROADMAP III.G). If a third architecture is now real, add it here AND
             to the per-architecture update feed — a feed that cannot describe this build
             will hand it someone else's bundle.
             """
    end
  end
end
