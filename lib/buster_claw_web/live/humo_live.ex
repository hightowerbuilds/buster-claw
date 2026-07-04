defmodule BusterClawWeb.HumoLive do
  @moduledoc """
  Humo tab — the shader-driven chat surface (see HUMO_ROADMAP.md).

  Phase 1: a real conversation with Humo's own headless Claude
  (`BusterClaw.Humo`, the shared `Agent.Chat` engine on the reserved `"humo"`
  conversation), rendered twice at once:

  - **The DOM transcript** (this view) — selectable, screen-reader-available,
    always legible. The accessibility invariant (Cross-cutting §A): the shader
    only ever *presents* the conversation, this list *is* it. **Closed by
    default** (operator call, 07-03): the smoke is the primary reading surface,
    and one click on the "text" toggle opens the plain version.
  - **The smoke** (`HumoSurface` hook, `assets/js/humo/`) — the same turns as
    shader state: thinking = churn, the latest reply condensing out of the fog,
    settling legible. Server → hook via `push_event` (`humo:phase`,
    `humo:text`); the mapping to uniforms lives client-side in `mapChatState`.

  The canvas container is `phx-update="ignore"`: the hook owns everything
  inside it, and LiveView must never patch over a live GPU canvas.
  """
  use BusterClawWeb, :live_view

  alias BusterClaw.Humo
  alias BusterClaw.Humo.Expression

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Humo.subscribe()

    status = Humo.status()

    {:ok,
     socket
     |> assign(:page_title, "Humo")
     |> assign(:messages, load_transcript())
     |> assign(:running, status == :running)
     |> assign(:thinking, if(status == :running, do: :running))
     |> assign(:queue_len, 0)
     |> assign(:show_text, false)
     |> assign(:draft, "")}
  end

  @impl true
  def handle_event("send", %{"text" => text}, socket) do
    text = String.trim(text)

    socket =
      if text == "" do
        socket
      else
        case Humo.send_message(text) do
          :ok -> assign(socket, :draft, "")
          {:error, reason} -> put_flash(socket, :error, "Humo send failed: #{inspect(reason)}")
        end
      end

    {:noreply, socket}
  end

  def handle_event("draft", %{"text" => text}, socket),
    do: {:noreply, assign(socket, :draft, text)}

  def handle_event("cut_run", _params, socket) do
    Humo.interrupt()
    {:noreply, socket}
  end

  # Wipe the conversation: reset Humo's Claude session and delete the transcript,
  # then clear this view. We reset locally rather than waiting on the `{:reset}`
  # broadcast because `Chat.reset/1` only broadcasts when a run process exists —
  # clearing stale persisted history (no live session) must still empty the view.
  def handle_event("clear_chat", _params, socket) do
    Humo.clear()
    {:noreply, reset_view(socket)}
  end

  def handle_event("toggle_text", _params, socket),
    do: {:noreply, update(socket, :show_text, &(!&1))}

  # Assistant replies may carry `humo-*` expression blocks. Strip them out
  # (they never show as raw JSON), drive the surface with each expression, and
  # render/read out only the clean text. A reply that was *only* an expression
  # adds no transcript bubble.
  @impl true
  def handle_info({:agent_chat, _conv, {:message, %{role: :assistant, text: text}}}, socket) do
    {clean, expressions} = Expression.extract(text)

    socket = Enum.reduce(expressions, socket, &apply_expression/2)

    socket =
      if clean == "" do
        socket
      else
        socket
        |> update(:messages, &(&1 ++ [%{role: :assistant, text: clean}]))
        |> push_event("humo:text", %{text: clean})
      end

    {:noreply, socket}
  end

  def handle_info({:agent_chat, _conv, {:message, msg}}, socket) do
    socket = update(socket, :messages, &(&1 ++ [msg]))

    socket =
      case msg.role do
        :meta -> push_event(socket, "humo:phase", %{phase: "settled"})
        :error -> push_event(socket, "humo:phase", %{phase: "idle"})
        _ -> socket
      end

    {:noreply, socket}
  end

  def handle_info({:agent_chat, _conv, {:status, :running}}, socket) do
    {:noreply,
     socket
     |> assign(:running, true)
     |> assign(:thinking, :running)
     |> push_event("humo:phase", %{phase: "thinking"})}
  end

  def handle_info({:agent_chat, _conv, {:status, :idle}}, socket) do
    {:noreply,
     socket
     |> assign(:running, false)
     |> assign(:thinking, nil)
     |> push_event("humo:phase", %{phase: "idle"})}
  end

  def handle_info({:agent_chat, _conv, {:thinking, ms}}, socket),
    do: {:noreply, assign(socket, :thinking, {:done, ms})}

  def handle_info({:agent_chat, _conv, {:queue, items}}, socket),
    do: {:noreply, assign(socket, :queue_len, length(items))}

  # The conversation was cleared from another connected client: mirror it here.
  def handle_info({:agent_chat, _conv, {:reset}}, socket),
    do: {:noreply, reset_view(socket)}

  def handle_info({:agent_chat, _conv, _payload}, socket), do: {:noreply, socket}

  # Empty the transcript, settle the indicators, and blank the smoke surface.
  defp reset_view(socket) do
    socket
    |> assign(:messages, [])
    |> assign(:running, false)
    |> assign(:thinking, nil)
    |> assign(:queue_len, 0)
    |> push_event("humo:reset", %{})
  end

  # Dispatch one parsed expression to the surface. `style` drives the smoke's
  # mood/render-mode; future types (`graph`, `draw`) render to the content
  # texture. The JS normalizer clamps the spec before it reaches the GPU.
  defp apply_expression(%{type: "style", data: data}, socket),
    do: push_event(socket, "humo:style", %{spec: data})

  defp apply_expression(%{type: "graph", data: data}, socket) when is_map(data),
    do: push_event(socket, "humo:graph", %{graph: data})

  defp apply_expression(%{type: "draw", data: %{"shapes" => shapes}}, socket)
       when is_list(shapes),
       do: push_event(socket, "humo:draw", %{shapes: shapes})

  defp apply_expression(_unknown, socket), do: socket

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} full_bleed>
      <div class="relative min-h-0 flex-1 overflow-hidden bg-[#121212]">
        <%!-- Smoke layer — hook-owned; LiveView never patches inside. --%>
        <div id="humo-surface" phx-hook="HumoSurface" phx-update="ignore" class="absolute inset-0">
          <canvas data-humo-canvas class="absolute inset-0 block h-full w-full"></canvas>
          <div
            data-humo-status
            class="absolute left-3 top-3 font-mono text-[11px] uppercase tracking-widest text-[#f4f1ea]/40"
          >
            humo · booting…
          </div>
        </div>

        <%!-- Conversation layer — the accessible source of truth. --%>
        <div class="relative z-10 mx-auto flex h-full w-full max-w-3xl flex-col px-4 py-6">
          <header class="flex items-center justify-between pb-3">
            <div>
              <p class="ic-eyebrow text-[#ff4d1c]">Humo</p>
              <p class="font-mono text-[11px] uppercase tracking-widest text-[#f4f1ea]/50">
                written in smoke · its own claude
              </p>
            </div>
            <div class="flex items-center gap-3">
              <span
                :if={@thinking}
                id="humo-thinking"
                phx-hook="ThinkingTimer"
                data-state={if(match?({:done, _}, @thinking), do: "done", else: "running")}
                data-ms={with {:done, ms} <- @thinking, do: ms}
                class="font-mono text-[11px] uppercase tracking-widest text-[#ff4d1c]/80"
              >
                <span data-thinking-label>Thinking…</span>
              </span>
              <span
                :if={@queue_len > 0}
                class="font-mono text-[11px] uppercase tracking-widest text-[#f4f1ea]/50"
              >
                {@queue_len} queued
              </span>
              <button
                :if={@running}
                phx-click="cut_run"
                class="border border-[#ff4d1c]/60 px-3 py-1 font-mono text-[11px] uppercase tracking-widest text-[#ff4d1c] transition hover:bg-[#ff4d1c]/10"
              >
                Stop
              </button>
              <button
                :if={@messages != []}
                phx-click="clear_chat"
                data-confirm="Clear this conversation? The transcript is deleted and Humo forgets its context."
                class="border border-[#f4f1ea]/25 px-3 py-1 font-mono text-[11px] uppercase tracking-widest text-[#f4f1ea]/60 transition hover:border-[#ff4d1c] hover:text-[#ff4d1c]"
              >
                Clear
              </button>
              <button
                phx-click="toggle_text"
                aria-expanded={to_string(@show_text)}
                aria-controls="humo-log"
                class="border border-[#f4f1ea]/25 px-3 py-1 font-mono text-[11px] uppercase tracking-widest text-[#f4f1ea]/60 transition hover:border-[#f4f1ea]/60 hover:text-[#f4f1ea]"
              >
                {if @show_text, do: "▾ hide text", else: "▸ show text"}
              </button>
            </div>
          </header>

          <%!-- The smoke is the primary reading surface; the plain transcript
               opens on demand and stays the accessible source of truth. --%>
          <div
            :if={@show_text}
            id="humo-log"
            phx-hook="HumoTranscript"
            class="min-h-0 flex-1 space-y-3 overflow-y-auto bg-[#121212]/35 py-2 pr-1 backdrop-blur-[2px]"
            aria-live="polite"
          >
            <div :for={msg <- @messages} class={message_classes(msg.role)}>
              <p class="whitespace-pre-wrap break-words">{msg.text}</p>
            </div>
          </div>
          <%!-- Closed: leave the fog unobstructed; clicking it opens the text. --%>
          <button
            :if={!@show_text}
            phx-click="toggle_text"
            aria-label="Show the conversation as text"
            class="min-h-0 flex-1 cursor-text"
          >
          </button>

          <form phx-submit="send" phx-change="draft" class="flex gap-2 pt-3">
            <input
              type="text"
              name="text"
              value={@draft}
              autocomplete="off"
              placeholder="Say something into the smoke…"
              class="min-w-0 flex-1 border border-[#f4f1ea]/25 bg-[#121212]/70 px-3 py-2 font-mono text-sm text-[#f4f1ea] placeholder-[#f4f1ea]/30 backdrop-blur transition focus:border-[#ff4d1c] focus:outline-none"
            />
            <button
              type="submit"
              class="border border-[#f4f1ea]/40 px-4 py-2 font-mono text-[11px] uppercase tracking-widest text-[#f4f1ea] transition hover:border-[#ff4d1c] hover:text-[#ff4d1c]"
            >
              Send
            </button>
          </form>
        </div>
      </div>
    </Layouts.app>
    """
  end

  # Transcript entries double as the readable fallback when the shader is off
  # or unavailable, so every role gets an explicit, legible treatment.
  defp message_classes(:user),
    do:
      "border-l-2 border-[#ff4d1c] bg-[#121212]/55 px-3 py-2 text-sm text-[#f4f1ea] backdrop-blur-sm"

  defp message_classes(:assistant),
    do: "bg-[#121212]/55 px-3 py-2 text-sm text-[#f4f1ea]/90 backdrop-blur-sm"

  defp message_classes(:tool),
    do: "px-3 py-1 font-mono text-xs text-[#f4f1ea]/50"

  defp message_classes(:error),
    do: "border-l-2 border-[#ff4d1c] px-3 py-2 font-mono text-xs text-[#ff4d1c]"

  defp message_classes(_meta),
    do: "px-3 py-1 font-mono text-[11px] uppercase tracking-widest text-[#f4f1ea]/40"

  # Persisted roles are strings from a bounded set; broadcast roles are atoms.
  defp load_transcript do
    Enum.map(Humo.recent(), fn m -> %{role: role_atom(m.role), text: m.content} end)
  end

  @role_atoms %{
    "user" => :user,
    "assistant" => :assistant,
    "tool" => :tool,
    "meta" => :meta,
    "error" => :error
  }
  defp role_atom(role), do: Map.get(@role_atoms, role, :meta)
end
