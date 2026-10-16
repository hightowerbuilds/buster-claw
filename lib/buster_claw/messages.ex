defmodule BusterClaw.Messages do
  @moduledoc """
  Apple Messages text integration.

  First increment: an explicit, read-only readiness probe. No ingestion, sending,
  application-boot side effects, or changes to existing routing.
  """

  alias BusterClaw.Messages.Connection
  alias BusterClaw.ShellPath

  @doc "Probe a local adapter; return only redacted readiness, never message content."
  def probe(opts \\ []) do
    with {:ok, binary} <- resolve(opts),
         {:ok, pid} <- Connection.start_link(Keyword.put(opts, :binary, binary)) do
      try do
        Connection.status(pid)
      after
        GenServer.stop(pid)
      end
    end
  end

  defp resolve(opts) do
    binary =
      Keyword.get_lazy(opts, :binary, fn ->
        Application.get_env(:buster_claw, :messages_binary) || bundled_binary() ||
          ShellPath.find_executable("imsg")
      end)

    if is_binary(binary) and Path.type(binary) == :absolute and File.regular?(binary),
      do: {:ok, binary},
      else: {:error, :not_installed}
  end

  @doc "The release's adapter path, when staged; independent of the launcher's PATH."
  def bundled_binary do
    path = Application.app_dir(:buster_claw, "priv/messages/imsg")
    if File.regular?(path), do: path
  end
end
