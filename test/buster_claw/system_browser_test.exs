defmodule BusterClaw.SystemBrowserTest do
  use ExUnit.Case, async: true

  alias BusterClaw.SystemBrowser

  test "opens a URL through the platform browser command" do
    parent = self()

    runner = fn command, args ->
      send(parent, {:browser_command, command, args})
      {"", 0}
    end

    assert {:ok, :opened} = SystemBrowser.open("https://accounts.google.com", runner: runner)
    assert_receive {:browser_command, command, args}
    assert command == expected_command()
    assert "https://accounts.google.com" in args
  end

  test "returns a bounded error when browser command fails" do
    runner = fn _command, _args -> {"nope", 1} end

    assert {:error, {:browser_open_failed, 1}} =
             SystemBrowser.open("https://accounts.google.com", runner: runner)
  end

  test "rejects a missing URL" do
    assert {:error, :missing_url} = SystemBrowser.open(nil)
  end

  defp expected_command do
    case :os.type() do
      {:unix, :darwin} -> "open"
      {:unix, _name} -> "xdg-open"
      {:win32, _name} -> "cmd"
    end
  end
end
