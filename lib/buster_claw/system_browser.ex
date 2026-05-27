defmodule BusterClaw.SystemBrowser do
  @moduledoc "Opens local URLs in the user's default system browser."

  def open(url, opts \\ [])

  def open(url, opts) when is_binary(url) and url != "" do
    runner = Keyword.get(opts, :runner, &run_command/2)

    with {:ok, command, args} <- browser_command(url),
         {_output, 0} <- runner.(command, args) do
      {:ok, :opened}
    else
      {_output, status} -> {:error, {:browser_open_failed, status}}
      error -> error
    end
  end

  def open(_url, _opts), do: {:error, :missing_url}

  defp browser_command(url) do
    case :os.type() do
      {:unix, :darwin} -> {:ok, "open", [url]}
      {:unix, _name} -> {:ok, "xdg-open", [url]}
      {:win32, _name} -> {:ok, "cmd", ["/c", "start", "", url]}
      _other -> {:error, :unsupported_os}
    end
  end

  defp run_command(command, args), do: System.cmd(command, args, stderr_to_stdout: true)
end
