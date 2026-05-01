package orchestrator

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
	"time"

	"buster-claw/internal/delivery"
	"buster-claw/internal/hooks"
	"buster-claw/internal/ingest"
	"buster-claw/internal/ollama"
	"buster-claw/internal/provider"
)

func TestQueueDocumentDeduplicatesAndRemoveDeletesQueuedWork(t *testing.T) {
	o := newTestOrchestrator(t)
	doc := writeRawDoc(t, o.saveDir, "one.md")

	o.QueueDocument(doc)
	o.QueueDocument(doc)

	entries := o.GetAnalysisQueue()
	if len(entries) != 1 {
		t.Fatalf("expected one deduplicated queue entry, got %d", len(entries))
	}
	if entries[0].Status != "queued" {
		t.Fatalf("expected queued status, got %q", entries[0].Status)
	}
	if got := o.GetStatus().QueueDepth; got != 1 {
		t.Fatalf("expected queue depth 1, got %d", got)
	}

	o.RemoveFromQueue(doc)
	if entries := o.GetAnalysisQueue(); len(entries) != 0 {
		t.Fatalf("expected removed queue entry, got %#v", entries)
	}
	if got := o.GetStatus().QueueDepth; got != 0 {
		t.Fatalf("expected queue depth 0 after remove, got %d", got)
	}

	processed, err := o.RunAnalysis(context.Background())
	if err != nil {
		t.Fatalf("RunAnalysis returned error: %v", err)
	}
	if processed != 0 {
		t.Fatalf("removed document should not be analyzed, processed %d", processed)
	}
}

func TestRunAnalysisProcessesQueuedDocumentsAndTracksStatus(t *testing.T) {
	o := newTestOrchestrator(t)
	o.client = ollama.NewClient(newFakeOllamaServer(t).URL)
	doc := writeRawDoc(t, o.saveDir, "two.md")

	o.QueueDocument(doc)
	processed, err := o.RunAnalysis(context.Background())
	if err != nil {
		t.Fatalf("RunAnalysis returned error: %v", err)
	}
	if processed != 1 {
		t.Fatalf("expected one processed document, got %d", processed)
	}

	entries := o.GetAnalysisQueue()
	if len(entries) != 1 {
		t.Fatalf("expected one queue entry, got %d", len(entries))
	}
	if entries[0].Status != "done" {
		t.Fatalf("expected done status, got %q", entries[0].Status)
	}
	if entries[0].Progress != 100 {
		t.Fatalf("expected complete progress, got %d", entries[0].Progress)
	}
	if entries[0].Report == "" {
		t.Fatalf("expected queue entry to reference the generated report")
	}

	status := o.GetStatus()
	if status.QueueDepth != 0 {
		t.Fatalf("expected empty queue depth, got %d", status.QueueDepth)
	}
	if status.CompletedJobs != 1 {
		t.Fatalf("expected one completed job, got %d", status.CompletedJobs)
	}
	if status.ActiveJob != "" {
		t.Fatalf("expected no active job, got %q", status.ActiveJob)
	}

	reportPath := filepath.Join(o.saveDir, "Library", "reports", time.Now().Format("2006-01-02"), "report-test.md")
	if _, err := os.Stat(reportPath); err != nil {
		t.Fatalf("expected report to be written at %s: %v", reportPath, err)
	}
}

func TestRunAnalysisAcceptsPlainMarkdownWithoutFileWrapper(t *testing.T) {
	o := newTestOrchestrator(t)
	o.client = ollama.NewClient(newPlainMarkdownOllamaServer(t).URL)
	doc := writeRawDoc(t, o.saveDir, "plain-response.md")

	if err := o.QueueDocument(doc); err != nil {
		t.Fatalf("QueueDocument returned error: %v", err)
	}
	processed, err := o.RunAnalysis(context.Background())
	if err != nil {
		t.Fatalf("RunAnalysis returned error for plain markdown: %v", err)
	}
	if processed != 1 {
		t.Fatalf("expected one processed document, got %d", processed)
	}

	entries := o.GetAnalysisQueue()
	if len(entries) != 1 {
		t.Fatalf("expected one queue entry, got %d", len(entries))
	}
	if entries[0].Status != "done" {
		t.Fatalf("expected done status, got %q: %s", entries[0].Status, entries[0].Error)
	}
	if entries[0].Report != "report-plain-response.md" {
		t.Fatalf("expected fallback report name, got %q", entries[0].Report)
	}
}

func TestRunAnalysisReturnsAfterMultipleDocumentFailures(t *testing.T) {
	o := newTestOrchestrator(t)
	o.client = ollama.NewClient(newFailingOllamaServer(t).URL)

	first := writeRawDoc(t, o.saveDir, "failing-one.md")
	second := writeRawDoc(t, o.saveDir, "failing-two.md")
	if err := o.QueueDocument(first); err != nil {
		t.Fatalf("queue first document: %v", err)
	}
	if err := o.QueueDocument(second); err != nil {
		t.Fatalf("queue second document: %v", err)
	}

	type result struct {
		processed int
		err       error
	}
	done := make(chan result, 1)
	go func() {
		processed, err := o.RunAnalysis(context.Background())
		done <- result{processed: processed, err: err}
	}()

	select {
	case got := <-done:
		if got.err == nil {
			t.Fatalf("expected analysis to return the last document error")
		}
		if got.processed != 0 {
			t.Fatalf("expected zero processed documents, got %d", got.processed)
		}
	case <-time.After(2 * time.Second):
		t.Fatalf("RunAnalysis did not return after multiple document failures")
	}

	entries := o.GetAnalysisQueue()
	if len(entries) != 2 {
		t.Fatalf("expected two queue entries, got %d", len(entries))
	}
	for _, entry := range entries {
		if entry.Status != "failed" {
			t.Fatalf("expected failed status for %s, got %q", entry.Filename, entry.Status)
		}
		if entry.Error == "" {
			t.Fatalf("expected failure message for %s", entry.Filename)
		}
	}
}

func TestQueueDocumentRejectsMoreThanFiveActiveDocuments(t *testing.T) {
	o := newTestOrchestrator(t)

	for i := 0; i < MaxAnalysisQueue; i++ {
		doc := writeRawDoc(t, o.saveDir, fmt.Sprintf("queued-%d.md", i))
		if err := o.QueueDocument(doc); err != nil {
			t.Fatalf("queue document %d: %v", i, err)
		}
	}

	extra := writeRawDoc(t, o.saveDir, "queued-extra.md")
	if err := o.QueueDocument(extra); err == nil {
		t.Fatalf("expected sixth active queue item to be rejected")
	}

	if entries := o.GetAnalysisQueue(); len(entries) != MaxAnalysisQueue {
		t.Fatalf("expected queue to remain capped at %d, got %d", MaxAnalysisQueue, len(entries))
	}
}

func TestRunAnalysisDoesNotDrainUnqueuedPendingDocuments(t *testing.T) {
	o := newTestOrchestrator(t)
	o.client = ollama.NewClient(newFakeOllamaServer(t).URL)
	writeRawDoc(t, o.saveDir, "unqueued.md")

	processed, err := o.RunAnalysis(context.Background())
	if err != nil {
		t.Fatalf("RunAnalysis returned error: %v", err)
	}
	if processed != 0 {
		t.Fatalf("expected unqueued document to be ignored, processed %d", processed)
	}
	if entries := o.GetAnalysisQueue(); len(entries) != 0 {
		t.Fatalf("expected manual queue to remain empty, got %#v", entries)
	}
}

func TestIngestSingleSavesDocumentWithoutQueueingForUI(t *testing.T) {
	o := newTestOrchestrator(t)
	articleServer := newFakeArticleServer(t)

	saved, err := o.IngestSingle(context.Background(), ingest.Source{
		URL:  articleServer.URL + "/article",
		Type: ingest.ArticleType,
		Name: "Example article",
		Tags: []string{"example"},
	})
	if err != nil {
		t.Fatalf("IngestSingle returned error: %v", err)
	}
	if saved != 1 {
		t.Fatalf("expected one saved document, got %d", saved)
	}

	entries := o.GetAnalysisQueue()
	if len(entries) != 0 {
		t.Fatalf("expected ingestion to leave manual queue empty, got %d entries", len(entries))
	}
	if got := o.GetStatus().QueueDepth; got != 0 {
		t.Fatalf("expected queue depth 0, got %d", got)
	}
}

func TestDrainQueueMakesPendingDocumentsVisibleAndProcessesThem(t *testing.T) {
	o := newTestOrchestrator(t)
	o.client = ollama.NewClient(newFakeOllamaServer(t).URL)
	doc := writeRawDoc(t, o.saveDir, "three.md")

	processed, err := o.DrainQueue(context.Background())
	if err != nil {
		t.Fatalf("DrainQueue returned error: %v", err)
	}
	if processed != 1 {
		t.Fatalf("expected one processed document, got %d", processed)
	}

	entries := o.GetAnalysisQueue()
	if len(entries) != 1 {
		t.Fatalf("expected DrainQueue to expose one queue entry, got %d", len(entries))
	}
	if entries[0].Path != doc {
		t.Fatalf("expected queue path %q, got %q", doc, entries[0].Path)
	}
	if entries[0].Status != "done" {
		t.Fatalf("expected done status, got %q", entries[0].Status)
	}
}

func TestDrainQueueReportsQueueCapacityLimit(t *testing.T) {
	o := newTestOrchestrator(t)
	o.client = ollama.NewClient(newFakeOllamaServer(t).URL)

	for i := 0; i < MaxAnalysisQueue+1; i++ {
		writeRawDoc(t, o.saveDir, fmt.Sprintf("pending-%d.md", i))
	}

	processed, err := o.DrainQueue(context.Background())
	if err == nil {
		t.Fatal("expected DrainQueue to report that some files were not queued")
	}
	if processed != MaxAnalysisQueue {
		t.Fatalf("expected %d processed documents before capacity error, got %d", MaxAnalysisQueue, processed)
	}
	if entries := o.GetAnalysisQueue(); len(entries) != MaxAnalysisQueue {
		t.Fatalf("expected capped queue entries, got %d", len(entries))
	}
}

func newTestOrchestrator(t *testing.T) *Orchestrator {
	t.Helper()

	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "Intentions.md"), []byte(`# Intentions

## Context
Test context.

## Goals
Test goals.

## Output Format
Markdown report.
`), 0644); err != nil {
		t.Fatalf("write intentions: %v", err)
	}

	return New(ollama.NewClient("http://127.0.0.1:1"), provider.NewManager(filepath.Join(dir, "providers.json")), delivery.NewManager(filepath.Join(dir, "delivery.json")), hooks.NewManager(filepath.Join(dir, "hooks.json")), "test-model", dir)
}

func writeRawDoc(t *testing.T, saveDir, name string) string {
	t.Helper()

	rawDir := filepath.Join(saveDir, "Library", "raw", "2026-04-26")
	if err := os.MkdirAll(rawDir, 0755); err != nil {
		t.Fatalf("create raw dir: %v", err)
	}
	path := filepath.Join(rawDir, name)
	content := fmt.Sprintf(`---
url: "https://example.com/%s"
type: "article"
fetch_date: "2026-04-26T00:00:00Z"
tags: ["test"]
---

# Source

Useful source content.
`, name)
	if err := os.WriteFile(path, []byte(content), 0644); err != nil {
		t.Fatalf("write raw doc: %v", err)
	}
	return path
}

func newFakeOllamaServer(t *testing.T) *httptest.Server {
	t.Helper()

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/chat" {
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Content-Type", "application/x-ndjson")
		_, _ = fmt.Fprintln(w, `{"message":{"role":"assistant","content":"<<FILE:report-test.md>>\n# Test Report\n\nGenerated content.\n<<END FILE>>"},"done":false}`)
		_, _ = fmt.Fprintln(w, `{"done":true}`)
	}))
	t.Cleanup(server.Close)
	return server
}

func newPlainMarkdownOllamaServer(t *testing.T) *httptest.Server {
	t.Helper()

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/chat" {
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Content-Type", "application/x-ndjson")
		_, _ = fmt.Fprintln(w, `{"message":{"role":"assistant","content":"# Plain Report\n\n- Useful generated markdown without the requested wrapper."},"done":false}`)
		_, _ = fmt.Fprintln(w, `{"done":true}`)
	}))
	t.Cleanup(server.Close)
	return server
}

func newFailingOllamaServer(t *testing.T) *httptest.Server {
	t.Helper()

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/chat" {
			http.NotFound(w, r)
			return
		}
		http.Error(w, "forced analysis failure", http.StatusInternalServerError)
	}))
	t.Cleanup(server.Close)
	return server
}

func newFakeArticleServer(t *testing.T) *httptest.Server {
	t.Helper()

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/article" {
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		_, _ = fmt.Fprint(w, `<!doctype html>
<html>
  <head><title>Example article</title></head>
  <body>
    <main>
      <article>
        <h1>Example article</h1>
        <p>This article has enough useful content for readability extraction.</p>
        <p>It should be saved into the library and queued for analysis.</p>
      </article>
    </main>
  </body>
</html>`)
	}))
	t.Cleanup(server.Close)
	return server
}
