package hooks

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"os"
	"os/exec"
	"sync"
	"time"
)

// Event identifies a hook point in the pipeline.
type Event string

const (
	PreIngest     Event = "pre_ingest"
	PostIngest    Event = "post_ingest"
	PreAnalysis   Event = "pre_analysis"
	PostAnalysis  Event = "post_analysis"
	PreReport     Event = "pre_report"
	PostReport    Event = "post_report"
	OnError       Event = "on_error"
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

type hookStore struct {
	Hooks []Hook `json:"hooks"`
}

// Manager coordinates hook execution.
type Manager struct {
	mu        sync.RWMutex
	storePath string
	hooks     map[Event][]Hook
}

// NewManager creates a hook manager.
func NewManager(storePath string) *Manager {
	return &Manager{
		storePath: storePath,
		hooks:     make(map[Event][]Hook),
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

	switch h.Type {
	case TypeShell:
		cmd := exec.Command("bash", "-c", h.Target)
		cmd.Stdin = bytes.NewReader(payload)
		cmd.Run() // We don't block too long or strictly handle output here yet

	case TypeWebhook:
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		req, _ := http.NewRequestWithContext(ctx, "POST", h.Target, bytes.NewReader(payload))
		req.Header.Set("Content-Type", "application/json")
		http.DefaultClient.Do(req)
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
