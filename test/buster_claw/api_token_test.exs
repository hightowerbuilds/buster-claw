defmodule BusterClaw.ApiTokenTest do
  # Not async: tests manipulate Application env which is global.
  use ExUnit.Case, async: false

  alias BusterClaw.ApiToken

  setup do
    original_token = Application.get_env(:buster_claw, :api_token)
    original_path = Application.get_env(:buster_claw, :api_token_path)

    tmp =
      Path.join(System.tmp_dir!(), "buster_claw_token_test_#{System.unique_integer([:positive])}")

    Application.delete_env(:buster_claw, :api_token)
    Application.put_env(:buster_claw, :api_token_path, Path.join(tmp, "api_token"))

    on_exit(fn ->
      File.rm_rf!(tmp)

      if original_token,
        do: Application.put_env(:buster_claw, :api_token, original_token),
        else: Application.delete_env(:buster_claw, :api_token)

      if original_path,
        do: Application.put_env(:buster_claw, :api_token_path, original_path),
        else: Application.delete_env(:buster_claw, :api_token_path)
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
