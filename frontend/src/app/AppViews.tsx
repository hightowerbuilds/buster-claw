import { AnalysisView } from "../features/analysis/AnalysisView";
import { ChatView } from "../features/chat/ChatView";
import { DeliveryView } from "../features/delivery/DeliveryView";
import { DocsView } from "../features/docs/DocsView";
import { DocumentsView } from "../features/documents/DocumentsView";
import { HomeView } from "../features/home/HomeView";
import { HooksView } from "../features/hooks/HooksView";
import { IngestionView } from "../features/ingestion/IngestionView";
import { MemoryView } from "../features/memory/MemoryView";
import { ModelsView } from "../features/models/ModelsView";
import { OrchestrationView } from "../features/orchestration/OrchestrationView";
import { ProvidersView } from "../features/providers/ProvidersView";
import { SchedulerView } from "../features/scheduler/SchedulerView";
import { WebhooksView } from "../features/webhooks/WebhooksView";
import type { useAppController } from "./useAppController";

type AppViewsProps = {
  controller: ReturnType<typeof useAppController>;
};

export function AppViews(props: AppViewsProps) {
  const app = props.controller;

  return (
    <div class="main-content">
      <HomeView
        visible={app.activeView === "home"}
        jobs={app.jobs}
        reports={app.reports}
        documents={app.documents}
        analysisQueue={app.analysisQueue}
        pendingFiles={app.pendingFiles}
        onOpenReport={(report) => {
          app.openReport(report);
          app.switchView("analysis");
        }}
      />

      <ChatView
        visible={app.activeView === "chat"}
        messages={app.messages}
        input={app.input}
        currentModel={app.currentModel}
        searching={app.searching}
        waiting={app.waiting}
        streaming={app.streaming}
        streamBuffer={app.streamBuffer}
        onInputChange={app.setInput}
        onSend={app.sendMessage}
      />

      <IngestionView
        visible={app.activeView === "ingestion"}
        busy={app.busy}
        streaming={app.streaming}
        sources={app.sources}
        sourceUrl={app.sourceForm.url}
        sourceName={app.sourceForm.name}
        sourceType={app.sourceForm.type}
        sourceTags={app.sourceForm.tags}
        onSourceUrlChange={app.setNewSourceUrl}
        onSourceNameChange={app.setNewSourceName}
        onSourceTypeChange={app.setNewSourceType}
        onSourceTagsChange={app.setNewSourceTags}
        onStartIngest={app.startIngest}
        onIngestSingle={app.ingestSingle}
        onDeleteSource={app.deleteSource}
        onAddSource={app.addSource}
      />

      <DocumentsView
        visible={app.activeView === "documents"}
        documents={app.documents}
        onDeleteDocument={app.deleteDocument}
      />

      <OrchestrationView
        visible={app.activeView === "orchestration"}
        busy={app.busy}
        streaming={app.streaming}
        analysisQueue={app.analysisQueue}
        pendingFiles={app.pendingFiles}
        onRunQueue={app.runQueue}
        onRemoveFromQueue={app.removeFromQueue}
        onQueueDocument={app.queueDocument}
      />

      <AnalysisView
        visible={app.activeView === "analysis"}
        reports={app.reports}
        selectedReport={app.selectedReport}
        reportContent={app.reportContent}
        onOpenReport={app.openReport}
        onCloseReport={app.closeReport}
      />

      <ModelsView
        visible={app.activeView === "models"}
        models={app.models}
        currentModel={app.currentModel}
        onRefresh={app.refreshModels}
        onSelectModel={app.switchModel}
      />

      <ProvidersView
        visible={app.activeView === "providers"}
        providers={app.providers}
        testResult={app.testResult}
        form={app.providerForm}
        onFormChange={app.updateProviderForm}
        onAddProvider={app.addProvider}
        onActivateProvider={app.activateProvider}
        onRemoveProvider={app.removeProvider}
        onTestProvider={app.testProvider}
      />

      <MemoryView
        visible={app.activeView === "memory"}
        memories={app.memories}
        newMemory={app.newMemory}
        onMemoryChange={app.setNewMemory}
        onAddMemory={app.addMemory}
        onRemoveMemory={app.removeMemory}
      />

      <SchedulerView
        visible={app.activeView === "scheduler"}
        jobs={app.jobs}
        form={app.jobForm}
        onFormChange={app.updateJobForm}
        onAddJob={app.addJob}
        onToggleJob={app.toggleJob}
        onRunJobNow={app.runJobNow}
        onDeleteJob={app.deleteJob}
      />

      <WebhooksView
        visible={app.activeView === "webhooks"}
        webhooks={app.webhooks}
        form={app.webhookForm}
        onFormChange={app.updateWebhookForm}
        onAddWebhook={app.addWebhook}
        onToggleWebhook={app.toggleWebhook}
        onDeleteWebhook={app.deleteWebhook}
      />

      <DeliveryView
        visible={app.activeView === "delivery"}
        destinations={app.destinations}
        form={app.deliveryForm}
        onFormChange={app.updateDeliveryForm}
        onAddDestination={app.addDestination}
        onTestDestination={app.testDestination}
        onDeleteDestination={app.deleteDestination}
      />

      <HooksView
        visible={app.activeView === "hooks"}
        hooks={app.pipelineHooks}
        form={app.hookForm}
        onFormChange={app.updateHookForm}
        onAddHook={app.addHook}
        onDeleteHook={app.deleteHook}
      />

      <DocsView visible={app.activeView === "docs"} />
    </div>
  );
}
