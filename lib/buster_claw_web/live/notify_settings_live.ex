defmodule BusterClawWeb.NotifySettingsLive do
  @moduledoc """
  Settings → Notify: the notification sound board.

  Manages the workspace sound library (`<workspace>/sounds/`) and the per-event
  routing map — which sound plays for each notification source (chat, terminal,
  email, voicemail, manual) and kind (timer, alarm, reminder), with a default
  underneath. Precedence when a notification fires: source → kind → default →
  `notify.<ext>`/first file (see `Notifications.Sound`).

  Preview buttons play files client-side via the `SoundPreview` hook. The Test
  button on each row creates a *real* immediate notification carrying that
  row's kind/source, so the whole pipeline rings — scheduler, modal, and the
  routed sound — exactly as a live fire would.
  """
  use BusterClawWeb, :live_view

  alias BusterClaw.Notifications
  alias BusterClaw.Notifications.Sound

  @max_upload_bytes 20 * 1_024 * 1_024

  # Each routing row: the map key, its section, and the kind/source a Test fire
  # uses so the routed path is genuinely exercised. Labels are NOT here — they
  # live in `Sound.route_label/1`, because the Studio's assign-on-render offers
  # the same keys and a label defined twice is a label that drifts.
  @rows [
    %{key: "default", group: :base, kind: "reminder", source: "manual"},
    %{key: "timer", group: :kind, kind: "timer", source: "manual"},
    %{key: "alarm", group: :kind, kind: "alarm", source: "manual"},
    %{key: "reminder", group: :kind, kind: "reminder", source: "manual"},
    %{key: "chat", group: :source, kind: "reminder", source: "chat"},
    %{key: "terminal", group: :source, kind: "reminder", source: "terminal"},
    %{key: "email", group: :source, kind: "reminder", source: "email"},
    %{
      key: "voicemail",
      group: :source,
      kind: "reminder",
      source: "voicemail"
    },
    %{key: "manual", group: :source, kind: "reminder", source: "manual"},
    # SOUND_ROADMAP Part II — SoundBoard keys. Their Test goes through
    # SoundBoard.ring/1, not a fabricated notification: these keys never fire
    # the notification pipeline in real life, so a Test that did would pass on
    # a path production never takes. The board's cooldown applies to Test too —
    # that IS the pipeline, so two rapid Tests ringing once is honest.
    %{key: "confirm", group: :agent, test: :ring},
    %{key: "shift", group: :agent, test: :ring},
    %{key: "blocked", group: :agent, test: :ring},
    %{key: "web", group: :agent, test: :ring},
    %{key: "order", group: :agent, test: :ring},
    %{key: "sms", group: :comms, test: :ring},
    %{key: "security", group: :security, test: :ring},
    %{key: "boot", group: :playful, test: :ring}
  ]

  @impl true
  def mount(_params, _session, socket) do
    # `sounds/` is a drop zone — create it when the user is looking at the
    # setting that tells them what to drop in.
    BusterClaw.Workspace.ensure_entry("sounds")

    Sound.ensure()

    {:ok,
     socket
     |> assign(:page_title, "Notify")
     |> assign(:rows, @rows)
     |> refresh()
     # `audio/*` rather than the extension list: LiveView's accept validation
     # rejects extensions the MIME lib doesn't know (`.ogg`). The real gate is
     # the extension check in save_sound.
     |> allow_upload(:sound,
       accept: ~w(audio/*),
       max_entries: 1,
       max_file_size: @max_upload_bytes
     )}
  end

  @impl true
  def handle_event("assign", %{"key" => key, "sound" => sound}, socket) do
    case Sound.assign(key, sound) do
      :ok ->
        {:noreply, socket |> refresh() |> put_flash(:info, "Sound routing saved.")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Couldn't save that routing.")}
    end
  end

  def handle_event("test", %{"key" => key}, socket) do
    row = Enum.find(@rows, &(&1.key == key))

    if row[:test] == :ring do
      BusterClaw.Notifications.SoundBoard.ring(key)
      {:noreply, socket}
    else
      test_notification(row, socket)
    end
  end

  def handle_event("toggle_sound", _params, socket) do
    Sound.set_enabled(not Sound.enabled?())
    {:noreply, refresh(socket)}
  end

  def handle_event("delete_sound", %{"name" => name}, socket) do
    case Sound.delete(name) do
      :ok ->
        {:noreply, socket |> refresh() |> put_flash(:info, "Deleted #{name}.")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Couldn't delete #{name}.")}
    end
  end

  def handle_event("validate_sound", _params, socket), do: {:noreply, socket}

  def handle_event("save_sound", _params, socket) do
    saved =
      consume_uploaded_entries(socket, :sound, fn %{path: path}, entry ->
        ext = entry.client_name |> Path.extname() |> String.downcase()

        if ext in Sound.accepted_extensions() do
          File.mkdir_p(Sound.dir())
          dest = Path.join(Sound.dir(), available_name(entry.client_name))
          File.cp!(path, dest)
          {:ok, Path.basename(dest)}
        else
          {:ok, :rejected_extension}
        end
      end)

    case saved do
      [] ->
        {:noreply, put_flash(socket, :error, "Choose an audio file first.")}

      [:rejected_extension | _] ->
        {:noreply, put_flash(socket, :error, "Audio files only (MP3, WAV, OGG, M4A, AAC).")}

      [name | _] ->
        {:noreply, socket |> refresh() |> put_flash(:info, "Added #{name}.")}
    end
  end

  defp test_notification(row, socket) do
    attrs = %{
      kind: row.kind,
      source: row.source,
      label: "Notify test — #{Sound.route_label(row.key)}",
      fire_at: DateTime.utc_now() |> DateTime.truncate(:second)
    }

    case Notifications.create_notification(attrs) do
      {:ok, _notification} ->
        {:noreply, socket}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Couldn't fire a test notification.")}
    end
  end

  defp refresh(socket) do
    socket
    |> assign(:sounds, Sound.list())
    |> assign(:bundled, Sound.bundled_list())
    |> assign(:map, Sound.sound_map())
    |> assign(:sound_on, Sound.enabled?())
    # The walk, MATERIALIZED. Calling @resolved[row.key] inline in the
    # template read beautifully and was permanently stale: the expression's
    # only tracked assign was `row`, and @rows never changes, so LiveView
    # rendered every row's resolution exactly once — at mount — and never
    # again. An assign is both single-source (still Sound's walk, not a
    # reimplementation) and diffed like any other state.
    |> assign(:resolved, Map.new(Sound.route_keys(), &{&1, Sound.resolved(&1)}))
  end

  # A collision-free destination basename: sanitized, and suffixed -2, -3, …
  # rather than overwriting an existing library file.
  defp available_name(client_name) do
    base = client_name |> Path.basename() |> String.replace(~r/[^\w.\-]/u, "-")
    ext = Path.extname(base)
    stem = Path.rootname(base)

    Stream.concat([[base]], Stream.map(2..99, fn n -> "#{stem}-#{n}#{ext}" end))
    |> Enum.find(fn candidate -> not File.exists?(Path.join(Sound.dir(), candidate)) end)
  end

  defp display_name(file), do: file |> Path.rootname() |> String.capitalize()

  # Row display comes from @resolved (materialized in refresh/1) — one walk,
  # Sound's own, snapshotted into a tracked assign. See the note in refresh/1
  # for why calling Sound.resolved/1 inline in the template cannot work.

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} socket={@socket}>
      <section class="space-y-6">
        <BusterClawWeb.SettingsTabs.tabs active={:notify} />

        <div id="notify-sound-panel" phx-hook="SoundPreview" class="space-y-6">
          <div class="ic-panel overflow-hidden">
            <header class="border-b-2 border-base-content/20 px-5 py-4">
              <p class="ic-eyebrow">Notify</p>
              <h2 class="font-display text-2xl font-black uppercase tracking-tight">
                Sound board
              </h2>
              <p class="mt-1 text-sm text-base-content/65">
                Pick which sound each kind of notification plays. A <strong>source</strong>
                match wins over a <strong>kind</strong>
                match,
                which wins over the default. <strong>Test</strong>
                fires a real
                notification through the full pipeline — modal and all.
              </p>
              <label class="mt-3 flex w-fit cursor-pointer items-center gap-2">
                <input
                  type="checkbox"
                  checked={@sound_on}
                  phx-click="toggle_sound"
                  class="toggle toggle-primary toggle-sm"
                />
                <span class="text-sm font-semibold">
                  {if @sound_on, do: "Sound on", else: "Sound off — everything is visual-only"}
                </span>
              </label>
            </header>

            <div class="divide-y divide-base-300 px-5">
              <div
                :for={group <- [:base, :kind, :source, :agent, :comms, :security, :playful]}
                class="py-4"
              >
                <p class="ic-eyebrow mb-2">
                  {case group do
                    :base -> "Default"
                    :kind -> "By kind"
                    :source -> "By source"
                    :agent -> "Agent attention"
                    :comms -> "Comms"
                    :security -> "Security"
                    :playful -> "Chimes"
                  end}
                </p>
                <div class="space-y-2">
                  <div
                    :for={row <- Enum.filter(@rows, &(&1.group == group))}
                    class="flex flex-wrap items-center gap-3"
                  >
                    <span class="w-24 shrink-0 text-sm font-semibold">
                      {Sound.route_label(row.key)}
                    </span>

                    <form id={"assign-#{row.key}"} phx-change="assign" class="contents">
                      <input type="hidden" name="key" value={row.key} />
                      <select
                        name="sound"
                        class="min-w-44 rounded border-2 border-base-300 bg-base-100 px-2 py-1 text-sm"
                        aria-label={"Sound for #{Sound.route_label(row.key)}"}
                      >
                        <option value="" selected={is_nil(@map[row.key])}>
                          {if row.key == "default",
                            do: "Auto (notify.* or first file)",
                            else: "— inherit —"}
                        </option>
                        <option value="silent" selected={@map[row.key] == "silent"}>
                          Silent
                        </option>
                        <option
                          :for={sound <- @sounds}
                          value={sound}
                          selected={@map[row.key] == sound}
                        >
                          {display_name(sound)}
                        </option>
                        <option
                          :for={sound <- @bundled -- @sounds}
                          value={sound}
                          selected={@map[row.key] == sound}
                        >
                          Built-in: {display_name(sound)}
                        </option>
                      </select>
                    </form>

                    <span class="text-xs text-base-content/50">
                      {case @resolved[row.key] do
                        nil -> "plays: silent"
                        name -> "plays: #{display_name(name)}"
                      end}
                    </span>

                    <button
                      :if={@resolved[row.key]}
                      type="button"
                      data-preview-url={~p"/notify/sound/#{@resolved[row.key]}"}
                      class="btn btn-ghost btn-xs"
                      aria-label={"Preview the #{Sound.route_label(row.key)} sound"}
                    >
                      <.icon name="hero-play" class="size-4" /> Preview
                    </button>

                    <button
                      type="button"
                      phx-click="test"
                      phx-value-key={row.key}
                      class="btn btn-outline btn-xs"
                      aria-label={"Fire a test #{Sound.route_label(row.key)} notification"}
                    >
                      <.icon name="hero-bell-alert" class="size-4" /> Test
                    </button>
                  </div>
                </div>
              </div>
            </div>
          </div>

          <div class="ic-panel overflow-hidden">
            <header class="border-b-2 border-base-content/20 px-5 py-4">
              <p class="ic-eyebrow">Library</p>
              <h2 class="font-display text-xl font-black uppercase tracking-tight">
                Sounds on deck
              </h2>
              <p class="mt-1 text-sm text-base-content/65">
                Files in <code class="text-xs">sounds/</code> in your workspace.
                Add more below — MP3, WAV, OGG, M4A, or AAC.
              </p>
            </header>

            <div class="px-5 py-4">
              <p :if={@sounds == []} class="text-sm text-base-content/50">
                No sounds yet. Add one below and it becomes pickable above.
              </p>

              <ul :if={@sounds != []} class="divide-y divide-base-300">
                <li :for={sound <- @sounds} class="flex items-center gap-3 py-2">
                  <.icon name="hero-musical-note" class="size-4 shrink-0 text-primary" />
                  <span class="text-sm font-semibold">{display_name(sound)}</span>
                  <span class="text-xs text-base-content/45">{sound}</span>
                  <span class="grow" />
                  <button
                    type="button"
                    data-preview-url={~p"/notify/sound/#{sound}"}
                    class="btn btn-ghost btn-xs"
                    aria-label={"Preview #{sound}"}
                  >
                    <.icon name="hero-play" class="size-4" /> Preview
                  </button>
                  <button
                    type="button"
                    phx-click="delete_sound"
                    phx-value-name={sound}
                    data-claw-confirm={"Delete #{sound}? Routings pointing at it reset to inherit."}
                    class="btn btn-ghost btn-xs text-error"
                    aria-label={"Delete #{sound}"}
                  >
                    <.icon name="hero-trash" class="size-4" />
                  </button>
                </li>
              </ul>

              <form
                id="sound-upload"
                phx-submit="save_sound"
                phx-change="validate_sound"
                class="mt-4 flex flex-wrap items-center gap-3"
              >
                <.live_file_input
                  upload={@uploads.sound}
                  class="file-input file-input-bordered file-input-sm max-w-xs"
                />
                <button type="submit" class="btn btn-primary btn-sm">Add sound</button>
                <p
                  :for={err <- upload_errors(@uploads.sound)}
                  class="text-xs text-error"
                >
                  {case err do
                    :too_large -> "That file is too large (20 MB max)."
                    :not_accepted -> "Audio files only (MP3, WAV, OGG, M4A, AAC)."
                    _ -> "Upload failed."
                  end}
                </p>
              </form>
            </div>
          </div>
        </div>
      </section>
    </Layouts.app>
    """
  end
end
