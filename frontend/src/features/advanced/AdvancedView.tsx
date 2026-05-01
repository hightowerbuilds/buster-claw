import { createSignal, Show } from "solid-js";
import { DeliveryView } from "../delivery/DeliveryView";
import { DocsView } from "../docs/DocsView";
import { MemoryView } from "../memory/MemoryView";
import type { DeliveryDestination, MemoryEntry } from "../../wails.d";

type DeliveryForm = {
  name: string;
  type: string;
  url: string;
  token: string;
  chatId: string;
};

type AdvancedTab = "delivery" | "docs" | "memory";

type AdvancedViewProps = {
  visible: boolean;
  destinations: DeliveryDestination[];
  deliveryForm: DeliveryForm;
  memories: MemoryEntry[];
  newMemory: string;
  onDeliveryFormChange: (field: keyof DeliveryForm, value: string) => void;
  onAddDestination: (destination: DeliveryForm) => void;
  onTestDestination: (name: string) => void;
  onDeleteDestination: (name: string) => void;
  onMemoryChange: (value: string) => void;
  onAddMemory: (text: string) => void;
  onRemoveMemory: (index: number) => void;
};

export function AdvancedView(props: AdvancedViewProps) {
  const [activeTab, setActiveTab] = createSignal<AdvancedTab>("delivery");

  return (
    <div class="view-panel" classList={{ hidden: !props.visible }}>
      <div class="view-panel-content advanced-panel">
        <div class="view-header">
          <div>
            <h2>Advanced</h2>
            <p>Configuration for automation, integrations, and system-level behavior.</p>
          </div>
        </div>

        <div class="advanced-tabs">
          <button
            class="advanced-tab"
            classList={{ active: activeTab() === "delivery" }}
            onClick={() => setActiveTab("delivery")}
          >
            Delivery
          </button>
          <button
            class="advanced-tab"
            classList={{ active: activeTab() === "docs" }}
            onClick={() => setActiveTab("docs")}
          >
            Docs
          </button>
          <button
            class="advanced-tab"
            classList={{ active: activeTab() === "memory" }}
            onClick={() => setActiveTab("memory")}
          >
            Memory
          </button>
        </div>

        <Show when={activeTab() === "delivery"}>
          <DeliveryView
            destinations={props.destinations}
            form={props.deliveryForm}
            onFormChange={props.onDeliveryFormChange}
            onAddDestination={props.onAddDestination}
            onTestDestination={props.onTestDestination}
            onDeleteDestination={props.onDeleteDestination}
          />
        </Show>
        <Show when={activeTab() === "docs"}>
          <DocsView />
        </Show>
        <Show when={activeTab() === "memory"}>
          <MemoryView
            memories={props.memories}
            newMemory={props.newMemory}
            onMemoryChange={props.onMemoryChange}
            onAddMemory={props.onAddMemory}
            onRemoveMemory={props.onRemoveMemory}
          />
        </Show>
      </div>
    </div>
  );
}
