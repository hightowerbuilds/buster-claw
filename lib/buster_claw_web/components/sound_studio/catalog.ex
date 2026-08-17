defmodule BusterClawWeb.SoundStudio.Catalog do
  @moduledoc """
  The Studio's source catalog, **decorated for a browser**.

  Extracted from `SoundStudioComponent` (CODE_QUALITY_REFACTOR Phase 3B, 08-03)
  because two consumers now ask them: the component itself and the arranger.
  Pure functions over the groups list; no assigns, no socket.

  ## What moved out on 08-16, and what stayed

  The catalog itself is now `BusterClaw.Notifications.StudioCatalog` in core
  (frozen Phase 3). **This module is what is left once the web is subtracted:
  the `url` field, and nothing else.**

  That split is the correction the 08-13 review made to the frozen plan. Four
  of the five builders baked router `~p` URLs, which would have pulled
  `BusterClawWeb.Router` into `lib/buster_claw/`. Core carries a filesystem
  `path` — which is what the unbuilt `sound_*` CLI needs — and `groups/0` here
  adds the `url` a browser needs on top of it.

  **A `url` is added per kind, and `nil` is a real answer.** A mix has no URL
  because it is not a file the browser can play until it is rendered, and the
  music-library manager is a control rather than a source.
  """
  use BusterClawWeb, :verified_routes

  alias BusterClaw.Notifications.StudioCatalog

  @doc """
  Every source the studio can open, grouped, each item carrying a playable
  `url` where one exists.

  Inherits `StudioCatalog.groups/0`'s cost — four directory listings and a
  database query. Call it once per render and pass the result down; see the
  core moduledoc for what happened the last time something called it in a loop.
  """
  def groups do
    Enum.map(StudioCatalog.groups(), fn group ->
      %{group | items: Enum.map(group.items, &with_url/1)}
    end)
  end

  @doc "Every sidebar group key. Cheap — does not read the disk."
  defdelegate group_keys, to: StudioCatalog

  @doc "The sidebar id that opens the music library manager."
  defdelegate music_library_id, to: StudioCatalog

  # The one thing this module exists for. Kept as a `case` on `kind` rather than
  # a field on each builder so that adding a source kind in core is a compile
  # error waiting here, not a missing link discovered in the browser.
  defp with_url(%{kind: :import, name: name} = item),
    do: Map.put(item, :url, ~p"/studio/file/#{name}")

  defp with_url(%{kind: :sound, name: name} = item),
    do: Map.put(item, :url, ~p"/notify/sound/#{name}")

  defp with_url(%{kind: :recording, recording_path: path} = item),
    do: Map.put(item, :url, ~p"/phone/recording?path=#{path}")

  defp with_url(%{kind: :music, name: name} = item),
    do: Map.put(item, :url, ~p"/music/track/#{name}")

  # A mix has to be rendered before anything can play it; the library row is a
  # control, not a source. Both are `nil` on purpose rather than absent, so
  # `clip_src/2` below can match on the field without knowing the kinds.
  defp with_url(item), do: Map.put(item, :url, nil)

  @doc "Find one source by id across every group, or `nil`."
  defdelegate find_source(groups, id), to: StudioCatalog

  @doc """
  Resolve one source id against a freshly read, URL-decorated catalog.

  Not a delegate: core's `resolve_source/1` returns an item with a `path` and no
  `url`, and every caller here needs the URL. Expensive by construction — it
  reads the whole catalog — so this is for a **one-shot** lookup. Inside a walk,
  take `groups/0` once and use `find_source/2`.
  """
  def resolve_source(id), do: find_source(groups(), id)

  @doc """
  The groups a clip may be added FROM: everything except mixes (a mix is a list
  of references to these, not raw material) and the music library manager,
  which is not a source at all. Groups left empty by that filter drop out
  rather than rendering a headed but empty optgroup.
  """
  def addable_groups(groups) do
    groups
    |> Enum.reject(&(&1.key == "mix"))
    |> Enum.map(fn group ->
      %{group | items: Enum.reject(group.items, &(&1.kind == :library))}
    end)
    |> Enum.reject(&(&1.items == []))
  end

  @doc """
  A clip's playable URL, resolved from the catalog at render time — the audition
  hook fetches THIS, so what it performs is exactly what the sidebar would play.

  A vanished source resolves to `nil` and the attribute is simply absent; the
  transport skips it while Render still refuses.
  """
  def clip_src(groups, %{source: source}) do
    case find_source(groups, source) do
      %{url: url} -> url
      _ -> nil
    end
  end
end
