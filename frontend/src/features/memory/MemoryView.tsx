import { For } from "solid-js";
import type { MemoryEntry } from "../../wails.d";

type MemoryViewProps = {
  memories: MemoryEntry[];
  newMemory: string;
  onMemoryChange: (value: string) => void;
  onAddMemory: (text: string) => void;
  onRemoveMemory: (index: number) => void;
};

export function MemoryView(props: MemoryViewProps) {
  const saveMemory = () => {
    const text = props.newMemory.trim();
    if (!text) return;
    props.onAddMemory(text);
    props.onMemoryChange("");
  };

  return (
    <div class="advanced-subview">
      <div class="view-header">
        <h2>Memory</h2>
        <span class="source-count">{props.memories.length} saved</span>
      </div>

      <div class="memory-add">
        <input
          type="text"
          placeholder="Remember something..."
          value={props.newMemory}
          onInput={(event) => props.onMemoryChange(event.currentTarget.value)}
          onKeyDown={(event) => {
            if (event.key === "Enter") saveMemory();
          }}
        />
        <button class="action-btn" onClick={saveMemory} disabled={!props.newMemory.trim()}>Save</button>
      </div>

      <div class="memory-list">
        <For each={props.memories} fallback={<div class="empty-list">No memories saved yet. Use the input above or `/remember` in chat.</div>}>
          {(entry) => (
            <div class="memory-item">
              <div class="memory-item-info">
                <div class="memory-item-text">{entry.text}</div>
                <div class="memory-item-date">{entry.createdAt.split("T")[0]}</div>
              </div>
              <button class="doc-delete-btn" onClick={() => props.onRemoveMemory(entry.index)}>Forget</button>
            </div>
          )}
        </For>
      </div>
    </div>
  );
}
