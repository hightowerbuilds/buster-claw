defmodule BusterClaw.UserGuide do
  @moduledoc """
  The in-app **User Guide** content, split into sub-tab sections. Each section is
  a markdown file under `daily-growth/user-guide/`, embedded at compile time (so
  it ships in releases and hot-reloads in dev when a file changes) and rendered to
  sanitized, blog-style HTML via `BusterClaw.Markdown`.

  Add a section by dropping a new file here and adding it to `@sections`.
  """
  @dir Path.expand(Path.join([__DIR__, "..", "..", "daily-growth", "user-guide"]))

  @sections [
    %{key: :introduction, label: "Introduction", file: "introduction.md"},
    %{key: :setup, label: "Setup", file: "setup.md"},
    %{key: :daily_loop, label: "Daily Loop", file: "daily-loop.md"}
  ]

  @external_resource Path.join(@dir, "introduction.md")
  @external_resource Path.join(@dir, "setup.md")
  @external_resource Path.join(@dir, "daily-loop.md")

  @markdowns Map.new(@sections, fn s -> {s.key, File.read!(Path.join(@dir, s.file))} end)

  @doc "Ordered sections, each `%{key, label, html}` (HTML rendered from markdown)."
  def sections do
    Enum.map(@sections, fn s ->
      %{
        key: s.key,
        label: s.label,
        html: BusterClaw.Markdown.to_html(Map.fetch!(@markdowns, s.key))
      }
    end)
  end

  @doc "The first section's key — the default sub-tab."
  def default_section, do: hd(@sections).key
end
