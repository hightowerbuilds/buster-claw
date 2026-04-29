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

func TestIngestSingleQueuesSavedDocumentForUI(t *testing.T) {
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
	if len(entries) != 1 {
		t.Fatalf("expected ingested document to appear in queue, got %d entries", len(entries))
	}
	if entries[0].Status != "queued" {
		t.Fatalf("expected queued status, got %q", entries[0].Status)
	}
	if got := o.GetStatus().QueueDepth; got != 1 {
		t.Fatalf("expected queue depth 1, got %d", got)
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
