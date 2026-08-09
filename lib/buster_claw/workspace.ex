defmodule BusterClaw.Workspace do
  @moduledoc """
  The single declaration of what a workspace folder contains.

  Before this module the layout was an emergent property of scattered `ensure/0`
  calls: nine at boot in `Application`, three more hidden inside `Jobs.ensure/0`,
  a different and smaller set in `WorkspaceLive.set_workspace_root/1`, and the
  rest created lazily on first use. Nothing could answer "what should this folder
  contain?" — not the code, not a test, not the user. Every entry below is now
  declared in one place, and `entries/0` is that answer.

  ## Tiers

    * `:core` — the workspace is not a workspace without it. Seeded eagerly by
      `ensure/0` (or, for `shift/`, by its owner during boot).
    * `:on_demand` — a real feature, but nothing until you use it. Declared here
      so it is a known part of the layout; materialized by `ensure_entry/1` at
      the point the user asks for the feature, never at install.
    * `:transient` — appears and disappears during normal operation (a kill
      switch, a capture dir). Declared so the guard doesn't flag it; never
      created here.
    * `:deprecated` — shipped once, no longer used. `sweep_deprecated/0` removes
      it when empty.

  ## Why on-demand

  A fresh install used to lay down sixteen top-level entries, seven of which held
  nothing the user made — four directories containing only a README explaining
  what could go in them, three empty. An empty labelled drawer does not teach;
  it reads as something missing. So a folder now appears when the user opens the
  surface that owns it, which is also the moment the app can tell them what it is
  for.

  ## The guard

  `BusterClaw.WorkspaceTest` fails the build if any module writes to a top-level
  workspace path this list doesn't declare. That is what stops the next feature
  from quietly adding a twenty-first entry — which is exactly how the folder got
  this way.
  """

  require Logger

  alias BusterClaw.Library.Artifact

  # name  — the top-level entry, exactly as it appears in the folder
  # kind  — :dir | :file
  # tier  — :core | :on_demand | :transient | :deprecated (see moduledoc)
  # owner — the module that defines it
  # seed  — {module, fun} that creates/seeds it, or nil when its owner does so
  #         inline at its own write sites
  # note  — what it holds, in the user's terms
  @entries [
    # --- core: the workspace is not usable without these -------------------
    %{
      name: "README.md",
      kind: :file,
      tier: :core,
      owner: __MODULE__,
      seed: {__MODULE__, :write_readme},
      note: "What this folder is and what you can put in it. Written for you."
    },
    %{
      name: ".buster-claw",
      kind: :dir,
      tier: :core,
      owner: BusterClaw.Introduction,
      seed: {BusterClaw.Introduction, :ensure},
      note:
        "The app's machine files: INTRODUCTION.md (the agent's operating guide, " <>
          "regenerated every launch) and dispatch/ (the dated queue diary)."
    },
    %{
      name: "buster-claw",
      kind: :file,
      tier: :core,
      owner: BusterClaw.WorkspaceCLI,
      seed: {BusterClaw.WorkspaceCLI, :ensure},
      note: "The CLI launcher, so `./buster-claw` works from this folder."
    },
    %{
      name: "library",
      kind: :dir,
      tier: :core,
      owner: BusterClaw.Library.Artifact,
      seed: {BusterClaw.Library.Artifact, :ensure_workspace_dirs},
      note: "Documents the agent collected or produced (raw/, reports/)."
    },
    %{
      name: "memory",
      kind: :dir,
      tier: :core,
      owner: BusterClaw.Jobs,
      # Created by the library scaffold; its files are seeded by Jobs.
      seed: nil,
      note: "Standing policy and trusted senders/numbers."
    },
    %{
      name: "jobs",
      kind: :dir,
      tier: :core,
      owner: BusterClaw.Jobs,
      seed: {BusterClaw.Jobs, :ensure},
      note: "What each job means; edited by you, read by the agent."
    },
    %{
      name: "skills",
      kind: :dir,
      tier: :core,
      owner: BusterClaw.Skills,
      seed: {BusterClaw.Skills, :ensure},
      note: "Reusable procedures the agent can follow."
    },
    %{
      name: ".claude",
      kind: :dir,
      tier: :core,
      owner: BusterClaw.Jobs,
      # Seeded inside Jobs.ensure/0, alongside the job descriptions.
      seed: nil,
      note: "settings.json for the Claude Code session a shift runs."
    },
    %{
      name: "Dispatch.md",
      kind: :file,
      tier: :core,
      owner: BusterClaw.DispatchProjector,
      # The projector writes it on its first pass at boot.
      seed: nil,
      note: "The work queue — every open item, projected for the agent to read."
    },

    # --- on demand: real features, but nothing until you use them ----------
    %{
      name: "cmd-list",
      kind: :dir,
      tier: :on_demand,
      owner: BusterClaw.TerminalCommands,
      # No seeder: the palette runs on built-in defaults until you customize it
      # (TerminalCommands.user_doc/0 falls back), and `write_catalog/1` creates
      # the folder on that first save. Merely opening the editor writes nothing.
      seed: nil,
      note: "The terminal's command palette (catalog.json)."
    },
    %{
      name: "pages",
      kind: :dir,
      tier: :on_demand,
      owner: BusterClaw.Pages,
      seed: {BusterClaw.Pages, :ensure},
      note: "Bundled HTML pages — the Manual, the Financial Informant."
    },
    %{
      name: "journal",
      kind: :dir,
      tier: :on_demand,
      owner: BusterClaw.Journal,
      seed: {BusterClaw.Journal, :ensure},
      note: "The Activity record — one YYYY-MM-DD.md per day, appended by the agent."
    },
    # NAME RECLAIMED 08-09, exactly as `sources/` was on 08-03 — see the comment
    # on that entry. `notes/` was declared `:deprecated` ("superseded by
    # journal/") back when it held an older scratch concept. The Notes vault
    # shipped 08-08 and took the name over, which left a LIVE owner's directory
    # sitting in the swept-when-empty list: `sweep_deprecated/0` removed it on
    # every boot where the operator happened to have no notes, and `Notes`
    # re-created it on next touch. Nothing was ever lost — the sweeper refuses a
    # non-empty directory — but the registry was describing a live feature as an
    # orphan, which is how the entry survived being read.
    %{
      name: "notes",
      kind: :dir,
      tier: :on_demand,
      owner: BusterClaw.Notes,
      seed: {BusterClaw.Notes, :ensure},
      note: "The operator's Markdown vault — the Home Notes tab, read by note_*."
    },
    %{
      name: "sources",
      kind: :dir,
      tier: :on_demand,
      owner: BusterClaw.Finance.Sources,
      # No seeder, and that is the design rather than an omission. The shipped
      # catalogue lives in code so it can be CORRECTED by a new build; seeding it
      # here would put it behind `maybe_write`, which never overwrites, and a
      # registry of third-party APIs is the last thing that should be frozen at
      # install time. This folder holds only what an operator writes.
      #
      # NAME RECLAIMED 08-03. `sources/` was previously declared `:deprecated`
      # ("reserved for file exports that were never built"), which meant
      # `sweep_deprecated/0` DELETED it whenever it was empty. Leaving that entry
      # in place beside this one would have quietly removed an operator's
      # override folder the first time they emptied it. The deprecated entry is
      # gone; a stray directory from an old build is empty by construction (that
      # feature was never written), so nothing of anyone's is reinterpreted.
      seed: nil,
      note: "Your corrections and additions to the financial-data source registry."
    },
    %{
      name: "checks",
      kind: :dir,
      tier: :on_demand,
      owner: BusterClaw.Browser.Checks,
      seed: nil,
      note: "Saved site checks the agent can re-run."
    },
    %{
      name: "backgrounds",
      kind: :dir,
      tier: :on_demand,
      owner: BusterClaw.Appearance,
      seed: nil,
      note: "Background images you uploaded."
    },

    # --- on demand, drop zones: you put the first file in, not us ----------
    # All audio lives under `sounds/`: chimes at the top, `sounds/music/` for the
    # dock player's library, `sounds/studio/` for the Sound Studio's working
    # files. Those two are NOT declared here — this registry describes top-level
    # entries, and they are inside one. Each is created by its own surface
    # (Music.ensure/0, SoundStudio.ensure/0), so opening Notify doesn't conjure a
    # music library and vice versa.
    %{
      name: "sounds",
      kind: :dir,
      tier: :on_demand,
      owner: BusterClaw.Notifications.Sound,
      seed: {BusterClaw.Notifications.Sound, :ensure},
      note: "All audio — notification chimes, plus music/ and studio/ inside."
    },
    %{
      name: "shaders",
      kind: :dir,
      tier: :on_demand,
      owner: BusterClaw.Shaders,
      seed: {BusterClaw.Shaders, :ensure},
      note: "Your own .wgsl background patterns — no rebuild needed."
    },

    # --- transient: comes and goes during normal operation -----------------
    %{
      name: "browser-control",
      kind: :dir,
      tier: :transient,
      owner: BusterClaw.BrowserControl,
      seed: nil,
      note: "The controlled browser's profile and Agent Mode captures."
    },
    %{
      name: ".browser-bookmarks.json",
      kind: :file,
      tier: :transient,
      owner: BusterClaw.Bookmarks,
      seed: nil,
      note: "In-app browser bookmarks."
    },
    %{
      name: "STOP",
      kind: :file,
      tier: :transient,
      owner: BusterClaw.Orchestration,
      seed: nil,
      note: "The shift kill switch. Present only while a shift is stopped."
    },

    # --- deprecated: swept when empty --------------------------------------
    %{
      name: "analysis",
      kind: :dir,
      tier: :deprecated,
      owner: BusterClaw.Library.Artifact,
      seed: nil,
      note: "Unused. Reserved for file exports that were never built."
    },
    %{
      name: "extensions",
      kind: :dir,
      tier: :deprecated,
      owner: BusterClaw.Workspace,
      seed: nil,
      note:
        "Orphan. Held installed extensions' parts; the extension mechanism was " <>
          "deleted 08-08. Swept when empty."
    },
    %{
      name: "mcp",
      kind: :dir,
      tier: :deprecated,
      owner: BusterClaw.Workspace,
      seed: nil,
      note:
        "Orphan. Held the brokerage MCP config; nothing writes it since the " <>
          "trading stack was deleted 08-08. Safe to remove by hand."
    },
    %{
      name: "MANUAL.html",
      kind: :file,
      tier: :deprecated,
      owner: BusterClaw.Pages,
      seed: nil,
      note: "Legacy. Lived at the root before pages/; Pages.ensure/0 removes it."
    }
  ]

  @doc "Every declared workspace entry, in display order."
  def entries, do: @entries

  @doc "Every declared top-level name (dirs and files)."
  def names, do: Enum.map(@entries, & &1.name)

  @doc "Declared entries in `tier`."
  def entries(tier), do: Enum.filter(@entries, &(&1.tier == tier))

  @doc "Whether `name` is a declared top-level workspace entry."
  def declared?(name), do: name in names()

  @doc "The declared entry called `name`, or `nil`."
  def entry(name), do: Enum.find(@entries, &(&1.name == name))

  @doc "Absolute path to a declared entry. Raises on an undeclared name."
  def path(name) do
    unless declared?(name) do
      raise ArgumentError, """
      "#{name}" is not a declared workspace entry.

      Every top-level file or directory in the workspace must be declared in
      BusterClaw.Workspace.@entries — that list is the only description of the
      layout that exists. Add it there (with a tier and a note) before writing
      to it.
      """
    end

    Artifact.workspace_path(name)
  end

  @doc """
  Scaffold the workspace: **`:core` only**.

  Called at boot *and* by `WorkspaceLive.set_workspace_root/1`, which is the
  point: before this module those two ran different subsets, so moving your
  workspace folder produced a partial layout that only healed on the next app
  restart.

  Everything else waits for `ensure_entry/1`. Every step is best-effort and
  independent — one owner failing (a permissions problem, a full disk) must not
  stop the rest of the workspace being built.
  """
  def ensure do
    migrate_layout()

    :core
    |> entries()
    |> Enum.each(&run_seed/1)

    sweep_deprecated()
    :ok
  end

  # Old layouts fold into the current one before anything seeds:
  #
  #   - Audio used to sprawl across three top-level folders (`music/`, `sounds/`,
  #     `studio/`); it is one now, with the library and the Studio inside it.
  #   - `job-descriptions/` and `appearance/` were feature-named; they are
  #     content-named now (`jobs/`, `backgrounds/`). Appearance's Settings
  #     pointers are rewritten by `Appearance.ensure/0`, which boots after this.
  #   - `shift/` held the fridge (`Dispatch.md`, now top-level — a full-overwrite
  #     file the projector rewrites at boot, so the old copy is just deleted) and
  #     the dated diary (machine bookkeeping, now under `.buster-claw/dispatch/`).
  #
  # Runs before the seeders so an existing install's files are in place before
  # anything writes next to them. Idempotent by shape rather than by a marker:
  # once the old entry is gone there is nothing left to do.
  @relocations [
    {"music", "sounds/music"},
    {"studio", "sounds/studio"},
    {"job-descriptions", "jobs"},
    {"appearance", "backgrounds"},
    {"shift", ".buster-claw/dispatch"}
  ]

  # Machine-written files stranded by a move. Each is regenerated at its new home
  # every boot, so the old copy holds nothing of the user's.
  @stale_machine_files ["INTRODUCTION.md", "shift/Dispatch.md"]

  defp migrate_layout do
    Enum.each(@stale_machine_files, fn rel ->
      File.rm(Artifact.workspace_path(rel))
    end)

    Enum.each(@relocations, fn {old_name, new_rel} ->
      relocate(
        Artifact.workspace_path(old_name),
        Artifact.workspace_path(new_rel),
        {old_name, new_rel}
      )
    end)
  end

  defp relocate(old, new, {from, to} = label) do
    if File.dir?(old) do
      File.mkdir_p!(Path.dirname(new))

      # Fast path: nothing at the destination yet, so move the whole directory.
      if File.exists?(new), do: merge_into(old, new, label), else: rename_into(old, new, label)
    end
  rescue
    error ->
      Logger.warning(
        "Workspace: couldn't relocate #{from}/ to #{to}/: #{Exception.message(error)}"
      )
  end

  defp rename_into(old, new, {from, to} = label) do
    case File.rename(old, new) do
      :ok ->
        Logger.info("Workspace: moved #{from}/ to #{to}/")

      # Across filesystems rename fails; fall back to a copy-then-verify.
      {:error, _reason} ->
        merge_into(old, new, label)
    end
  end

  # Both exist: move each file the destination doesn't already have, then drop
  # the old directory only if it ended up empty. A name collision leaves the
  # original in place and says so — we do not get to pick which of a user's two
  # files survives.
  defp merge_into(old, new, {from, to}) do
    File.mkdir_p!(new)

    kept =
      old
      |> File.ls!()
      |> Enum.reject(fn name ->
        dest = Path.join(new, name)

        if File.exists?(dest) do
          false
        else
          File.rename(Path.join(old, name), dest) == :ok
        end
      end)

    case kept do
      [] ->
        File.rmdir(old)
        Logger.info("Workspace: merged #{from}/ into #{to}/")

      names ->
        Logger.warning(
          "Workspace: kept #{from}/ — #{length(names)} item(s) already exist under " <>
            "#{to}/ and were not overwritten: #{Enum.join(names, ", ")}"
        )
    end
  end

  @doc """
  Materialize one declared entry, now.

  Call this from the surface that owns the feature — opening the Music tab is
  what should create `music/`, not installing the app. Idempotent, best-effort,
  and safe to call on every mount. Returns `:ok` whether or not there was
  anything to do; an undeclared name raises, because that is a programming error.
  """
  def ensure_entry(name) do
    case entry(name) do
      nil ->
        raise ArgumentError, ~s("#{name}" is not a declared workspace entry)

      entry ->
        run_seed(entry)
        :ok
    end
  end

  defp run_seed(%{seed: nil}), do: :ok

  defp run_seed(%{seed: {module, fun}, name: name}) do
    apply(module, fun, [])
    :ok
  rescue
    error ->
      Logger.warning("Workspace: seeding #{name} failed: #{Exception.message(error)}")
      :error
  catch
    kind, reason ->
      Logger.warning("Workspace: seeding #{name} failed: #{inspect({kind, reason})}")
      :error
  end

  @doc """
  Remove `:deprecated` directories — but **only when they are empty**.

  These are scaffolding we shipped and then stopped using (`analysis/`,
  `extensions/`, `mcp/`). They are noise in every existing install and no new
  install should grow them.

  **Before adding an entry here, check that no live module owns the name.**
  Twice now a deprecated entry has outlived the name it described — `sources/`
  (fixed 08-03) and `notes/` (fixed 08-09) — and in both cases the directory
  went on being swept on boot after a new feature had claimed it.

  A non-empty one is left alone and logged. A user may have put something in
  there, and a folder we told them was theirs is not ours to empty — decluttering
  never outranks not destroying someone's files. Returns the names removed.
  """
  def sweep_deprecated do
    :deprecated
    |> entries()
    |> Enum.filter(&(&1.kind == :dir))
    |> Enum.flat_map(&sweep_dir/1)
  end

  defp sweep_dir(%{name: name}) do
    path = Artifact.workspace_path(name)

    case File.ls(path) do
      {:ok, []} ->
        case File.rmdir(path) do
          :ok ->
            [name]

          {:error, reason} ->
            Logger.warning("Workspace: couldn't remove empty #{name}/: #{inspect(reason)}")
            []
        end

      {:ok, entries} ->
        Logger.info(
          "Workspace: keeping deprecated #{name}/ — it holds #{length(entries)} item(s) " <>
            "that are not ours to delete"
        )

        []

      # Not there at all: the common case on a healthy install.
      {:error, _reason} ->
        []
    end
  end

  @doc """
  Write the workspace README — the one file here addressed to the human.

  Rewritten on every boot from the registry, so the list of folders can never
  drift from what the app actually creates. Never overwrites anything else.
  """
  def write_readme do
    File.mkdir_p!(Artifact.workspace_root())
    File.write!(Artifact.workspace_path("README.md"), readme_body())
    :ok
  end

  defp readme_body do
    """
    # Your Buster Claw folder

    <!-- Written by Buster Claw from its workspace registry. Edits are
         overwritten on launch; everything else in this folder is yours. -->

    This is your assistant's workspace. Everything it knows and everything it
    produces is a plain file in here — no database you can't read, no lock-in.
    `grep` works.

    ## What's here now

    #{listing(:core)}
    ## Folders that appear when you use them

    These are created the first time you open the feature that owns them, so a
    folder here always means something is actually in it.

    #{listing(:on_demand)}
    ## Adding your own

    The drop zones above (`sounds/`, `shaders/`) are yours to fill — put a file
    in and the app picks it up on the next look. You can safely edit anything in
    `jobs/`, `skills/` and `memory/`; those are read by the agent and are meant
    to be changed by you.

    The app's own machine files live out of the way in `.buster-claw/` — the
    agent's operating guide (`INTRODUCTION.md`, regenerated on every launch) and
    the dated dispatch diary. Read them if you're curious; they aren't yours to
    edit.
    """
  end

  defp listing(tier) do
    tier
    |> entries()
    |> Enum.reject(&(&1.name == "README.md"))
    |> Enum.map_join("\n", fn e ->
      suffix = if e.kind == :dir, do: "/", else: ""
      "- `#{e.name}#{suffix}` — #{e.note}"
    end)
    |> Kernel.<>("\n")
  end
end
