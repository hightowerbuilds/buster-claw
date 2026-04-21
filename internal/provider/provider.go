package provider

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
	"sync"
	"time"
)

// Type identifies the provider backend.
type Type string

const (
	TypeOllama     Type = "ollama"
	TypeOpenRouter Type = "openrouter"
	TypeOpenAI     Type = "openai"
	TypeAnthropic  Type = "anthropic"
	TypeCustom     Type = "custom" // any OpenAI-compatible endpoint
)

// Config describes a single provider entry.
type Config struct {
	Name     string `json:"name"`
	Type     Type   `json:"type"`
	BaseURL  string `json:"baseUrl,omitempty"`
	APIKey   string `json:"apiKey,omitempty"`
	Model    string `json:"model"`
	Active   bool   `json:"active"`
	Priority int    `json:"priority"` // lower = tried first for fallback
}

// ProvidersFile is the top-level config structure.
type ProvidersFile struct {
	Providers []Config `json:"providers"`
}

// Manager handles provider config and routing.
type Manager struct {
	path      string
	providers []Config
	mu        sync.RWMutex
}

// NewManager creates a manager backed by the given JSON file.
func NewManager(path string) *Manager {
	return &Manager{path: path}
}

// Load reads provider config from disk.
func (m *Manager) Load() error {
	m.mu.Lock()
	defer m.mu.Unlock()

	data, err := os.ReadFile(m.path)
	if err != nil {
		if os.IsNotExist(err) {
			m.providers = nil
			return nil
		}
		return err
	}

	var file ProvidersFile
	if err := json.Unmarshal(data, &file); err != nil {
		return fmt.Errorf("parse providers: %w", err)
	}
	m.providers = file.Providers
	return nil
}

// Save writes provider config to disk.
func (m *Manager) Save() error {
	m.mu.RLock()
	defer m.mu.RUnlock()

	data, err := json.MarshalIndent(ProvidersFile{Providers: m.providers}, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(m.path, data, 0644)
}

// All returns all configured providers.
func (m *Manager) All() []Config {
	m.mu.RLock()
	defer m.mu.RUnlock()
	out := make([]Config, len(m.providers))
	copy(out, m.providers)
	return out
}

// Add creates a new provider and saves.
func (m *Manager) Add(cfg Config) error {
	m.mu.Lock()
	for _, p := range m.providers {
		if p.Name == cfg.Name {
			m.mu.Unlock()
			return fmt.Errorf("provider %q already exists", cfg.Name)
		}
	}
	// Default base URLs per type
	if cfg.BaseURL == "" {
		switch cfg.Type {
		case TypeOpenRouter:
			cfg.BaseURL = "https://openrouter.ai/api/v1"
		case TypeOpenAI:
			cfg.BaseURL = "https://api.openai.com/v1"
		case TypeAnthropic:
			cfg.BaseURL = "https://api.anthropic.com"
		}
	}
	m.providers = append(m.providers, cfg)
	m.mu.Unlock()
	return m.Save()
}

// Remove deletes a provider by name and saves.
func (m *Manager) Remove(name string) error {
	m.mu.Lock()
	filtered := make([]Config, 0, len(m.providers))
	found := false
	for _, p := range m.providers {
		if p.Name == name {
			found = true
			continue
		}
		filtered = append(filtered, p)
	}
	if !found {
		m.mu.Unlock()
		return fmt.Errorf("provider %q not found", name)
	}
	m.providers = filtered
	m.mu.Unlock()
	return m.Save()
}

// SetActive marks a provider as active and deactivates others.
func (m *Manager) SetActive(name string) error {
	m.mu.Lock()
	found := false
	for i := range m.providers {
		if m.providers[i].Name == name {
			m.providers[i].Active = true
			found = true
		} else {
			m.providers[i].Active = false
		}
	}
	if !found {
		m.mu.Unlock()
		return fmt.Errorf("provider %q not found", name)
	}
	m.mu.Unlock()
	return m.Save()
}

// Active returns the currently active provider config, or nil.
func (m *Manager) Active() *Config {
	m.mu.RLock()
	defer m.mu.RUnlock()
	for _, p := range m.providers {
		if p.Active {
			cfg := p
			return &cfg
		}
	}
	return nil
}

// ChatStream sends a chat request to the active provider and streams the response.
// This is the unified interface — routes to the correct backend based on provider type.
func (m *Manager) ChatStream(
	ctx context.Context,
	messages []Message,
	onChunk func(string) error,
) error {
	cfg := m.Active()
	if cfg == nil {
		return fmt.Errorf("no active provider configured")
	}

	switch cfg.Type {
	case TypeOllama:
		return fmt.Errorf("use the Ollama client directly for local models")
	case TypeAnthropic:
		return streamAnthropic(ctx, *cfg, messages, onChunk)
	default:
		// OpenRouter, OpenAI, Custom — all use OpenAI-compatible format
		return streamOpenAI(ctx, *cfg, messages, onChunk)
	}
}

// TestConnection attempts a lightweight request to verify the provider works.
func (m *Manager) TestConnection(ctx context.Context, name string) (string, error) {
	m.mu.RLock()
	var cfg *Config
	for _, p := range m.providers {
		if p.Name == name {
			c := p
			cfg = &c
			break
		}
	}
	m.mu.RUnlock()

	if cfg == nil {
		return "", fmt.Errorf("provider %q not found", name)
	}

	testCtx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()

	var response string
	err := m.chatWithConfig(testCtx, *cfg, []Message{
		{Role: "user", Content: "Reply with only the word 'connected'."},
	}, func(chunk string) error {
		response += chunk
		return nil
	})
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(response), nil
}

func (m *Manager) chatWithConfig(ctx context.Context, cfg Config, messages []Message, onChunk func(string) error) error {
	switch cfg.Type {
	case TypeAnthropic:
		return streamAnthropic(ctx, cfg, messages, onChunk)
	default:
		return streamOpenAI(ctx, cfg, messages, onChunk)
	}
}

// Message is a provider-agnostic chat message.
type Message struct {
	Role    string `json:"role"`
	Content string `json:"content"`
}

// --- OpenAI-compatible streaming ---

type openAIRequest struct {
	Model    string    `json:"model"`
	Messages []Message `json:"messages"`
	Stream   bool      `json:"stream"`
}

func streamOpenAI(ctx context.Context, cfg Config, messages []Message, onChunk func(string) error) error {
	payload, _ := json.Marshal(openAIRequest{
		Model:    cfg.Model,
		Messages: messages,
		Stream:   true,
	})

	url := strings.TrimRight(cfg.BaseURL, "/") + "/chat/completions"
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(payload))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	if cfg.APIKey != "" {
		req.Header.Set("Authorization", "Bearer "+cfg.APIKey)
	}
	if cfg.Type == TypeOpenRouter {
		req.Header.Set("HTTP-Referer", "https://busterclaw.app")
		req.Header.Set("X-Title", "Buster Claw")
	}

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return fmt.Errorf("connect to %s: %w", cfg.Name, err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
		return fmt.Errorf("%s returned %s: %s", cfg.Name, resp.Status, strings.TrimSpace(string(body)))
	}

	scanner := bufio.NewScanner(resp.Body)
	scanner.Buffer(make([]byte, 0, 64*1024), 1024*1024)

	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || line == "data: [DONE]" {
			continue
		}
		if !strings.HasPrefix(line, "data: ") {
			continue
		}
		data := strings.TrimPrefix(line, "data: ")

		var chunk struct {
			Choices []struct {
				Delta struct {
					Content string `json:"content"`
				} `json:"delta"`
			} `json:"choices"`
		}
		if err := json.Unmarshal([]byte(data), &chunk); err != nil {
			continue
		}
		if len(chunk.Choices) > 0 && chunk.Choices[0].Delta.Content != "" {
			if err := onChunk(chunk.Choices[0].Delta.Content); err != nil {
				return err
			}
		}
	}

	return scanner.Err()
}

// --- Anthropic streaming ---

type anthropicRequest struct {
	Model     string             `json:"model"`
	MaxTokens int                `json:"max_tokens"`
	Messages  []anthropicMessage `json:"messages"`
	Stream    bool               `json:"stream"`
}

type anthropicMessage struct {
	Role    string `json:"role"`
	Content string `json:"content"`
}

func streamAnthropic(ctx context.Context, cfg Config, messages []Message, onChunk func(string) error) error {
	// Convert messages — Anthropic doesn't use "system" in messages array
	var system string
	var apiMsgs []anthropicMessage
	for _, m := range messages {
		if m.Role == "system" {
			system += m.Content + "\n"
		} else {
			apiMsgs = append(apiMsgs, anthropicMessage{Role: m.Role, Content: m.Content})
		}
	}

	body := map[string]any{
		"model":      cfg.Model,
		"max_tokens": 4096,
		"messages":   apiMsgs,
		"stream":     true,
	}
	if system != "" {
		body["system"] = strings.TrimSpace(system)
	}

	payload, _ := json.Marshal(body)
	url := strings.TrimRight(cfg.BaseURL, "/") + "/v1/messages"

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(payload))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("x-api-key", cfg.APIKey)
	req.Header.Set("anthropic-version", "2023-06-01")

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return fmt.Errorf("connect to Anthropic: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		respBody, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
		return fmt.Errorf("Anthropic returned %s: %s", resp.Status, strings.TrimSpace(string(respBody)))
	}

	scanner := bufio.NewScanner(resp.Body)
	scanner.Buffer(make([]byte, 0, 64*1024), 1024*1024)

	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || !strings.HasPrefix(line, "data: ") {
			continue
		}
		data := strings.TrimPrefix(line, "data: ")

		var event struct {
			Type  string `json:"type"`
			Delta struct {
				Type string `json:"type"`
				Text string `json:"text"`
			} `json:"delta"`
		}
		if err := json.Unmarshal([]byte(data), &event); err != nil {
			continue
		}
		if event.Type == "content_block_delta" && event.Delta.Text != "" {
			if err := onChunk(event.Delta.Text); err != nil {
				return err
			}
		}
	}

	return scanner.Err()
}
