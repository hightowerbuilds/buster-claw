defmodule BusterClaw.Pages do
  @moduledoc """
  Installs Buster Claw's bundled HTML **pages** into `<workspace>/pages/`, the
  home for self-contained pages opened in the in-app browser (linked from the
  homepage's Featured Pages):

  - `MANUAL.html` — the User Guide (`BusterClaw.Manual`).
  - `financial-informant.html` — the Financial Informant (`BusterClaw.FinancialInformant`).

  Pages are regenerated on launch and on workspace switch, skipping the write
  when the on-disk file already matches. Legacy installs that wrote `MANUAL.html`
  to the workspace root are cleaned up.
  """
  require Logger

  alias BusterClaw.{FinancialInformant, Manual}
  alias BusterClaw.Library.Artifact

  @subdir "pages"

  @pages [
    %{file: "MANUAL.html", render: &Manual.html/0},
    %{file: "financial-informant.html", render: &FinancialInformant.html/0}
  ]

  @doc "Absolute path of the `pages/` directory in the current workspace."
  def dir, do: Path.join(Artifact.workspace_root(), @subdir)

  @doc "Absolute path of a bundled page file."
  def path(file), do: Path.join(dir(), file)

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
  defp cleanup_legacy do
    legacy = Path.join(Artifact.workspace_root(), "MANUAL.html")
    if File.exists?(legacy), do: File.rm(legacy)
  end

  defp write_if_changed(path, content) do
    case File.read(path) do
      {:ok, ^content} -> :ok
      _ -> File.write!(path, content)
    end
  end
end
