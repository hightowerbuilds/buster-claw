defmodule BusterClaw.Runtime.Status do
  @moduledoc """
  Reports the local runtime state surfaced by the first rewrite status view.
  """

  alias BusterClaw.Repo

  @views [
    %{key: :home, label: "Home", path: "/"},
    %{key: :chat, label: "Chat", path: "/chat"},
    %{key: :sources, label: "Sources", path: "/sources"},
    %{key: :documents, label: "Documents", path: "/documents"},
    %{key: :analysis, label: "Analysis", path: "/analysis"},
    %{key: :calendar, label: "Calendar", path: "/calendar"},
    %{key: :gws, label: "GWS", path: "/gws"},
    %{key: :webhooks, label: "Webhooks / Hooks", path: "/webhooks"},
    %{key: :advanced, label: "Advanced", path: "/advanced"}
  ]

  @services [
    "Repo",
    "PubSub",
    "Endpoint",
    "Library",
    "Chat sessions",
    "Ingestion",
    "Analysis jobs",
    "Providers",
    "Google Workspace",
    "MCP supervisor",
    "Scheduler",
    "Webhooks",
    "Hooks",
    "Delivery",
    "Memory",
    "Calendar"
  ]

  def snapshot do
    library_root = Application.get_env(:buster_claw, :library_root)
    database_path = Repo.config() |> Keyword.get(:database)

    %{
      app: "Buster Claw",
      phase: "Phoenix skeleton",
      library_root: library_root,
      library_exists?: path_exists?(library_root),
      database_path: database_path,
      database_exists?: path_exists?(database_path),
      pubsub: inspect(BusterClaw.PubSub),
      endpoint: "127.0.0.1",
      views: @views,
      services: @services
    }
  end

  defp path_exists?(nil), do: false
  defp path_exists?(path), do: File.exists?(path)
end
