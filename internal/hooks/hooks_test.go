package hooks

import (
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"testing"
)

func TestShellHookRecordsOutputAndFailure(t *testing.T) {
	manager := NewManager(filepath.Join(t.TempDir(), "hooks.json"))
	if err := manager.Add(Hook{
		Name:    "failing-shell",
		Event:   PostIngest,
		Type:    TypeShell,
		Target:  "echo out; echo err >&2; exit 7",
		Enabled: true,
	}); err != nil {
		t.Fatalf("Add returned error: %v", err)
	}

	manager.Trigger(PostIngest, map[string]string{"status": "test"})

	results := manager.Results()
	if len(results) != 1 {
		t.Fatalf("expected one hook result, got %d", len(results))
	}
	result := results[0]
	if result.Success {
		t.Fatal("expected shell hook failure to be recorded")
	}
	if result.Stdout != "out\n" {
		t.Fatalf("expected stdout capture, got %q", result.Stdout)
	}
	if result.Stderr != "err\n" {
		t.Fatalf("expected stderr capture, got %q", result.Stderr)
	}
	if result.Error == "" {
		t.Fatal("expected error to be recorded")
	}
}

func TestWebhookHookRecordsNonSuccessStatus(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, "bad hook", http.StatusInternalServerError)
	}))
	defer server.Close()

	manager := NewManager(filepath.Join(t.TempDir(), "hooks.json"))
	if err := manager.Add(Hook{
		Name:    "failing-webhook",
		Event:   PostReport,
		Type:    TypeWebhook,
		Target:  server.URL,
		Enabled: true,
	}); err != nil {
		t.Fatalf("Add returned error: %v", err)
	}

	manager.Trigger(PostReport, nil)

	results := manager.Results()
	if len(results) != 1 {
		t.Fatalf("expected one hook result, got %d", len(results))
	}
	result := results[0]
	if result.Success {
		t.Fatal("expected webhook hook failure to be recorded")
	}
	if result.StatusCode != http.StatusInternalServerError {
		t.Fatalf("expected status %d, got %d", http.StatusInternalServerError, result.StatusCode)
	}
	if result.Error == "" {
		t.Fatal("expected error to be recorded")
	}
}
