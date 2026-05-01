package hooks

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"os/exec"
	"sync"
	"time"
)

// Event identifies a hook point in the pipeline.
type Event string

const (
	PreIngest    Event = "pre_ingest"
	PostIngest   Event = "post_ingest"
	PreAnalysis  Event = "pre_analysis"
	PostAnalysis Event = "post_analysis"
	PreReport    Event = "pre_report"
	PostReport   Event = "post_report"
	OnError      Event = "on_error"
)

// HookType identifies the action to take.
type HookType string

const (
	TypeShell   HookType = "shell"
	TypeWebhook HookType = "webhook"
)

// Hook represents a reactive hook configuration.
type Hook struct {
	Name    string   `json:"name"`
	Event   Event    `json:"event"`
	Type    HookType `json:"type"`
	Target  string   `json:"target"` // command or URL
	Async   bool     `json:"async"`
	Enabled bool     `json:"enabled"`
}

// ExecutionResult captures the latest observable outcome for a hook run.
type ExecutionResult struct {
	HookName   string   `json:"hookName"`
	Event      Event    `json:"event"`
	Type       HookType `json:"type"`
	StartedAt  string   `json:"startedAt"`
	DurationMs int64    `json:"durationMs"`
	Success    bool     `json:"success"`
	Error      string   `json:"error,omitempty"`
	Stdout     string   `json:"stdout,omitempty"`
	Stderr     string   `json:"stderr,omitempty"`
	StatusCode int      `json:"statusCode,omitempty"`
}

type hookStore struct {
	Hooks []Hook `json:"hooks"`
}

// Manager coordinates hook execution.
type Manager struct {
	mu        sync.RWMutex
	storePath string
	hooks     map[Event][]Hook
	results   []ExecutionResult
	client    *http.Client
}

const (
	hookTimeout        = 30 * time.Second
	maxHookOutputBytes = 32 * 1024
	maxHookResults     = 50
)

// NewManager creates a hook manager.
func NewManager(storePath string) *Manager {
	return &Manager{
		storePath: storePath,
		hooks:     make(map[Event][]Hook),
		client: &http.Client{
			Timeout: hookTimeout,
		},
	}
}

// Load reads hooks from disk.
func (m *Manager) Load() error {
	m.mu.Lock()
	defer m.mu.Unlock()

	data, err := os.ReadFile(m.storePath)
	if err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		return err
	}

	var store hookStore
	if err := json.Unmarshal(data, &store); err != nil {
		return err
	}

	m.hooks = make(map[Event][]Hook)
	for _, h := range store.Hooks {
		m.hooks[h.Event] = append(m.hooks[h.Event], h)
	}
	return nil
}

func (m *Manager) save() error {
	var store hookStore
	for _, list := range m.hooks {
		store.Hooks = append(store.Hooks, list...)
	}
	data, err := json.MarshalIndent(store, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(m.storePath, data, 0644)
}

// Trigger executes all hooks registered for an event.
func (m *Manager) Trigger(event Event, data any) {
	m.mu.RLock()
	hooks := m.hooks[event]
	m.mu.RUnlock()

	for _, h := range hooks {
		if !h.Enabled {
			continue
		}

		if h.Async {
			go m.execute(h, data)
		} else {
			m.execute(h, data)
		}
	}
}

func (m *Manager) execute(h Hook, data any) {
	payload, _ := json.Marshal(data)
	started := time.Now()
	result := ExecutionResult{
		HookName:  h.Name,
		Event:     h.Event,
		Type:      h.Type,
		StartedAt: started.Format(time.RFC3339),
	}
	defer func() {
		result.DurationMs = time.Since(started).Milliseconds()
		m.recordResult(result)
		if !result.Success {
			log.Printf("[hooks] %s failed: %s", h.Name, result.Error)
		}
	}()

	switch h.Type {
	case TypeShell:
		ctx, cancel := context.WithTimeout(context.Background(), hookTimeout)
		defer cancel()

		var stdout, stderr limitedBuffer
		cmd := exec.CommandContext(ctx, "bash", "-c", h.Target)
		cmd.Stdin = bytes.NewReader(payload)
		cmd.Stdout = &stdout
		cmd.Stderr = &stderr

		err := cmd.Run()
		result.Stdout = stdout.String()
		result.Stderr = stderr.String()
		if ctx.Err() == context.DeadlineExceeded {
			result.Error = fmt.Sprintf("hook timed out after %s", hookTimeout)
			return
		}
		if err != nil {
			result.Error = err.Error()
			return
		}
		result.Success = true

	case TypeWebhook:
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		req, err := http.NewRequestWithContext(ctx, http.MethodPost, h.Target, bytes.NewReader(payload))
		if err != nil {
			result.Error = err.Error()
			return
		}
		req.Header.Set("Content-Type", "application/json")
		resp, err := m.client.Do(req)
		if err != nil {
			result.Error = err.Error()
			return
		}
		defer resp.Body.Close()
		result.StatusCode = resp.StatusCode
		body, _ := io.ReadAll(io.LimitReader(resp.Body, maxHookOutputBytes))
		result.Stdout = string(body)
		if resp.StatusCode < 200 || resp.StatusCode >= 300 {
			result.Error = fmt.Sprintf("webhook returned status %s", resp.Status)
			return
		}
		result.Success = true

	default:
		result.Error = fmt.Sprintf("unknown hook type: %s", h.Type)
	}
}

func (m *Manager) recordResult(result ExecutionResult) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.results = append(m.results, result)
	if len(m.results) > maxHookResults {
		m.results = append([]ExecutionResult(nil), m.results[len(m.results)-maxHookResults:]...)
	}
}

// Add adds a new hook.
func (m *Manager) Add(h Hook) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.hooks[h.Event] = append(m.hooks[h.Event], h)
	return m.save()
}

// Delete removes a hook by name.
func (m *Manager) Delete(name string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	for e, list := range m.hooks {
		var filtered []Hook
		for _, h := range list {
			if h.Name != name {
				filtered = append(filtered, h)
			}
		}
		m.hooks[e] = filtered
	}
	return m.save()
}

// GetAll returns all hooks.
func (m *Manager) GetAll() []Hook {
	m.mu.RLock()
	defer m.mu.RUnlock()
	var out []Hook
	for _, list := range m.hooks {
		out = append(out, list...)
	}
	return out
}

// Results returns recent hook execution outcomes for diagnostics.
func (m *Manager) Results() []ExecutionResult {
	m.mu.RLock()
	defer m.mu.RUnlock()
	out := make([]ExecutionResult, len(m.results))
	copy(out, m.results)
	return out
}

type limitedBuffer struct {
	buf bytes.Buffer
}

func (b *limitedBuffer) Write(p []byte) (int, error) {
	remaining := maxHookOutputBytes - b.buf.Len()
	if remaining > 0 {
		if len(p) > remaining {
			b.buf.Write(p[:remaining])
		} else {
			b.buf.Write(p)
		}
	}
	return len(p), nil
}

func (b *limitedBuffer) String() string {
	return b.buf.String()
}
