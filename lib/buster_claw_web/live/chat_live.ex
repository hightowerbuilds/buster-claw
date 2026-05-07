defmodule BusterClawWeb.ChatLive do
  use BusterClawWeb, :live_view

  alias BusterClaw.Chat

  @impl true
  def mount(_params, _session, socket) do
    session_id = Chat.default_session()
    if connected?(socket), do: Phoenix.PubSub.subscribe(BusterClaw.PubSub, Chat.topic(session_id))

    {:ok,
     socket
     |> assign(:page_title, "Chat")
     |> assign(:session_id, session_id)
     |> assign(:input, "")
     |> assign(:stream_buffer, "")
     |> assign(:waiting, false)
     |> assign(:streaming, false)
     |> assign(:messages, Chat.messages(session_id))}
  end

  @impl true
  def handle_event("update_input", %{"prompt" => prompt}, socket) do
    {:noreply, assign(socket, :input, prompt)}
  end

  def handle_event("send_message", %{"prompt" => prompt}, socket) do
    waiting = not String.starts_with?(String.trim(prompt), "/")

    Chat.send_message(socket.assigns.session_id, prompt)
    {:noreply, assign(socket, input: "", waiting: waiting, stream_buffer: "")}
  end

  def handle_event("clear_chat", _params, socket) do
    Chat.clear(socket.assigns.session_id)

    {:noreply,
     assign(socket, messages: [], input: "", stream_buffer: "", waiting: false, streaming: false)}
  end

  @impl true
  def handle_info({:message, %{message: message}}, socket) do
    {:noreply, assign(socket, :messages, socket.assigns.messages ++ [message])}
  end

  def handle_info({:waiting, _payload}, socket) do
    {:noreply, assign(socket, waiting: true, streaming: false)}
  end

  def handle_info({:token, %{chunk: chunk}}, socket) do
    {:noreply,
     assign(socket,
       waiting: false,
       streaming: true,
       stream_buffer: socket.assigns.stream_buffer <> chunk
     )}
  end

  def handle_info({:done, %{content: content}}, socket) do
    message = %BusterClaw.Chat.Message{role: "assistant", content: content}

    {:noreply,
     assign(socket,
       messages: socket.assigns.messages ++ [message],
       waiting: false,
       streaming: false,
       stream_buffer: ""
     )}
  end

  def handle_info({:error, %{error: error}}, socket) do
    message = %BusterClaw.Chat.Message{role: "assistant", content: error}

    {:noreply,
     assign(socket,
       messages: socket.assigns.messages ++ [message],
       waiting: false,
       streaming: false,
       stream_buffer: ""
     )}
  end

  def handle_info({:cleared, _payload}, socket) do
    {:noreply, assign(socket, messages: [], waiting: false, streaming: false, stream_buffer: "")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <section class="flex min-h-[70vh] flex-col gap-6">
        <div>
          <p class="text-sm font-semibold uppercase tracking-wide text-base-content/60">
            Session
          </p>
          <h1 class="text-4xl font-semibold tracking-normal">Chat</h1>
          <p class="mt-2 text-base text-base-content/70">
            Supervised local chat session with provider routing and slash commands.
          </p>
        </div>

        <section class="flex-1 rounded-lg border border-base-300 bg-base-100">
          <div class="max-h-[55vh] min-h-[360px] space-y-4 overflow-auto p-4">
            <div
              :for={message <- @messages}
              class={[
                "rounded-lg border border-base-300 p-4",
                if(message.role == "user", do: "bg-base-200", else: "bg-base-100")
              ]}
            >
              <div class="mb-2 text-xs font-semibold uppercase tracking-wide text-base-content/60">
                {message.role}
              </div>
              <div class="whitespace-pre-wrap text-sm leading-6">{message.content}</div>
            </div>

            <div :if={@waiting} class="rounded-lg border border-base-300 bg-base-200 p-4 text-sm">
              Waiting for provider...
            </div>

            <div
              :if={@streaming and @stream_buffer != ""}
              class="rounded-lg border border-base-300 bg-base-100 p-4"
            >
              <div class="mb-2 text-xs font-semibold uppercase tracking-wide text-base-content/60">
                assistant
              </div>
              <div class="whitespace-pre-wrap text-sm leading-6">{@stream_buffer}</div>
            </div>
          </div>
        </section>

        <form phx-submit="send_message" phx-change="update_input" class="space-y-3">
          <textarea
            name="prompt"
            class="min-h-28 w-full rounded-lg border border-base-300 bg-base-100 p-4 text-sm"
            placeholder="Message Buster Claw or type /help"
          >{@input}</textarea>
          <div class="flex justify-between gap-3">
            <button
              type="button"
              class="rounded border border-base-300 px-4 py-2 text-sm"
              phx-click="clear_chat"
            >
              Clear
            </button>
            <button class="rounded bg-base-content px-4 py-2 text-sm font-semibold text-base-100">
              Send
            </button>
          </div>
        </form>
      </section>
    </Layouts.app>
    """
  end
end
