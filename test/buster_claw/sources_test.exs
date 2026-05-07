defmodule BusterClaw.SourcesTest do
  use BusterClaw.DataCase

  alias BusterClaw.Sources

  test "creates, updates, lists, and deletes sources" do
    assert {:ok, source} =
             Sources.create_source(%{
               url: "https://example.com/feed.xml",
               type: "rss",
               name: "Example",
               tags: %{"items" => ["ai", "research"]}
             })

    assert [^source] = Sources.list_sources()

    assert {:ok, source} = Sources.update_source(source, %{enabled: false})
    refute source.enabled

    assert {:ok, _} = Sources.delete_source(source)
    assert [] = Sources.list_sources()
  end

  test "validates source type and unique url" do
    assert {:error, changeset} = Sources.create_source(%{url: "https://example.com", type: "bad"})
    assert %{type: [_]} = errors_on(changeset)

    assert {:ok, _} = Sources.create_source(%{url: "https://example.com", type: "article"})

    assert {:error, changeset} =
             Sources.create_source(%{url: "https://example.com", type: "article"})

    assert %{url: [_]} = errors_on(changeset)
  end
end
