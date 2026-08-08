defmodule BusterClaw.Introduction do
  @moduledoc """
  Generates `INTRODUCTION.md` — an orientation document for the AI model: what
  Buster Claw is, the workspace layout, working conventions (chiefly that the
  Activity record is the *one* activity log), and the full CLI command surface.

  The document is installed at `.buster-claw/INTRODUCTION.md` (regenerated on
  launch and whenever the workspace changes) so the terminal agent reads it for
  orientation and the full command list. It lives in the machine-files dir, not
  the workspace root: it is a prompt for the model, and it should not be the
  loudest file in the user's personal folder — the workspace `README.md` is the
  one document addressed to the human.
  """

  require Logger

  alias BusterClaw.Commands
  alias BusterClaw.Library.Artifact

  @filename "INTRODUCTION.md"
  @rel Path.join(".buster-claw", @filename)

  # The prose lives in `introduction/*.md`, embedded at compile time — the same
  # shape `BusterClaw.UserGuide` uses for the in-app Manual, and for the same
  # two reasons: `@external_resource` makes `mix` recompile when a section
  # changes (so a dev edit is live), and `File.read!/1` at compile time bakes
  # the text into the BEAM, so the release carries it with no runtime file read.
  #
  # Repo root rather than `priv/`, matching `user-guide/`. Everything in `priv/`
  # ships loose inside the release, so putting it there would package a second
  # copy of text already compiled in — and, worse, put an editable-looking file
  # in an installed app that no edit could affect.
  #
  # It was a 657-line heredoc inside `markdown/0` until 08-08. Two holes are all
  # that was dynamic, and they are placeholders now rather than interpolation:
  # `{{WORKSPACE_ROOT}}` and `{{COMMAND_SURFACE}}`.
  @dir Path.expand(Path.join([__DIR__, "..", "..", "introduction"]))

  # Order is the document's order. A new section is a file plus a line here.
  @sections [
    "01-orientation.md",
    "02-activity-record.md",
    "03-jobs-and-phone.md",
    "04-startup.md",
    "05-browsing.md",
    "06-documents-and-services.md",
    "07-notify-memory-shaders.md",
    "08-skills-and-commands.md"
  ]

  for section <- @sections do
    @external_resource Path.join(@dir, section)
  end

  @markdowns Map.new(@sections, &{&1, File.read!(Path.join(@dir, &1))})

  @doc "The introduction file name."
  def filename, do: @filename

  @doc "Workspace-relative path of the introduction (`.buster-claw/INTRODUCTION.md`)."
  def rel_path, do: @rel

  @doc "Absolute path of the installed introduction in the current workspace."
  def path, do: Artifact.workspace_path(@rel)

  @doc """
  Write the freshly generated introduction to the workspace root, skipping the
  write when the on-disk file already matches (avoids rewriting an identical
  file on every boot and workspace switch).
  """
  def install! do
    path = path()
    File.mkdir_p!(Path.dirname(path))
    content = markdown()

    case File.read(path) do
      {:ok, ^content} -> :ok
      _ -> File.write!(path, content)
    end

    {:ok, path}
  end

  @doc "Best-effort install; never raises (used at boot)."
  def ensure do
    install!()
  rescue
    error ->
      Logger.warning("Introduction install failed: #{Exception.message(error)}")
      :error
  catch
    kind, reason ->
      Logger.warning("Introduction install failed: #{inspect({kind, reason})}")
      :error
  end

  @doc "The installed file's content, falling back to a freshly generated copy."
  def read do
    case File.read(path()) do
      {:ok, content} -> content
      {:error, _reason} -> markdown()
    end
  end

  @doc """
  The full introduction markdown — prose, conventions, and the command surface.

  Composed from `introduction/*.md` in `@sections` order. Two placeholders
  are substituted: `{{WORKSPACE_ROOT}}` and `{{COMMAND_SURFACE}}`.
  """
  def markdown do
    # Joined with "" and not "\n": each file already ends with the blank line
    # that separated its section from the next one in the original heredoc.
    @sections
    |> Enum.map_join(&Map.fetch!(@markdowns, &1))
    |> String.replace("{{WORKSPACE_ROOT}}", Artifact.workspace_root())
    |> String.replace("{{COMMAND_SURFACE}}", command_surface_markdown())
  end

  @doc "Markdown list of the command catalog grouped by trust tier."
  def command_surface_markdown do
    commands = Commands.list_commands()
    {safe, restricted} = Enum.split_with(commands, &(tier(&1) == :safe))

    [
      "### Safe (agent-callable)",
      render_commands(safe),
      "",
      "### Restricted (require confirmation)",
      render_commands(restricted)
    ]
    |> Enum.join("\n")
  end

  defp render_commands([]), do: "_None._"

  defp render_commands(commands) do
    commands
    |> Enum.sort_by(&Map.fetch!(&1, :name))
    |> Enum.map_join("\n", fn cmd ->
      "- `#{Map.fetch!(cmd, :name)}` — #{Map.get(cmd, :description, "")}"
    end)
  end

  defp tier(cmd), do: Map.get(cmd, :tier, :safe)
end
