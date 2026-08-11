defmodule BusterClaw.Clinch.ChokepointTest do
  @moduledoc """
  Clinch Phase 1's exit criterion: `BusterClaw.Clinch.Vault` is the **only**
  module that touches `BusterClaw.Vault`.

  It guarded two vaults until Phase 4 retired `BusterClaw.Google.Vault`
  (migration `20260810220000`). The chokepoint is why that retirement was this
  file plus a migration rather than a change to every caller — which is the
  argument Phase 1 made when it built the facade, now paid off.

  Why this is worth a test rather than a convention. The chokepoint is the whole
  argument for the Clinch existing — one place where audit, policy and the Phase
  4 re-key can be applied, instead of a rule everyone has to remember. A rule
  nobody checks is a rule that drifts back, which is exactly what
  `scripts/check_cycles.sh` was written to say about dependency cycles.

  It reads source text rather than running `mix xref`, for the same reason
  `acl_lockstep.rs` does: the property is "which files mention this", it needs no
  runtime, and it fails in the same second it breaks. Doc heredocs and comments
  are stripped first, so prose about the vaults — of which there is plenty, and
  should be — is not mistaken for a call.
  """
  use ExUnit.Case, async: true

  # The two vault implementations, and the one facade allowed to call them.
  @allowed [
    "lib/buster_claw/vault.ex",
    "lib/buster_claw/clinch/vault.ex"
  ]

  @patterns [
    "alias BusterClaw.Vault",
    "BusterClaw.Vault."
  ]

  defp lib_files do
    Path.wildcard("lib/**/*.ex")
  end

  # Keep only the parts outside `"""` heredocs (indices 0, 2, 4 … of a split on
  # the delimiter), then drop comment lines. Prose mentioning the vaults is
  # documentation, not a dependency.
  defp code_only(source) do
    source
    |> String.split(~s(\"\"\"))
    |> Enum.take_every(2)
    |> Enum.join("\n")
    |> String.split("\n")
    |> Enum.reject(&(&1 |> String.trim() |> String.starts_with?("#")))
    |> Enum.join("\n")
  end

  defp offenders do
    for path <- lib_files(),
        path not in @allowed,
        code = code_only(File.read!(path)),
        pattern <- @patterns,
        String.contains?(code, pattern) do
      {path, pattern}
    end
  end

  test "no module outside Clinch.Vault reads either vault directly" do
    assert offenders() == [],
           """
           The Clinch is the one door to the vaults, and these reach around it:

           #{offenders() |> Enum.map_join("\n", fn {path, pattern} -> "  #{path} — #{pattern}" end)}

           Call BusterClaw.Clinch.Vault instead (pass :google for the
           google_accounts *_enc columns — its default is :app, and a value
           written by one vault cannot be read by the other).
           """
  end

  # Without this, the test above passes just as happily if the patterns stop
  # matching anything at all — a stripper bug would read as a clean codebase.
  #
  # The facade is the one file that must match: the vault implementation does not
  # name itself (`defmodule BusterClaw.Vault` is neither an alias nor a call), so
  # this is the only positive control there is. It got weaker when Phase 4 removed
  # the second vault — one assertion where there were two — which is worth knowing
  # if the stripper is ever changed.
  test "the scan still sees the facade aliasing the vault" do
    code = code_only(File.read!("lib/buster_claw/clinch/vault.ex"))

    assert String.contains?(code, "alias BusterClaw.Vault"),
           "the facade no longer aliases the app vault, or the stripper ate it"
  end

  # The stripper must remove prose, or every moduledoc explaining the vaults
  # would read as a dependency — and it must not remove code.
  test "the stripper drops doc prose but keeps code" do
    source =
      ~s|defmodule X do\n  @moduledoc """\n  alias BusterClaw.Vault in prose\n  """\n  alias BusterClaw.Repo\n  # alias BusterClaw.Vault in a comment\nend\n|

    code = code_only(source)

    refute String.contains?(code, "in prose")
    refute String.contains?(code, "in a comment")
    assert String.contains?(code, "alias BusterClaw.Repo")
  end

  test "the file list is real" do
    assert length(lib_files()) > 100
    assert Enum.all?(@allowed, &File.exists?/1)
  end
end
