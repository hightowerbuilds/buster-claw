defmodule BusterClaw.Pages do
  @moduledoc """
  Installs Buster Claw's bundled HTML **pages** into `<workspace>/pages/`, the
  home for self-contained pages opened in the in-app browser (listed by the
  chrome's Pages button, `BusterClawWeb.BrowserPagesController`):

  - `MANUAL.html` — the User Guide (`BusterClaw.Manual`).

  Pages are regenerated on launch and on workspace switch, skipping the write
  when the on-disk file already matches. Legacy installs that wrote `MANUAL.html`
  to the workspace root — or carry retired bundled pages — are cleaned up.
  """
  require Logger

  alias BusterClaw.Library.Artifact
  alias BusterClaw.Manual

  @subdir "pages"

  @pages [
    %{file: "MANUAL.html", render: &Manual.html/0}
  ]

  # Bundled pages we used to install; removed on install! so they don't linger
  # and masquerade as agent-made pages in list/0.
  @retired_files ["financial-informant.html"]

  @bundled_files Enum.map(@pages, & &1.file)

  # How much of a page file to read when digging for its <title>.
  @title_head_bytes 65_536

  @doc "Absolute path of the `pages/` directory in the current workspace."
  def dir, do: Artifact.workspace_path(@subdir)

  @doc "Absolute path of a bundled page file."
  def path(file), do: Path.join(dir(), file)

  @doc """
  Every `.html` page in `<workspace>/pages/` as
  `%{file, title, mtime, bundled?}`, agent-made pages first (newest on top),
  the bundled pages after. `title` comes from the document's `<title>`
  (falling back to the humanized filename); `mtime` is a posix timestamp.
  """
  def list do
    case File.ls(dir()) do
      {:ok, names} ->
        names
        |> Enum.filter(&(&1 |> String.downcase() |> String.ends_with?(".html")))
        |> Enum.map(&entry/1)
        |> Enum.sort_by(&{&1.bundled?, bundled_rank(&1), -&1.mtime})

      {:error, _reason} ->
        []
    end
  end

  # Bundled pages keep their catalog order (they share an install mtime, which
  # would otherwise make their order flap); agent pages sort by mtime alone.
  defp bundled_rank(%{bundled?: false}), do: 0
  defp bundled_rank(%{file: file}), do: Enum.find_index(@bundled_files, &(&1 == file)) || 0

  defp entry(file) do
    abs = path(file)

    mtime =
      case File.stat(abs, time: :posix) do
        {:ok, %{mtime: mtime}} -> mtime
        _ -> 0
      end

    %{
      file: file,
      title: title_of(abs) || humanize(file),
      mtime: mtime,
      bundled?: file in @bundled_files
    }
  end

  # The document's <title>, from the head of the file only (pages can be MBs
  # of inlined assets; the title lives in the first few KB or not at all).
  defp title_of(abs) do
    case File.open(abs, [:read, :binary]) do
      {:ok, io} ->
        head = IO.binread(io, @title_head_bytes)
        File.close(io)
        extract_title(head)

      {:error, _reason} ->
        nil
    end
  end

  defp extract_title(head) when is_binary(head) do
    with [_, title] <- Regex.run(~r/<title[^>]*>([^<]{1,200})</i, head),
         trimmed when trimmed != "" <- title |> String.replace(~r/\s+/, " ") |> String.trim() do
      trimmed
    else
      _ -> nil
    end
  end

  defp extract_title(_no_head), do: nil

  # "sweatshirt-merchandising-report.html" -> "Sweatshirt merchandising report"
  defp humanize(file) do
    file
    |> String.replace_suffix(".html", "")
    |> String.replace(~r/[-_]+/, " ")
    |> String.capitalize()
  end

  @doc """
  Write every bundled page to `<workspace>/pages/` (skip-if-identical) and remove
  the legacy root-level `MANUAL.html`. Returns `:ok`.
  """
  def install! do
    File.mkdir_p!(dir())
    cleanup_legacy()
    Enum.each(@pages, fn p -> write_if_changed(path(p.file), p.render.()) end)
    :ok
  end

  @doc "Best-effort install; never raises (used at boot)."
  def ensure do
    install!()
  rescue
    error ->
      Logger.warning("Pages.ensure failed: #{Exception.message(error)}")
      :error
  catch
    _, _ -> :error
  end

  # MANUAL.html previously lived at the workspace root; relocate by removing it.
  # Retired bundled pages are removed from pages/ the same way.
  defp cleanup_legacy do
    legacy = Artifact.workspace_path("MANUAL.html")
    if File.exists?(legacy), do: File.rm(legacy)
    Enum.each(@retired_files, fn file -> File.rm(path(file)) end)
  end

  defp write_if_changed(path, content) do
    case File.read(path) do
      {:ok, ^content} -> :ok
      _ -> File.write!(path, content)
    end
  end
end
