defmodule Mix.Tasks.Messages.Probe do
  @shortdoc "Check the pinned iMessage adapter without reading conversations or sending"
  @moduledoc """
  Run `mix messages.probe --binary /absolute/path/to/imsg`.

  Optional `--database /absolute/path/to/fixture.db` selects a synthetic database
  for development. Without it the helper probes its default Messages database.
  The output is redacted readiness JSON; account/login and send permission remain
  unverified. This does not start Phoenix, pollers, or the application database.
  A successful terminal probe is not packaged-app permission evidence.
  """
  use Mix.Task

  @impl true
  def run(args) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: [binary: :string, database: :string])

    if rest != [] or invalid != [],
      do: Mix.raise("Use --binary PATH and optionally --database PATH")

    Mix.Task.run("app.config")
    opts = Enum.map(opts, fn {key, path} -> {key, Path.expand(path)} end)

    case BusterClaw.Messages.probe(opts) do
      {:ok, status} -> Mix.shell().info(Jason.encode!(status, pretty: true))
      {:error, reason} -> Mix.raise("Messages probe failed: #{reason}")
    end
  end
end
