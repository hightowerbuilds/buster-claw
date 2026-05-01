import { AnalysisView } from "../features/analysis/AnalysisView";
import { AdvancedView } from "../features/advanced/AdvancedView";
import { CalendarView } from "../features/calendar/CalendarView";
import { ChatView } from "../features/chat/ChatView";
import { DocumentsView } from "../features/documents/DocumentsView";
import { HomeView } from "../features/home/HomeView";
import { IngestionView } from "../features/ingestion/IngestionView";
import { IntelligenceView } from "../features/intelligence/IntelligenceView";
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
        calendarEvents={app.calendarEvents}
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
        busy={app.busy}
        streaming={app.streaming}
        documents={app.documents}
        analysisQueue={app.analysisQueue}
        pendingFiles={app.pendingFiles}
        selectedDocument={app.selectedDocument}
        documentContent={app.documentContent}
        onDeleteDocument={app.deleteDocument}
        onRunQueue={app.runQueue}
        onQueueDocument={app.queueDocument}
        onOpenDocument={app.openDocument}
        onCloseDocument={app.closeDocument}
      />

      <AnalysisView
        visible={app.activeView === "analysis"}
        reports={app.reports}
        selectedReport={app.selectedReport}
        reportContent={app.reportContent}
        onOpenReport={app.openReport}
        onCloseReport={app.closeReport}
      />

      <CalendarView
        visible={app.activeView === "calendar"}
        events={app.calendarEvents}
        jobs={app.jobs}
      />

      <IntelligenceView
        visible={app.activeView === "intelligence"}
        models={app.models}
        currentModel={app.currentModel}
        providers={app.providers}
        providerForm={app.providerForm}
        testResult={app.testResult}
        onRefreshModels={app.refreshModels}
        onSelectModel={app.switchModel}
        onProviderFormChange={app.updateProviderForm}
        onAddProvider={app.addProvider}
        onActivateProvider={app.activateProvider}
        onRemoveProvider={app.removeProvider}
        onTestProvider={app.testProvider}
      />

      <WebhooksView
        visible={app.activeView === "webhooks"}
        webhooks={app.webhooks}
        webhookForm={app.webhookForm}
        hooks={app.pipelineHooks}
        hookForm={app.hookForm}
        onWebhookFormChange={app.updateWebhookForm}
        onHookFormChange={app.updateHookForm}
        onAddWebhook={app.addWebhook}
        onToggleWebhook={app.toggleWebhook}
        onDeleteWebhook={app.deleteWebhook}
        onAddHook={app.addHook}
        onDeleteHook={app.deleteHook}
      />

      <AdvancedView
        visible={app.activeView === "advanced"}
        destinations={app.destinations}
        deliveryForm={app.deliveryForm}
        memories={app.memories}
        newMemory={app.newMemory}
        onDeliveryFormChange={app.updateDeliveryForm}
        onAddDestination={app.addDestination}
        onTestDestination={app.testDestination}
        onDeleteDestination={app.deleteDestination}
        onMemoryChange={app.setNewMemory}
        onAddMemory={app.addMemory}
        onRemoveMemory={app.removeMemory}
      />
    </div>
  );
}
