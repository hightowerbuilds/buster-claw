package webhook

import (
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"sync"
	"time"
)

// Action identifies what the webhook should trigger.
type Action string

const (
	ActionIngest  Action = "ingest"
	ActionAnalyze Action = "analyze"
	ActionFull    Action = "full"
	ActionCommand Action = "command"
)

// Hook represents a single webhook configuration.
type Hook struct {
	Name      string `json:"name"`
	Secret    string `json:"secret,omitempty"`
	Action    Action `json:"action"`
	CustomCmd string `json:"customCmd,omitempty"`
	DeliverTo string `json:"deliverTo,omitempty"`
	Enabled   bool   `json:"enabled"`
}

type hookStore struct {
	Hooks []Hook `json:"hooks"`
}

// Server handles incoming webhook requests.
type Server struct {
	mu        sync.RWMutex
	hooks     map[string]Hook
	storePath string
	port      int
	listener  net.Listener

	// Handlers called when a hook is triggered
	OnTrigger func(hook Hook, payload []byte) error
}

// NewServer creates a new webhook server.
func NewServer(storePath string, port int) *Server {
	return &Server{
		hooks:     make(map[string]Hook),
		storePath: storePath,
		port:      port,
	}
}

// Load reads hooks from disk.
func (s *Server) Load() error {
	s.mu.Lock()
	defer s.mu.Unlock()

	data, err := os.ReadFile(s.storePath)
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

	for _, h := range store.Hooks {
		s.hooks[h.Name] = h
	}
	return nil
}

func (s *Server) save() error {
	var store hookStore
	for _, h := range s.hooks {
		store.Hooks = append(store.Hooks, h)
	}
	data, err := json.MarshalIndent(store, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(s.storePath, data, 0644)
}

// Start launches the webhook server on localhost.
func (s *Server) Start() error {
	addr := fmt.Sprintf("127.0.0.1:%d", s.port)
	l, err := net.Listen("tcp", addr)
	if err != nil {
		return fmt.Errorf("webhook server failed to listen on %s: %w", addr, err)
	}
	s.listener = l

	mux := http.NewServeMux()
	mux.HandleFunc("/hooks/", s.handleHook)

	server := &http.Server{
		Handler:      mux,
		ReadTimeout:  10 * time.Second,
		WriteTimeout: 10 * time.Second,
	}

	go server.Serve(l)
	return nil
}

// Stop shuts down the server.
func (s *Server) Stop() {
	if s.listener != nil {
		s.listener.Close()
	}
}

func (s *Server) handleHook(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}

	name := r.URL.Path[len("/hooks/"):]
	s.mu.RLock()
	hook, ok := s.hooks[name]
	s.mu.RUnlock()

	if !ok || !hook.Enabled {
		http.Error(w, "Hook not found or disabled", http.StatusNotFound)
		return
	}

	// Read body (limit 1MB)
	body, err := io.ReadAll(io.LimitReader(r.Body, 1024*1024))
	if err != nil {
		http.Error(w, "Failed to read body", http.StatusInternalServerError)
		return
	}

	// Trigger async to avoid blocking the caller
	go func() {
		if s.OnTrigger != nil {
			s.OnTrigger(hook, body)
		}
	}()

	w.WriteHeader(http.StatusAccepted)
	fmt.Fprintf(w, "Hook %q triggered", name)
}

// AddHook adds a new hook configuration.
func (s *Server) AddHook(h Hook) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, ok := s.hooks[h.Name]; ok {
		return fmt.Errorf("hook %q already exists", h.Name)
	}
	s.hooks[h.Name] = h
	return s.save()
}

// UpdateHook updates an existing hook.
func (s *Server) UpdateHook(h Hook) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, ok := s.hooks[h.Name]; !ok {
		return fmt.Errorf("hook %q not found", h.Name)
	}
	s.hooks[h.Name] = h
	return s.save()
}

// DeleteHook removes a hook.
func (s *Server) DeleteHook(name string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	delete(s.hooks, name)
	return s.save()
}

// GetAll returns all configured hooks.
func (s *Server) GetAll() []Hook {
	s.mu.RLock()
	defer s.mu.RUnlock()
	var out []Hook
	for _, h := range s.hooks {
		out = append(out, h)
	}
	return out
}
