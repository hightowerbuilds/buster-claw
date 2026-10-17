defmodule BusterClaw.Studio.Catalog do
  @moduledoc """
  Everything the Studio can open, grouped — as **core** data, with no web in it.

  Extracted from `BusterClawWeb.SoundStudioComponent` on 08-16 (the frozen
  Phase 3 of the archived modularization roadmap). That component was FROZEN in
  `scripts/check_file_sizes.sh` at exactly its size, so the catalog was the
  first thing it had to give up to gain any room at all. Taking this phase is
  what ended the freeze, later the same day.

  ## An item is `{id, kind, name, label, sub, path}` — and never a URL

  This is the correction the 08-13 review added to the frozen plan, and it is
  the whole reason this module can live in core. Four of the five builders used
  to bake router `~p` URLs, which would have dragged `BusterClawWeb.Router` into
  `lib/buster_claw/` and made the catalog unusable from anywhere but a browser.

  So an item carries a **filesystem path** and the web layer decorates a `url`
  onto it — see `BusterClawWeb.SoundStudio.Catalog.groups/0`. A path is what the
  still-unbuilt `sound_*` CLI needs (`LEFTOVERS_AGENT_CORE`, "the Studio has no
  CLI"); a URL is what only a browser needs. Getting that backwards is what kept
  this extraction frozen.

  ## `groups/0` is expensive and is not cached

  It performs **four directory listings**:
  `Mix.list/0`, `Editor.list/0`, `Sound.list/0` + `Sound.bundled_list/0`,
  and `Music.tracks/0`. That cost is stated here
  because it is easy to reach for `groups/0` in a loop without noticing —
  `resolve_source/1` did exactly that, once per clip, on every mixdown.

  **If you need one item, take the groups you already have and use
  `find_source/2`.** `resolve_source/1` below exists for callers that genuinely
  have nothing to hand and is deliberately the noisy option.

  ## `group_keys/0` is separate on purpose

  Answering "is this a real group?" must not read four directories, and the
  folded-groups setting is filtered against it on every read. A test asserts the
  two lists agree, which is what stops the cheap answer drifting from the real
  one.
  """
  alias BusterClaw.Music
  alias BusterClaw.Notifications.Sound
  alias BusterClaw.Studio.Editor
  alias BusterClaw.Studio.Mix

  @doc """
  Every source the studio can open, grouped for the sidebar.

  Reads four directories — see the moduledoc before
  calling this anywhere that repeats.
  """
  def groups do
    [
      %{key: "mix", label: "Mixes", items: mix_items()},
      # Imports lead the material groups: this is the working mix, and the one
      # the operator fills themselves.
      %{key: "imports", label: "Imports", items: import_items()},
      %{key: "sounds", label: "Sounds", items: sound_items()},
      %{key: "music", label: "Music", items: music_items()}
    ]
  end

  @doc """
  Every sidebar group key. Cheap on purpose — `groups/0` reads four directories
  which is far too much work to answer "is this a real
  group?". A test asserts the two lists agree.
  """
  def group_keys, do: ~w(mix imports sounds music)

  @doc "Find one source by id across the groups you already have, or `nil`."
  def find_source(_groups, nil), do: nil

  def find_source(groups, id) do
    groups |> Enum.flat_map(& &1.items) |> Enum.find(&(&1.id == id))
  end

  @doc """
  Resolve a source id against a **freshly read** catalog.

  Expensive by construction — it calls `groups/0`. Correct for a one-shot
  lookup where the caller holds no groups; wrong inside anything that repeats.
  A renderer walking n clips wants `groups/0` once and `find_source/2` n times,
  which is what `Studio.Render` is passed.
  """
  def resolve_source(id), do: find_source(groups(), id)

  defp mix_items do
    Enum.map(Mix.list(), fn name ->
      %{
        id: "mix:" <> name,
        kind: :mix,
        name: name,
        label: name,
        sub: "arrangement",
        # A mix is not a file the browser can play; it has to be rendered
        # first, which is what the arranger's Render button is for.
        path: nil
      }
    end)
  end

  defp import_items do
    Enum.map(Editor.list(), fn name ->
      %{
        id: "import:" <> name,
        kind: :import,
        name: name,
        label: Path.rootname(name),
        sub: String.trim_leading(Path.extname(name), "."),
        path: Editor.path_for(name)
      }
    end)
  end

  # Everything in the `sounds/` folder, plus any built-in not yet copied there.
  #
  # The sidebar looked like a dump of system sounds once, and the cause was
  # `phx.digest`'s hashed duplicates (`alarm-<md5>.wav` beside `alarm.wav`),
  # since fixed in `Sound.bundled_list/0` — **not** the operator's own files.
  # Their sounds belong here: a scream and a bongo hit are exactly the raw
  # material this tab exists to cut up.
  #
  # Deduped by basename, because `Sound.resolve_path/1` only ever plays one of
  # the two layers — listing both would advertise a choice the resolver does not
  # offer. `yours` means the file is in the workspace (an override, or something
  # only you have); `built-in` means it still resolves to the shipped copy.
  defp sound_items do
    workspace = MapSet.new(Sound.list())

    (Sound.list() ++ Sound.bundled_list())
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(fn name ->
      %{
        id: "sound:" <> name,
        kind: :sound,
        name: name,
        label: Path.rootname(name),
        sub: if(MapSet.member?(workspace, name), do: "yours", else: "built-in"),
        path: Sound.resolve_path(name)
      }
    end)
  end

  # Tracks only. A `:library` row used to ride at the top of this group and open
  # the music library manager (upload / delete / queue / play-all); both went on
  # 08-16, because the Studio is for making things and administering a collection
  # is not making something.
  #
  # **The tracks stayed on purpose.** Chopping a song into a mix is exactly the
  # creative work this tab exists for, so music remains raw material — it simply
  # stopped being a thing you manage from here.
  defp music_items do
    Enum.map(Music.tracks(), fn track ->
      %{
        id: "music:" <> track.name,
        kind: :music,
        name: track.name,
        label: track.title,
        sub: track.artist,
        path: Music.path_for(track.name)
      }
    end)
  end
end
