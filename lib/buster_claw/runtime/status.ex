defmodule BusterClaw.Runtime.Status do
  @moduledoc """
  Reports the local runtime state surfaced by the first rewrite status view.
  """

  alias BusterClaw.Repo

  @views [
    %{key: :home, label: "Home", path: "/"},
    %{key: :terminal, label: "Terminal", path: "/terminal"},
    %{key: :workspace, label: "Workspace", path: "/workspace"},
    %{key: :browse, label: "Browser", path: "/browse"},
    %{key: :calendar, label: "Calendar", path: "/calendar"},
    %{key: :gws, label: "GWS", path: "/gws"},
    %{key: :integrations, label: "Integrations", path: "/integrations"}
  ]

  @services [
    "Repo",
    "PubSub",
    "Endpoint",
    "Library",
    "Google Workspace",
    "Integrations",
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
