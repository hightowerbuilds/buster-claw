import { createSignal, Show } from "solid-js";
import { ModelsView } from "../models/ModelsView";
import { ProvidersView } from "../providers/ProvidersView";
import type { ProviderInfo } from "../../wails.d";

type ProviderForm = {
  name: string;
  type: string;
  baseUrl: string;
  apiKey: string;
  model: string;
};

type IntelligenceTab = "models" | "providers";

type IntelligenceViewProps = {
  visible: boolean;
  models: string[];
  currentModel: string;
  providers: ProviderInfo[];
  providerForm: ProviderForm;
  testResult: string;
  onRefreshModels: () => void;
  onSelectModel: (model: string) => void;
  onProviderFormChange: (field: keyof ProviderForm, value: string) => void;
  onAddProvider: (provider: ProviderForm) => void;
  onActivateProvider: (name: string) => void;
  onRemoveProvider: (name: string) => void;
  onTestProvider: (name: string) => void;
};

export function IntelligenceView(props: IntelligenceViewProps) {
  const [activeTab, setActiveTab] = createSignal<IntelligenceTab>("models");

  return (
    <div class="view-panel" classList={{ hidden: !props.visible }}>
      <div class="view-panel-content advanced-panel">
        <div class="view-header">
          <div>
            <h2>Intelligence</h2>
            <p>Configure local models and external model providers.</p>
          </div>
        </div>

        <div class="advanced-tabs">
          <button
            class="advanced-tab"
            classList={{ active: activeTab() === "models" }}
            onClick={() => setActiveTab("models")}
          >
            Models
          </button>
          <button
            class="advanced-tab"
            classList={{ active: activeTab() === "providers" }}
            onClick={() => setActiveTab("providers")}
          >
            Providers
          </button>
        </div>

        <Show when={activeTab() === "models"}>
          <ModelsView
            models={props.models}
            currentModel={props.currentModel}
            onRefresh={props.onRefreshModels}
            onSelectModel={props.onSelectModel}
          />
        </Show>

        <Show when={activeTab() === "providers"}>
          <ProvidersView
            providers={props.providers}
            testResult={props.testResult}
            form={props.providerForm}
            onFormChange={props.onProviderFormChange}
            onAddProvider={props.onAddProvider}
            onActivateProvider={props.onActivateProvider}
            onRemoveProvider={props.onRemoveProvider}
            onTestProvider={props.onTestProvider}
          />
        </Show>
      </div>
    </div>
  );
}
