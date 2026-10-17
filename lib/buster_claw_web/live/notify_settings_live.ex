defmodule BusterClawWeb.NotifySettingsLive do
  @moduledoc """
  Settings → Notify: the notification sound board.

  Manages the per-event routing map — which sound plays for each notification
  source (chat, terminal, email, manual) and kind (timer, alarm, reminder),
  with a default underneath, plus the agent's own noises — and the workspace
  sound library (`<workspace>/sounds/`) behind it. Precedence when a
  notification fires: source → kind → default → `notify.<ext>`/first file (see
  `Notifications.Sound`).

  One screen (10-17): every route is a row — label, a sound select, ▶, Test —
  in two columns of groups, with no page scroll. There is no library listing:
  the sixteen bundled chimes are in every select, and only sounds the operator
  added appear below the board, as chips with a delete. The select's inherit
  entry names what the row resolves to, so "plays" is read in place.

  ▶ plays the resolved file client-side via the `SoundPreview` hook. Test
  creates a *real* immediate notification carrying that row's kind/source, so
  the whole pipeline rings — scheduler, modal, and the routed sound — exactly
  as a live fire would.
  """
  use BusterClawWeb, :live_view

  alias BusterClaw.Notifications
  alias BusterClaw.Notifications.Sound

  @max_upload_bytes 20 * 1_024 * 1_024

  # Each routing row: the map key, its section, and the kind/source a Test fire
  # uses so the routed path is genuinely exercised. Labels are NOT here — they
  # live in `Sound.route_label/1`, because `sound_routes` shows the same keys
  # and a label defined twice is a label that drifts.
  @rows [
    %{key: "default", group: :base, kind: "reminder", source: "manual"},
    %{key: "timer", group: :kind, kind: "timer", source: "manual"},
    %{key: "alarm", group: :kind, kind: "alarm", source: "manual"},
    %{key: "reminder", group: :kind, kind: "reminder", source: "manual"},
    %{key: "chat", group: :source, kind: "reminder", source: "chat"},
    %{key: "terminal", group: :source, kind: "reminder", source: "terminal"},
    %{key: "email", group: :source, kind: "reminder", source: "email"},
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
    %{key: "security", group: :security, test: :ring},
    %{key: "boot", group: :playful, test: :ring}
  ]

  # The board's two columns, each a list of groups in reading order. A group
  # with no rows is not a group (an empty "Comms" header sat on the page for
  # months before 10-17).
  @columns [
    [{:base, "Default"}, {:kind, "By kind"}, {:source, "By source"}],
    [{:agent, "Agent attention"}, {:security, "Security"}, {:playful, "Chimes"}]
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
     |> assign(:columns, @columns)
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
        # The context owns the library folder, the extension allowlist and the
        # free-name rule; the page used to carry a second copy of all three
        # (CODE_QUALITY_SWEEP Phase 5).
        case Sound.install_file(path, entry.client_name) do
          {:ok, name} -> {:ok, name}
          {:error, :unsupported_format} -> {:ok, :rejected_extension}
          {:error, reason} -> {:ok, {:error, reason}}
        end
      end)

    case saved do
      [] ->
        {:noreply, put_flash(socket, :error, "Choose an audio file first.")}

      [:rejected_extension | _] ->
        {:noreply, put_flash(socket, :error, "Audio files only (MP3, WAV, OGG, M4A, AAC).")}

      [{:error, reason} | _] ->
        {:noreply, put_flash(socket, :error, "Couldn't add that file: #{inspect(reason)}.")}

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
    sounds = Sound.list()
    bundled = Sound.bundled_list()

    socket
    |> assign(:sounds, sounds)
    |> assign(:bundled, bundled)
    # The operator's own files: what the chips below the board show, and the
    # "Yours" group in every select. A workspace copy of a bundled chime is
    # neither — it plays under the chime's own name, and deleting it would
    # only restore the bundled one.
    |> assign(:own, sounds -- bundled)
    |> assign(:own_files, Enum.map(sounds -- bundled, &file_row/1))
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

  # One row of the file list: what Finder would show, from one `File.stat`.
  # A file that vanishes between `list/0` and here reads as 0 B with no date
  # rather than crashing the page — the next refresh drops it.
  defp file_row(name) do
    stat =
      case File.stat(Path.join(Sound.dir(), name), time: :local) do
        {:ok, stat} -> stat
        _ -> %File.Stat{size: 0, mtime: nil}
      end

    %{
      name: name,
      label: display_name(name),
      kind: name |> Path.extname() |> String.trim_leading("."),
      size: human_size(stat.size),
      modified: local_stamp(stat.mtime)
    }
  end

  defp human_size(bytes) when bytes < 1_024, do: "#{bytes} B"
  defp human_size(bytes) when bytes < 1_048_576, do: "#{Float.round(bytes / 1_024, 1)} KB"
  defp human_size(bytes), do: "#{Float.round(bytes / 1_048_576, 1)} MB"

  defp local_stamp({{y, m, d}, {h, mi, _s}}) do
    :io_lib.format("~4..0B-~2..0B-~2..0B ~2..0B:~2..0B", [y, m, d, h, mi]) |> to_string()
  end

  defp local_stamp(_), do: ""

  # "boot.wav" -> "Boot". Row display comes from @resolved (materialized in
  # refresh/1) — one walk, Sound's own, snapshotted into a tracked assign. See
  # the note in refresh/1 for why calling Sound.resolved/1 inline cannot work.
  defp display_name(file), do: file |> Path.rootname() |> String.capitalize()

  @impl true
  def render(assigns) do
    ~H"""
    <%!-- One screen: `fit_viewport` clamps the shell, the board is a flex
          column that scrolls inside itself if a window is ever too short. --%>
    <Layouts.app flash={@flash} socket={@socket} fit_viewport>
      <section class="flex min-h-0 flex-1 flex-col gap-4">
        <BusterClawWeb.SettingsTabs.tabs active={:notify} />

        <div
          id="notify-sound-panel"
          phx-hook="SoundPreview"
          class="ic-panel flex min-h-0 flex-1 flex-col overflow-hidden"
        >
          <div class="ic-panel-h shrink-0">
            <span>Sound board</span>
            <label class="flex cursor-pointer items-center gap-2 font-sans normal-case tracking-normal">
              <input
                type="checkbox"
                checked={@sound_on}
                phx-click="toggle_sound"
                class="toggle toggle-primary toggle-xs"
              />
              <span class="text-xs font-semibold">
                {if @sound_on, do: "Sound on", else: "Sound off — everything is visual-only"}
              </span>
            </label>
          </div>

          <div class="min-h-0 flex-1 overflow-y-auto p-4">
            <p class="mb-2 text-[0.6875rem] leading-4 text-base-content/55">
              A <strong>source</strong>
              match beats a <strong>kind</strong>
              match, which beats the default. ▶ plays the sound a row resolves to;
              <strong>Test</strong>
              fires the real thing, modal and all.
            </p>

            <div class="grid gap-x-6 gap-y-3 lg:grid-cols-2">
              <div :for={column <- @columns} class="space-y-3">
                <div :for={{group, title} <- column}>
                  <p class="ic-eyebrow mb-1.5">{title}</p>
                  <div class="space-y-1.5">
                    <.route_row
                      :for={row <- Enum.filter(@rows, &(&1.group == group))}
                      row={row}
                      map={@map}
                      resolved={@resolved[row.key]}
                      bundled={@bundled}
                      own={@own}
                    />
                  </div>
                </div>
              </div>
            </div>

            <%!-- The library, reduced to what is the operator's: the bundled
                  chimes are in every select already and need no list. What
                  is left is their own files, as a file-explorer list — name,
                  file, size, modified — in a box that scrolls on its own so
                  a long folder never pushes the board off the screen. --%>
            <div class="mt-3 space-y-2 border-t-2 border-base-content/15 pt-3">
              <div class="flex flex-wrap items-center gap-2">
                <p class="ic-eyebrow">Your sounds</p>
                <span class="font-mono text-[0.625rem] text-base-content/45">
                  {length(@own)} in <span class="normal-case">sounds/</span>
                </span>

                <form
                  id="sound-upload"
                  phx-submit="save_sound"
                  phx-change="validate_sound"
                  class="ml-auto flex flex-wrap items-center gap-2"
                >
                  <.live_file_input
                    upload={@uploads.sound}
                    class="file-input file-input-bordered file-input-xs max-w-56"
                  />
                  <button type="submit" class="btn btn-primary btn-xs">Add sound</button>
                  <p :for={err <- upload_errors(@uploads.sound)} class="text-xs text-error">
                    {case err do
                      :too_large -> "That file is too large (20 MB max)."
                      :not_accepted -> "Audio files only (MP3, WAV, OGG, M4A, AAC)."
                      _ -> "Upload failed."
                    end}
                  </p>
                </form>
              </div>

              <div
                id="own-sounds"
                class="max-h-36 overflow-y-auto rounded border-2 border-base-content/20"
              >
                <table class="w-full table-fixed border-collapse text-xs">
                  <thead class="sticky top-0 z-10 bg-base-100">
                    <tr class="border-b-2 border-base-content/15 text-left">
                      <th class="w-7 px-2 py-1.5"></th>
                      <th class="ic-eyebrow px-2 py-1.5 font-semibold">Name</th>
                      <th class="ic-eyebrow w-24 px-2 py-1.5 font-semibold">Kind</th>
                      <th class="ic-eyebrow w-20 px-2 py-1.5 text-right font-semibold">Size</th>
                      <th class="ic-eyebrow w-36 px-2 py-1.5 font-semibold">Modified</th>
                      <th class="w-16 px-2 py-1.5"></th>
                    </tr>
                  </thead>
                  <tbody>
                    <tr
                      :for={file <- @own_files}
                      data-own-sound={file.name}
                      class="group border-b border-base-content/10 transition last:border-b-0 hover:bg-base-200/60"
                    >
                      <td class="px-2 py-1">
                        <.icon name="hero-musical-note" class="size-3.5 text-primary" />
                      </td>
                      <td class="truncate px-2 py-1 font-semibold" title={file.name}>
                        {file.label}
                        <span class="ml-1 font-mono text-[0.625rem] font-normal text-base-content/45">
                          {file.name}
                        </span>
                      </td>
                      <td class="px-2 py-1 font-mono uppercase text-base-content/60">{file.kind}</td>
                      <td class="px-2 py-1 text-right font-mono tabular-nums text-base-content/60">
                        {file.size}
                      </td>
                      <td class="whitespace-nowrap px-2 py-1 font-mono tabular-nums text-base-content/60">
                        {file.modified}
                      </td>
                      <td class="px-1 py-1">
                        <span class="flex items-center justify-end gap-0.5">
                          <button
                            type="button"
                            data-preview-url={~p"/notify/sound/#{file.name}"}
                            class="grid size-6 place-items-center rounded text-base-content/60 transition hover:text-primary"
                            aria-label={"Preview #{file.name}"}
                          >
                            <.icon name="hero-play" class="size-3.5" />
                          </button>
                          <button
                            type="button"
                            phx-click="delete_sound"
                            phx-value-name={file.name}
                            data-claw-confirm={"Delete #{file.name}? Routings pointing at it reset to inherit."}
                            class="grid size-6 place-items-center rounded text-base-content/60 transition hover:text-error"
                            aria-label={"Delete #{file.name}"}
                          >
                            <.icon name="hero-trash" class="size-3.5" />
                          </button>
                        </span>
                      </td>
                    </tr>
                    <tr :if={@own == []}>
                      <td colspan="6" class="px-3 py-3 text-center text-xs text-base-content/45">
                        None yet — the sixteen built-in chimes are in every menu. Drop a file
                        into <span class="font-mono">sounds/</span> or add one above.
                      </td>
                    </tr>
                  </tbody>
                </table>
              </div>
            </div>
          </div>
        </div>
      </section>
    </Layouts.app>
    """
  end

  # One route: label, the sound select, ▶ for what it resolves to, Test.
  # `data-plays` is the resolved file (or "silent") so a test can read the walk
  # without parsing prose; the inherit option says the same thing to a human.
  attr :row, :map, required: true
  attr :map, :map, required: true
  attr :resolved, :any, required: true
  attr :bundled, :list, required: true
  attr :own, :list, required: true

  defp route_row(assigns) do
    ~H"""
    <div
      data-route={@row.key}
      data-plays={@resolved || "silent"}
      class="grid grid-cols-[5.5rem_minmax(0,1fr)_auto_auto] items-center gap-1.5"
    >
      <span class="truncate text-xs font-semibold">{Sound.route_label(@row.key)}</span>

      <form id={"assign-#{@row.key}"} phx-change="assign" class="contents">
        <input type="hidden" name="key" value={@row.key} />
        <select
          name="sound"
          class="w-full min-w-0 rounded border-2 border-base-content/20 bg-base-100 px-1.5 py-1 text-xs"
          aria-label={"Sound for #{Sound.route_label(@row.key)}"}
        >
          <option value="" selected={is_nil(@map[@row.key])}>
            {inherit_label(@row.key, @resolved)}
          </option>
          <option value="silent" selected={@map[@row.key] == "silent"}>Silent</option>
          <optgroup :if={@own != []} label="Yours">
            <option :for={sound <- @own} value={sound} selected={@map[@row.key] == sound}>
              {display_name(sound)}
            </option>
          </optgroup>
          <optgroup label="Built-in">
            <option :for={sound <- @bundled} value={sound} selected={@map[@row.key] == sound}>
              {display_name(sound)}
            </option>
          </optgroup>
        </select>
      </form>

      <button
        type="button"
        disabled={is_nil(@resolved)}
        data-preview-url={@resolved && ~p"/notify/sound/#{@resolved}"}
        class="grid size-7 place-items-center rounded border-2 border-base-content/20 text-base-content/70 transition hover:border-primary hover:text-primary disabled:cursor-not-allowed disabled:opacity-30"
        aria-label={"Preview the #{Sound.route_label(@row.key)} sound"}
        title={if @resolved, do: "Plays #{display_name(@resolved)}", else: "Silent"}
      >
        <.icon name="hero-play" class="size-3.5" />
      </button>

      <button
        type="button"
        phx-click="test"
        phx-value-key={@row.key}
        class="grid size-7 place-items-center rounded border-2 border-base-content/20 text-base-content/70 transition hover:border-primary hover:text-primary"
        aria-label={"Fire a test #{Sound.route_label(@row.key)} notification"}
        title="Test — fires the real thing"
      >
        <.icon name="hero-bell-alert" class="size-3.5" />
      </button>
    </div>
    """
  end

  # The unset option says what the row would play, so the walk is read in the
  # menu rather than in a sentence beside it.
  defp inherit_label("default", nil), do: "Auto · silent"
  defp inherit_label("default", resolved), do: "Auto · #{display_name(resolved)}"
  defp inherit_label(_key, nil), do: "Inherit · silent"
  defp inherit_label(_key, resolved), do: "Inherit · #{display_name(resolved)}"
end
