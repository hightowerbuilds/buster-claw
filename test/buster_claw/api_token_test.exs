defmodule BusterClaw.ApiTokenTest do
  # Not async: tests manipulate Application env which is global.
  use ExUnit.Case, async: false

  alias BusterClaw.ApiToken

  # All three token keys are saved/restored, not just the full one: the sibling
  # tokens derive their paths from `token_path()`, so a test that presets them
  # would otherwise leak into every later test that calls `agent_value/0`.
  @token_keys [:api_token, :mcp_api_token, :agent_api_token, :api_token_path]

  setup do
    originals = Map.new(@token_keys, &{&1, Application.get_env(:buster_claw, &1)})

    tmp =
      Path.join(System.tmp_dir!(), "buster_claw_token_test_#{System.unique_integer([:positive])}")

    Enum.each(
      [:api_token, :mcp_api_token, :agent_api_token],
      &Application.delete_env(:buster_claw, &1)
    )

    Application.put_env(:buster_claw, :api_token_path, Path.join(tmp, "api_token"))

    on_exit(fn ->
      File.rm_rf!(tmp)

      Enum.each(@token_keys, fn key ->
        case Map.fetch!(originals, key) do
          nil -> Application.delete_env(:buster_claw, key)
          value -> Application.put_env(:buster_claw, key, value)
        end
      end)
    end)

    %{tmp: tmp}
  end

  test "generates a token when the file does not exist", %{tmp: tmp} do
    refute File.exists?(Path.join(tmp, "api_token"))

    token = ApiToken.value()

    assert is_binary(token)
    assert byte_size(token) >= 32
    assert File.exists?(Path.join(tmp, "api_token"))
  end

  test "returns the same token on repeated calls (cached in app env)" do
    first = ApiToken.value()
    second = ApiToken.value()
    assert first == second
  end

  test "re-reading from disk after env clear returns the persisted value", %{tmp: tmp} do
    first = ApiToken.value()
    Application.delete_env(:buster_claw, :api_token)
    second = ApiToken.value()
    assert first == second
    assert File.read!(Path.join(tmp, "api_token")) |> String.trim() == first
  end

  test "honors a pre-set :api_token Application env (never touches disk)", %{tmp: tmp} do
    Application.put_env(:buster_claw, :api_token, "preset-override")
    assert ApiToken.value() == "preset-override"
    refute File.exists?(Path.join(tmp, "api_token"))
  end

  # Clinch Phase 0. The packaged shell holds all three loopback tokens in the
  # macOS Keychain and injects them as BUSTER_CLAW_*_API_TOKEN, which
  # config/runtime.exs reads into these three app-env keys. `agent_token` was the
  # one nothing set, so it fell through to `load_or_generate/1` and persisted the
  # untrusted-provenance token to disk in the clear. This is the assertion that
  # would have caught it: with all three supplied, none of them touches disk.
  test "all three loopback tokens resolve from app env without touching disk", %{tmp: tmp} do
    Application.put_env(:buster_claw, :api_token, "env-full")
    Application.put_env(:buster_claw, :mcp_api_token, "env-mcp")
    Application.put_env(:buster_claw, :agent_api_token, "env-agent")

    assert ApiToken.value() == "env-full"
    assert ApiToken.mcp_value() == "env-mcp"
    assert ApiToken.agent_value() == "env-agent"

    for name <- ~w(api_token mcp_token agent_token) do
      refute File.exists?(Path.join(tmp, name)),
             "#{name} was written to disk despite being supplied by the shell"
    end
  end

  # The fallback still has to work for a manual release run outside the shell —
  # each sibling persists next to the full token under its own name.
  test "each sibling falls back to its own file when app env is empty", %{tmp: tmp} do
    assert is_binary(ApiToken.value())
    assert is_binary(ApiToken.mcp_value())
    assert is_binary(ApiToken.agent_value())

    assert ApiToken.value() != ApiToken.mcp_value()
    assert ApiToken.mcp_value() != ApiToken.agent_value()

    for name <- ~w(api_token mcp_token agent_token) do
      assert File.exists?(Path.join(tmp, name))
    end
  end

  @tag :posix
  test "persists at mode 0o600 and parent dir at 0o700", %{tmp: tmp} do
    ApiToken.value()

    file_path = Path.join(tmp, "api_token")
    assert File.exists?(file_path)

    {:ok, file_stat} = File.stat(file_path)
    {:ok, dir_stat} = File.stat(tmp)

    # File.stat returns mode including type bits; mask to permission bits.
    assert Bitwise.band(file_stat.mode, 0o777) == 0o600
    assert Bitwise.band(dir_stat.mode, 0o777) == 0o700
  end

  @tag :posix
  test "re-tightens mode on read when an older write left it open", %{tmp: tmp} do
    file_path = Path.join(tmp, "api_token")
    File.mkdir_p!(tmp)
    File.write!(file_path, "preexisting-token")
    File.chmod!(file_path, 0o644)

    _ = ApiToken.value()

    {:ok, stat} = File.stat(file_path)
    assert Bitwise.band(stat.mode, 0o777) == 0o600
  end
end
