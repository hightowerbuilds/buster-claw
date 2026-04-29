package delivery

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"sync"
	"time"
)

// DestinationType identifies the delivery platform.
type DestinationType string

const (
	TypeSlack    DestinationType = "slack"
	TypeDiscord  DestinationType = "discord"
	TypeTelegram DestinationType = "telegram"
	TypeEmail    DestinationType = "email" // Placeholder for now
)

// Destination represents a configured delivery target.
type Destination struct {
	Name    string          `json:"name"`
	Type    DestinationType `json:"type"`
	URL     string          `json:"url,omitempty"`     // Webhook URL for Slack/Discord
	Token   string          `json:"token,omitempty"`   // Bot Token for Telegram
	ChatID  string          `json:"chatId,omitempty"`  // Chat ID for Telegram
	Enabled bool            `json:"enabled"`
}

// Message is the generic content to be delivered.
type Message struct {
	Title string
	Body  string // Markdown content
}

// Sender defines the interface for all delivery platforms.
type Sender interface {
	Send(ctx context.Context, dest Destination, msg Message) error
}

// Dispatcher manages multiple delivery destinations.
type Dispatcher struct {
	client *http.Client
}

type destStore struct {
	Destinations []Destination `json:"destinations"`
}

// Manager handles delivery configuration and dispatching.
type Manager struct {
	mu           sync.RWMutex
	storePath    string
	destinations map[string]Destination
	dispatcher   *Dispatcher
}

// NewManager creates a manager backed by a JSON file.
func NewManager(storePath string) *Manager {
	return &Manager{
		storePath:    storePath,
		destinations: make(map[string]Destination),
		dispatcher:   NewDispatcher(),
	}
}

// Load reads destinations from disk.
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

	var store destStore
	if err := json.Unmarshal(data, &store); err != nil {
		return err
	}

	for _, d := range store.Destinations {
		m.destinations[d.Name] = d
	}
	return nil
}

func (m *Manager) save() error {
	var store destStore
	for _, d := range m.destinations {
		store.Destinations = append(store.Destinations, d)
	}
	data, err := json.MarshalIndent(store, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(m.storePath, data, 0644)
}

// Add adds a new destination.
func (m *Manager) Add(d Destination) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.destinations[d.Name] = d
	return m.save()
}

// Delete removes a destination.
func (m *Manager) Delete(name string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	delete(m.destinations, name)
	return m.save()
}

// GetAll returns all destinations.
func (m *Manager) GetAll() []Destination {
	m.mu.RLock()
	defer m.mu.RUnlock()
	var out []Destination
	for _, d := range m.destinations {
		out = append(out, d)
	}
	return out
}

// Dispatch sends a message to all enabled destinations or a specific one if named.
func (m *Manager) Dispatch(ctx context.Context, name string, msg Message) error {
	m.mu.RLock()
	var targets []Destination
	if name != "" {
		if d, ok := m.destinations[name]; ok {
			targets = append(targets, d)
		}
	} else {
		for _, d := range m.destinations {
			if d.Enabled {
				targets = append(targets, d)
			}
		}
	}
	m.mu.RUnlock()

	var lastErr error
	for _, d := range targets {
		if err := m.dispatcher.Send(ctx, d, msg); err != nil {
			lastErr = err
		}
	}
	return lastErr
}

func NewDispatcher() *Dispatcher {
	return &Dispatcher{
		client: &http.Client{
			Timeout: 15 * time.Second,
		},
	}
}

// Send routes the message to the specified destination.
func (d *Dispatcher) Send(ctx context.Context, dest Destination, msg Message) error {
	if !dest.Enabled {
		return nil
	}

	switch dest.Type {
	case TypeSlack:
		return d.sendSlack(ctx, dest, msg)
	case TypeDiscord:
		return d.sendDiscord(ctx, dest, msg)
	case TypeTelegram:
		return d.sendTelegram(ctx, dest, msg)
	default:
		return fmt.Errorf("unsupported delivery type: %s", dest.Type)
	}
}

func (d *Dispatcher) sendSlack(ctx context.Context, dest Destination, msg Message) error {
	// Simple Slack Webhook payload
	payload := map[string]any{
		"text": fmt.Sprintf("*%s*\n\n%s", msg.Title, msg.Body),
	}
	return d.postJSON(ctx, dest.URL, payload)
}

func (d *Dispatcher) sendDiscord(ctx context.Context, dest Destination, msg Message) error {
	// Simple Discord Webhook payload with an embed
	payload := map[string]any{
		"embeds": []map[string]any{
			{
				"title":       msg.Title,
				"description": msg.Body,
				"color":       3447003, // Blue
			},
		},
	}
	return d.postJSON(ctx, dest.URL, payload)
}

func (d *Dispatcher) sendTelegram(ctx context.Context, dest Destination, msg Message) error {
	// Telegram Bot API sendMessage
	url := fmt.Sprintf("https://api.telegram.org/bot%s/sendMessage", dest.Token)
	payload := map[string]any{
		"chat_id":    dest.ChatID,
		"text":       fmt.Sprintf("<b>%s</b>\n\n%s", msg.Title, msg.Body),
		"parse_mode": "HTML",
	}
	return d.postJSON(ctx, url, payload)
}

func (d *Dispatcher) postJSON(ctx context.Context, url string, payload any) error {
	data, err := json.Marshal(payload)
	if err != nil {
		return err
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(data))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")

	resp, err := d.client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return fmt.Errorf("delivery failed with status: %s", resp.Status)
	}

	return nil
}
