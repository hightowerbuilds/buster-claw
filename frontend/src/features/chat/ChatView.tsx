import { createEffect, For, Show } from "solid-js";
import type { ChatMessage } from "../../wails.d";

type ChatViewProps = {
  visible: boolean;
  messages: ChatMessage[];
  input: string;
  currentModel: string;
  searching: string;
  waiting: boolean;
  streaming: boolean;
  streamBuffer: string;
  onInputChange: (value: string) => void;
  onSend: () => void;
};

export function ChatView(props: ChatViewProps) {
  let messagesEnd: HTMLDivElement | undefined;

  createEffect(() => {
    props.messages.length;
    props.streamBuffer;
    messagesEnd?.scrollIntoView({ behavior: "smooth" });
  });

  const handleKeyDown = (event: KeyboardEvent) => {
    if (event.key === "Enter" && !event.shiftKey) {
      event.preventDefault();
      props.onSend();
    }
  };

  return (
    <div class="chat-area" classList={{ hidden: !props.visible }}>
      <div class="messages">
        <Show when={props.messages.length > 0 || props.streaming} fallback={
          <div class="empty-state">
            <h2>Welcome to Buster Claw</h2>
            <p>Chat with your local model or run the pipeline.</p>
            <p style="font-size: 11px; color: var(--text-muted)">Model: {props.currentModel || "none selected"}</p>
          </div>
        }>
          <For each={props.messages}>{(message) => (
            <div class={`message ${message.role}`}>
              <div class="message-role">{message.role === "user" ? "You" : "Gemma"}</div>
              <div class="message-content">{message.content}</div>
            </div>
          )}</For>
          <Show when={props.searching}>
            <div class="message assistant searching">
              <div class="message-role">Gemma</div>
              <div class="message-content">Searching the web for "{props.searching}"<span class="streaming-indicator" /></div>
            </div>
          </Show>
          <Show when={props.waiting && !props.searching}>
            <div class="message assistant">
              <div class="message-role">Gemma</div>
              <div class="message-content thinking-dots"><span /><span /><span /></div>
            </div>
          </Show>
          <Show when={props.streaming && props.streamBuffer}>
            <div class="message assistant">
              <div class="message-role">Gemma</div>
              <div class="message-content">{props.streamBuffer}<span class="streaming-indicator" /></div>
            </div>
          </Show>
        </Show>
        <div ref={messagesEnd} />
      </div>
      <div class="input-area">
        <div class="input-row">
          <input
            type="text"
            placeholder={props.currentModel ? "Send a message..." : "No model selected"}
            value={props.input}
            onInput={(event) => props.onInputChange(event.currentTarget.value)}
            onKeyDown={handleKeyDown}
            disabled={!props.currentModel || props.streaming}
          />
          <button onClick={props.onSend} disabled={!props.currentModel || props.streaming || !props.input.trim()}>Send</button>
        </div>
      </div>
    </div>
  );
}
