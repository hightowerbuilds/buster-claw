defmodule BusterClawWeb.SketchComponent do
  @moduledoc """
  The Sketch Pad's state: the document, the selection, the undo stack, and the
  autosave.

  `SKETCH_ROADMAP` Phase 1. The substrate reversal happens here — the server owns
  the drawing and the DOM is its projection, where the first version had the
  browser own every pixel and the server no opinion at all.

  That is a deliberate reversal of a decision that was right for what it was built
  for. The Notes rule it cited (*do not build a parallel model beside the DOM*)
  is not broken by this: the answer here is not two models but **one**, on the
  server, rendered as SVG. There is no element state in JavaScript to drift.

  ## What still happens in the browser, and why

  A stroke being drawn is not sent to the server. `pointermove` fires per pixel
  and a round trip per point would be visible as lag on the one interaction that
  must feel immediate. The hook draws the in-flight stroke into its own layer and
  pushes the finished points once, on `pointerup`.

  So the split is: **the browser owns a stroke until it is finished; the server
  owns every stroke that is.** Nothing is duplicated — at any moment a given
  stroke is exactly one of the two.

  ## Autosave writes on every change

  Not debounced. The file is small, the write is atomic, and the drawing is the
  only copy — there is no database behind it. Losing thirty seconds of work to a
  crash to save a few file writes on a local machine is the wrong trade.

  ## Undo keeps documents, not inverse operations

  `Document`'s operations are pure, so the previous document *is* the undo state.
  A list of them costs a few hundred small maps and cannot be wrong, where a log
  of inverses has to be correct for every operation including the ones added
  later. Bounded at #{50} steps.
  """
  use BusterClawWeb, :live_component

  require Logger

  alias BusterClaw.Sketch.{Assets, Document, Element, Placement, Store}
  alias BusterClawWeb.Studio.{Sketch, SketchSvg}

  @history_limit 50
  @default_name "untitled"
  @tools ~w(draw erase select)a

  # More than a handful at once is a folder someone dragged by accident.
  @max_images_at_once 5

  @impl true
  def mount(socket) do
    {:ok,
     socket
     # Bytes only ever arrive through LiveView's own upload, and the refusals
     # that matter run on the CLIENT before one moves — `max_file_size` here, and
     # image-only filtering in the hook. What lands server-side is checked again
     # by `Assets`, because a client refusal is a courtesy and not a boundary.
     |> allow_upload(:sketch_image,
       accept: ~w(.png .jpg .jpeg .gif .webp),
       max_entries: @max_images_at_once,
       max_file_size: Assets.max_bytes(),
       auto_upload: true,
       progress: &consume_image/3
     )
     |> assign(:drop_point, nil)
     |> assign(:max_images, @max_images_at_once)
     |> assign(:name, @default_name)
     |> assign(:tool, :draw)
     |> assign(:color, Sketch.default_color())
     |> assign(:width, Sketch.default_width())
     |> assign(:selected, nil)
     |> assign(:history, [])
     |> assign(:notice, nil)
     |> assign(:doc, Document.new())}
  end

  @impl true
  def update(assigns, socket) do
    # Load once, on the first update. A tab switch re-mounts this component, and
    # re-reading the file then is exactly what makes the drawing survive one.
    socket = assign(socket, assigns)

    if socket.assigns[:loaded?] do
      {:ok, socket}
    else
      {:ok, socket |> assign(:loaded?, true) |> load()}
    end
  end

  defp load(socket) do
    name = socket.assigns.name

    case Store.load(name) do
      {:ok, doc} ->
        assign(socket, doc: doc, notice: nil)

      {:error, :not_found} ->
        assign(socket, doc: Document.new(%{title: name}), notice: nil)

      {:error, reason} ->
        # Deliberately NOT an empty canvas. Handing back a blank one is how
        # someone saves over the drawing they were trying to recover.
        Logger.warning("SketchComponent: cannot load #{name}: #{inspect(reason)}")

        assign(socket,
          doc: Document.new(%{title: name}),
          notice:
            "#{name}.json could not be read, so it was not opened. Nothing has been written."
        )
        |> assign(:read_only, true)
    end
  end

  # -------------------------------------------------------------------- events

  @impl true
  def handle_event("tool", %{"tool" => tool}, socket) do
    case Enum.find(@tools, &(Atom.to_string(&1) == tool)) do
      nil -> {:noreply, socket}
      known -> {:noreply, socket |> assign(:tool, known) |> assign(:selected, nil)}
    end
  end

  def handle_event("color", %{"color" => color}, socket) do
    # Picking a colour is picking up a pen, so it puts the eraser down — the same
    # rule the raster version needed and could not show.
    if color in Sketch.colors() do
      {:noreply, socket |> assign(:color, color) |> assign(:tool, :draw)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("width", %{"width" => width}, socket) do
    case Integer.parse(to_string(width)) do
      {parsed, _rest} ->
        if parsed in Sketch.widths(),
          do: {:noreply, assign(socket, :width, parsed)},
          else: {:noreply, socket}

      :error ->
        {:noreply, socket}
    end
  end

  # A finished stroke, pushed once on pointerup.
  def handle_event("stroke", %{"points" => points}, socket) do
    attrs = %{
      "kind" => "stroke",
      "author" => "operator",
      "points" => points,
      "color" => socket.assigns.color,
      "width" => socket.assigns.width
    }

    case Element.new(attrs) do
      {:ok, element} ->
        {:noreply, commit(socket, Document.add(socket.assigns.doc, element))}

      {:error, reason} ->
        # The operator's own pointer cannot normally produce one of these. If it
        # does, the stroke is dropped and said out loud rather than half-stored.
        Logger.warning("SketchComponent: refusing a stroke: #{inspect(reason)}")

        {:noreply,
         assign(socket, :notice, "That stroke could not be saved (#{inspect(reason)}).")}
    end
  end

  def handle_event("erase", %{"id" => id}, socket) do
    case Document.delete(socket.assigns.doc, id) do
      {:ok, doc} -> {:noreply, commit(socket, doc)}
      # Already gone — the pointer crossed it twice before the first round trip
      # landed. Not an error, and not worth a history entry.
      :error -> {:noreply, socket}
    end
  end

  def handle_event("select", %{"id" => id}, socket) do
    {:noreply, assign(socket, :selected, Document.find(socket.assigns.doc, id) && id)}
  end

  def handle_event("select", _params, socket), do: {:noreply, assign(socket, :selected, nil)}

  def handle_event("move", %{"id" => id, "dx" => dx, "dy" => dy}, socket)
      when is_number(dx) and is_number(dy) do
    case Document.move(socket.assigns.doc, id, {dx, dy}) do
      {:ok, doc} -> {:noreply, commit(socket, doc)}
      :error -> {:noreply, socket}
    end
  end

  def handle_event("delete_selected", _params, socket) do
    with id when is_binary(id) <- socket.assigns.selected,
         {:ok, doc} <- Document.delete(socket.assigns.doc, id) do
      {:noreply, socket |> assign(:selected, nil) |> commit(doc)}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("clear", _params, socket) do
    {:noreply, socket |> assign(:selected, nil) |> commit(Document.clear(socket.assigns.doc))}
  end

  # Where the next image should land. Pushed by the hook the instant a drop or
  # paste happens, because by the time the bytes have uploaded the pointer is
  # somewhere else — and an image that appears where the mouse ended up rather
  # than where it was let go of feels broken even though nothing failed.
  def handle_event("drop_point", %{"x" => x, "y" => y}, socket)
      when is_number(x) and is_number(y) do
    {:noreply, assign(socket, :drop_point, {x, y})}
  end

  def handle_event("drop_point", _params, socket), do: {:noreply, socket}

  # The packaged app's path. macOS WKWebView does not hand file CONTENTS to the
  # DOM on an OS drag, so Tauri gives the hook a path and the server reads it —
  # the same split `ChatDropzone` and `WorkspaceDropzone` already use, and the
  # reason a surface wired only to `phx-drop-target` works in dev and does
  # nothing in the DMG.
  def handle_event("drop_paths", %{"paths" => paths}, socket) when is_list(paths) do
    {:noreply,
     paths
     |> Enum.take(@max_images_at_once)
     |> Enum.reduce(socket, fn path, acc ->
       place_image(acc, fn -> Assets.put_file(acc.assigns.name, path) end, Path.basename(path))
     end)}
  end

  # A client-side refusal — the file never left the browser. Rendered here so one
  # sentence comes back however the file was refused.
  def handle_event("drop_refused", %{"reason" => reason} = params, socket) do
    name = Map.get(params, "filename", "That file")
    {:noreply, assign(socket, :notice, "#{name} was not added — #{refusal(reason)}.")}
  end

  def handle_event("undo", _params, socket) do
    case socket.assigns.history do
      [] ->
        {:noreply, socket}

      [previous | rest] ->
        socket = socket |> assign(doc: previous, history: rest, selected: nil)
        {:noreply, persist(socket)}
    end
  end

  # ------------------------------------------------------------------- images

  # LiveView hands over a temp file it deletes the moment this returns, so the
  # bytes are copied during the consume — there is no later moment to do it in.
  defp consume_image(:sketch_image, entry, socket) do
    if entry.done? do
      {:noreply,
       consume_uploaded_entry(socket, entry, fn %{path: path} ->
         {:ok,
          place_image(
            socket,
            fn -> Assets.put_file(socket.assigns.name, path) end,
            entry.client_name
          )}
       end)}
    else
      {:noreply, socket}
    end
  end

  # One route for every way an image arrives — an upload, a native path, and
  # (Phase 4's other half) a model import — so a refusal reads the same whichever
  # gesture produced it and the placement rule lives in exactly one place.
  defp place_image(socket, store, label) do
    case store.() do
      {:ok, asset} ->
        {w, h} = Placement.fit(asset.width, asset.height)
        {x, y} = Placement.origin(socket.assigns.drop_point || {24, 24}, {w, h})

        attrs = %{
          "kind" => "image",
          "author" => "operator",
          "source" => asset.source,
          "x" => x,
          "y" => y,
          "w" => w,
          "h" => h
        }

        case Element.new(attrs) do
          {:ok, element} ->
            socket
            |> assign(:drop_point, nil)
            |> commit(Document.add(socket.assigns.doc, element))

          {:error, reason} ->
            Logger.warning("SketchComponent: refusing an image element: #{inspect(reason)}")
            assign(socket, :notice, "#{label} could not be placed.")
        end

      {:error, reason} ->
        assign(socket, :notice, "#{label} was not added — #{refusal(reason)}.")
    end
  end

  defp refusal(reason), do: Placement.humanize(reason, Assets.max_bytes(), @max_images_at_once)

  # ------------------------------------------------------------------ internals

  # One door for every mutation: push the old document onto the undo stack, take
  # the new one, write it. Nothing changes the document without going through here.
  defp commit(socket, %Document{} = doc) do
    history = Enum.take([socket.assigns.doc | socket.assigns.history], @history_limit)

    socket |> assign(doc: doc, history: history, notice: nil) |> persist()
  end

  defp persist(socket) do
    if socket.assigns[:read_only] do
      socket
    else
      case Store.save(socket.assigns.name, socket.assigns.doc) do
        {:ok, _path} ->
          socket

        {:error, reason} ->
          Logger.warning("SketchComponent: save failed: #{inspect(reason)}")
          assign(socket, :notice, "Could not write the sketch to disk (#{inspect(reason)}).")
      end
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <%!-- The dropzone wraps the whole pad, so an image dropped anywhere over it
          lands. TWO transports arrive here and only one is live per environment:
          the hook forwards Tauri's native drag-drop as `drop_paths` (paths — the
          packaged app), and in a dev browser the same hook feeds LiveView's
          upload (contents). `phx-drop-target` is what declares this a target;
          the hook still takes the drop itself so it can refuse one before a byte
          moves. Same shape as `ChatDropzone` — see SKETCH_ROADMAP D12. --%>
    <section
      id="studio-sketch"
      data-studio-tab="sketch"
      phx-hook="SketchDropzone"
      phx-target={@myself}
      phx-drop-target={@uploads.sketch_image.ref}
      data-max-bytes={Assets.max_bytes()}
      data-max-files={@max_images}
      class="ic-panel relative flex min-h-0 flex-1 flex-col overflow-hidden"
    >
      <.live_file_input upload={@uploads.sketch_image} class="sr-only" />
      <%!-- The same overlay and class pair as the chat and the workspace, reused
            so there is one drag affordance in the app rather than three. --%>
      <div
        class="bc-drop-overlay pointer-events-none absolute inset-0 z-20 place-items-center bg-base-100/85"
        aria-hidden="true"
      >
        <div class="flex flex-col items-center gap-2 rounded-sm border-2 border-dashed border-primary px-8 py-6">
          <.icon name="hero-photo" class="size-8 text-primary" />
          <p class="font-mono text-xs uppercase tracking-wider text-primary">Drop an image</p>
        </div>
      </div>
      <Sketch.toolbar
        target={@myself}
        tool={@tool}
        color={@color}
        width={@width}
        selected={@selected}
        undoable={@history != []}
      />
      <SketchSvg.surface
        target={@myself}
        sketch={@name}
        elements={@doc.elements}
        selected={@selected}
        tool={@tool}
      />
      <Sketch.status notice={@notice} count={Document.size(@doc)} name={@name} />
    </section>
    """
  end
end
