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
  # uses so the routed path is genuinely exercised.
  @rows [
    %{key: "default", label: "Default", group: :base, kind: "reminder", source: "manual"},
    %{key: "timer", label: "Timers", group: :kind, kind: "timer", source: "manual"},
    %{key: "alarm", label: "Alarms", group: :kind, kind: "alarm", source: "manual"},
    %{key: "reminder", label: "Reminders", group: :kind, kind: "reminder", source: "manual"},
    %{key: "chat", label: "Chat", group: :source, kind: "reminder", source: "chat"},
    %{key: "terminal", label: "Terminal", group: :source, kind: "reminder", source: "terminal"},
    %{key: "email", label: "Email", group: :source, kind: "reminder", source: "email"},
    %{
      key: "voicemail",
      label: "Voicemail",
      group: :source,
      kind: "reminder",
      source: "voicemail"
    },
    %{key: "manual", label: "Manual", group: :source, kind: "reminder", source: "manual"}
  ]

  @impl true
  def mount(_params, _session, socket) do
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

    attrs = %{
      kind: row.kind,
      source: row.source,
      label: "Notify test — #{row.label}",
      fire_at: DateTime.utc_now() |> DateTime.truncate(:second)
    }

    case Notifications.create_notification(attrs) do
      {:ok, _notification} ->
        {:noreply, socket}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Couldn't fire a test notification.")}
    end
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

  defp refresh(socket) do
    socket
    |> assign(:sounds, Sound.list())
    |> assign(:map, Sound.sound_map())
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

  # What a routing row actually resolves to right now, for honest display.
  # Matches Sound.for_notification/1's source → kind → default → floor walk from
  # this row's key downward.
  defp effective(map, "default"), do: map["default"] || fallback_name()
  defp effective(map, key), do: map[key] || map["default"] || fallback_name()

  defp fallback_name do
    case Sound.path() do
      nil -> nil
      path -> Path.basename(path)
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
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
            </header>

            <div class="divide-y divide-base-300 px-5">
              <div :for={group <- [:base, :kind, :source]} class="py-4">
                <p class="ic-eyebrow mb-2">
                  {case group do
                    :base -> "Default"
                    :kind -> "By kind"
                    :source -> "By source"
                  end}
                </p>
                <div class="space-y-2">
                  <div
                    :for={row <- Enum.filter(@rows, &(&1.group == group))}
                    class="flex flex-wrap items-center gap-3"
                  >
                    <span class="w-24 shrink-0 text-sm font-semibold">{row.label}</span>

                    <form id={"assign-#{row.key}"} phx-change="assign" class="contents">
                      <input type="hidden" name="key" value={row.key} />
                      <select
                        name="sound"
                        class="min-w-44 rounded border-2 border-base-300 bg-base-100 px-2 py-1 text-sm"
                        aria-label={"Sound for #{row.label}"}
                      >
                        <option value="" selected={is_nil(@map[row.key])}>
                          {if row.key == "default",
                            do: "Auto (notify.* or first file)",
                            else: "— inherit —"}
                        </option>
                        <option
                          :for={sound <- @sounds}
                          value={sound}
                          selected={@map[row.key] == sound}
                        >
                          {display_name(sound)}
                        </option>
                      </select>
                    </form>

                    <span class="text-xs text-base-content/50">
                      {case effective(@map, row.key) do
                        nil -> "plays: silent"
                        name -> "plays: #{display_name(name)}"
                      end}
                    </span>

                    <button
                      :if={effective(@map, row.key)}
                      type="button"
                      data-preview-url={~p"/notify/sound/#{effective(@map, row.key)}"}
                      class="btn btn-ghost btn-xs"
                      aria-label={"Preview the #{row.label} sound"}
                    >
                      <.icon name="hero-play" class="size-4" /> Preview
                    </button>

                    <button
                      type="button"
                      phx-click="test"
                      phx-value-key={row.key}
                      class="btn btn-outline btn-xs"
                      aria-label={"Fire a test #{row.label} notification"}
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
