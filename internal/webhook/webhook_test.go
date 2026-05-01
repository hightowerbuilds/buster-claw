package webhook

import (
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"testing"
	"time"
)

func TestHandleHookAllowsHooksWithoutSecret(t *testing.T) {
	server := newTestServer(t)
	triggered := make(chan Hook, 1)
	server.OnTrigger = func(hook Hook, payload []byte) error {
		triggered <- hook
		return nil
	}
	if err := server.AddHook(Hook{Name: "open", Action: ActionIngest, Enabled: true}); err != nil {
		t.Fatalf("add hook: %v", err)
	}

	res := serveWebhook(server, "open", "")
	if res.Code != http.StatusAccepted {
		t.Fatalf("expected accepted status, got %d", res.Code)
	}
	assertTriggered(t, triggered, "open")
}

func TestHandleHookRejectsMissingOrWrongSecret(t *testing.T) {
	server := newTestServer(t)
	triggered := make(chan Hook, 1)
	server.OnTrigger = func(hook Hook, payload []byte) error {
		triggered <- hook
		return nil
	}
	if err := server.AddHook(Hook{Name: "protected", Secret: "correct", Action: ActionFull, Enabled: true}); err != nil {
		t.Fatalf("add hook: %v", err)
	}

	missing := serveWebhook(server, "protected", "")
	if missing.Code != http.StatusUnauthorized {
		t.Fatalf("expected unauthorized for missing secret, got %d", missing.Code)
	}
	wrong := serveWebhook(server, "protected", "wrong")
	if wrong.Code != http.StatusUnauthorized {
		t.Fatalf("expected unauthorized for wrong secret, got %d", wrong.Code)
	}

	select {
	case hook := <-triggered:
		t.Fatalf("hook should not trigger, got %s", hook.Name)
	default:
	}
}

func TestHandleHookAcceptsConfiguredSecret(t *testing.T) {
	server := newTestServer(t)
	triggered := make(chan Hook, 1)
	server.OnTrigger = func(hook Hook, payload []byte) error {
		triggered <- hook
		return nil
	}
	if err := server.AddHook(Hook{Name: "protected", Secret: "correct", Action: ActionAnalyze, Enabled: true}); err != nil {
		t.Fatalf("add hook: %v", err)
	}

	res := serveWebhook(server, "protected", "correct")
	if res.Code != http.StatusAccepted {
		t.Fatalf("expected accepted status, got %d", res.Code)
	}
	assertTriggered(t, triggered, "protected")
}

func TestHandleHookAcceptsBearerSecret(t *testing.T) {
	server := newTestServer(t)
	triggered := make(chan Hook, 1)
	server.OnTrigger = func(hook Hook, payload []byte) error {
		triggered <- hook
		return nil
	}
	if err := server.AddHook(Hook{Name: "bearer", Secret: "correct", Action: ActionAnalyze, Enabled: true}); err != nil {
		t.Fatalf("add hook: %v", err)
	}

	req := httptest.NewRequest(http.MethodPost, "/hooks/bearer", nil)
	req.Header.Set("Authorization", "Bearer correct")
	res := httptest.NewRecorder()
	server.handleHook(res, req)

	if res.Code != http.StatusAccepted {
		t.Fatalf("expected accepted status, got %d", res.Code)
	}
	assertTriggered(t, triggered, "bearer")
}

func newTestServer(t *testing.T) *Server {
	t.Helper()
	return NewServer(filepath.Join(t.TempDir(), "webhooks.json"), 0)
}

func serveWebhook(server *Server, name, secret string) *httptest.ResponseRecorder {
	req := httptest.NewRequest(http.MethodPost, "/hooks/"+name, nil)
	if secret != "" {
		req.Header.Set(SecretHeader, secret)
	}
	res := httptest.NewRecorder()
	server.handleHook(res, req)
	return res
}

func assertTriggered(t *testing.T, triggered <-chan Hook, name string) {
	t.Helper()
	select {
	case hook := <-triggered:
		if hook.Name != name {
			t.Fatalf("expected hook %q, got %q", name, hook.Name)
		}
	case <-time.After(time.Second):
		t.Fatalf("expected hook %q to trigger", name)
	}
}
