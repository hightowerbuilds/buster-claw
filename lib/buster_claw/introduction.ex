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
  alias BusterClaw.Seed

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
  #
  # `{{COMMAND_SURFACE}}` lives at the END of the LAST file, and that is load-
  # bearing twice over. `01-orientation.md` tells the model the generated catalog
  # is "at the end of this file" — it was not, until 09-05: the placeholder sat in
  # `08-…`, leaving ~110 lines of hand-written prose stranded below a 213-row
  # table. And `introduction_test.exs` splits the document on the sentence that
  # introduces that table to test the half a human wrote; with the placeholder
  # mid-document, every guard silently stopped short of the last section. A new
  # section goes ABOVE the command surface, not after it.
  @sections [
    "01-orientation.md",
    "02-activity-record.md",
    "03-jobs-and-phone.md",
    "04-startup.md",
    "05-browsing.md",
    "06-documents-and-services.md",
    "07-notify-memory-shaders.md",
    "08-skills-and-commands.md",
    "09-sound-pockets-and-chrome.md"
  ]

  for section <- @sections do
    @external_resource Path.join(@dir, section)
  end

  @markdowns Map.new(@sections, &{&1, File.read!(Path.join(@dir, &1))})

  # ── The brief: CLAUDE.md and AGENTS.md at the workspace root ─────────────
  #
  # THREE_DOORS Phase 1. The chat's cwd is the workspace root, and every
  # supported harness reads a memory file from cwd on its own — Claude Code
  # `CLAUDE.md`, Codex and OpenCode `AGENTS.md` — at zero per-turn cost. The full
  # introduction is ~17k tokens and the shipped chat transports re-send the
  # system-prompt addendum on EVERY turn, so it cannot go there; this ~350-word
  # brief can go on disk, and it points at the full document for the rest.
  #
  # It is NOT part of `@sections`: `markdown/0` is the full guide and the brief
  # is the thing that points at it.
  #
  # Deliberately no `{{WORKSPACE_ROOT}}` inside: the bytes must be identical on
  # every machine, or `BusterClaw.Seed`'s digest list could never recognise a
  # shipped version and every install would look "edited" forever.
  @brief_file "00-brief.md"
  @external_resource Path.join(@dir, @brief_file)
  @brief File.read!(Path.join(@dir, @brief_file))
  @brief_names ~w(CLAUDE.md AGENTS.md)

  # Every version of the brief ever shipped, as sha256 digests, oldest first,
  # current last — the same contract as `BusterClaw.Jobs`. **When you edit
  # `introduction/00-brief.md`, APPEND its new digest here**; never replace or
  # reorder. `BusterClaw.SeedTest` fails with the digest to add if you forget.
  @brief_versions [
    "da2e2de14553cbca833643041b27cddcc97cbc3d626625e17877a2ffe0234d9f"
  ]

  @doc "Absolute path of the installed introduction in the current workspace."
  def path, do: Artifact.workspace_path(@rel)

  @doc "The seeded brief — identical bytes for `CLAUDE.md` and `AGENTS.md`."
  def brief, do: @brief

  @doc """
  The one paragraph the home chat appends to its system prompt so a harness that
  skipped the on-disk brief still knows where it is. Under a hundred tokens, on
  purpose: it is re-sent every turn on the shipped transports.
  """
  def pointer do
    "You are running inside Buster Claw, a Mac app that gives you a command " <>
      "surface for the operator's mail, calendar, notes, documents, browser and " <>
      "more through the `./buster-claw` CLI in the current folder. Read " <>
      "`CLAUDE.md` in that folder first; `.buster-claw/INTRODUCTION.md` is the " <>
      "full guide."
  end

  @doc """
  Seed manifest for `BusterClaw.SeedTest`: one entry per seeded brief filename,
  each with the current content and the full version list.
  """
  def seed_manifest do
    for name <- @brief_names do
      %{name: name, content: @brief, versions: @brief_versions}
    end
  end

  @doc """
  Write `CLAUDE.md` and `AGENTS.md` at the workspace root through
  `BusterClaw.Seed`, so an unedited copy upgrades when the brief improves and an
  edited one is the operator's. Best-effort; returns `{:ok, outcomes}` keyed by
  filename, or `:error`.
  """
  def ensure_briefs do
    File.mkdir_p!(Artifact.workspace_root())

    outcomes =
      Map.new(@brief_names, fn name ->
        {:ok, outcome} = Seed.write(Artifact.workspace_path(name), @brief, @brief_versions)
        {name, outcome}
      end)

    {:ok, outcomes}
  rescue
    error ->
      Logger.warning("Brief seeding failed: #{Exception.message(error)}")
      :error
  end

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

  # Markdown list of the command catalog grouped by trust tier.
  defp command_surface_markdown do
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
      "- `#{Map.fetch!(cmd, :name)}`#{gate_marker(cmd)} — #{Map.get(cmd, :description, "")}"
    end)
  end

  # The prose above names roughly a dozen commands as "gated" in passing, and
  # nothing in the generated list agreed with it — leaving the model to guess
  # which of 100-odd restricted verbs stop for a human every time. Read off the
  # same `gated:` field `PolicyEngine` enforces, so the two cannot drift.
  defp gate_marker(%{gated: true}), do: " **(gated)**"
  defp gate_marker(_cmd), do: ""

  defp tier(cmd), do: Map.get(cmd, :tier, :safe)
end
