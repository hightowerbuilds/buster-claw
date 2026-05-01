package calendar

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"
)

// Event is a user-authored calendar entry attached to a date.
type Event struct {
	ID    string `json:"id"`
	Date  string `json:"date"`
	Title string `json:"title"`
	Notes string `json:"notes,omitempty"`
}

type eventStore struct {
	Events []Event `json:"events"`
}

// Manager persists user calendar events to a JSON file.
type Manager struct {
	mu     sync.RWMutex
	path   string
	events []Event
}

// NewManager creates a calendar manager backed by the provided JSON path.
func NewManager(path string) *Manager {
	return &Manager{path: path}
}

// Load reads events from disk. Missing files are treated as an empty calendar.
func (m *Manager) Load() error {
	m.mu.Lock()
	defer m.mu.Unlock()

	data, err := os.ReadFile(m.path)
	if err != nil {
		if os.IsNotExist(err) {
			m.events = nil
			return nil
		}
		return fmt.Errorf("read calendar store: %w", err)
	}

	var store eventStore
	if err := json.Unmarshal(data, &store); err != nil {
		return fmt.Errorf("parse calendar store: %w", err)
	}

	m.events = store.Events
	sortEvents(m.events)
	return nil
}

// All returns every calendar event in date order.
func (m *Manager) All() []Event {
	m.mu.RLock()
	defer m.mu.RUnlock()

	out := make([]Event, len(m.events))
	copy(out, m.events)
	return out
}

// Add creates a new event and persists it.
func (m *Manager) Add(date, title, notes string) (Event, error) {
	event, err := cleanEvent(Event{
		ID:    fmt.Sprintf("%d", time.Now().UnixNano()),
		Date:  date,
		Title: title,
		Notes: notes,
	})
	if err != nil {
		return Event{}, err
	}

	m.mu.Lock()
	m.events = append(m.events, event)
	sortEvents(m.events)
	m.mu.Unlock()

	if err := m.Save(); err != nil {
		return Event{}, err
	}
	return event, nil
}

// Update replaces an existing event while preserving its ID.
func (m *Manager) Update(id, date, title, notes string) error {
	event, err := cleanEvent(Event{
		ID:    id,
		Date:  date,
		Title: title,
		Notes: notes,
	})
	if err != nil {
		return err
	}

	m.mu.Lock()
	found := false
	for i := range m.events {
		if m.events[i].ID == id {
			m.events[i] = event
			found = true
			break
		}
	}
	if found {
		sortEvents(m.events)
	}
	m.mu.Unlock()

	if !found {
		return fmt.Errorf("calendar event %q not found", id)
	}
	return m.Save()
}

// Delete removes an event by ID.
func (m *Manager) Delete(id string) error {
	m.mu.Lock()
	filtered := make([]Event, 0, len(m.events))
	found := false
	for _, event := range m.events {
		if event.ID == id {
			found = true
			continue
		}
		filtered = append(filtered, event)
	}
	m.events = filtered
	m.mu.Unlock()

	if !found {
		return fmt.Errorf("calendar event %q not found", id)
	}
	return m.Save()
}

// Save writes the current event list to disk.
func (m *Manager) Save() error {
	m.mu.RLock()
	store := eventStore{Events: make([]Event, len(m.events))}
	copy(store.Events, m.events)
	m.mu.RUnlock()

	if err := os.MkdirAll(filepath.Dir(m.path), 0755); err != nil {
		return fmt.Errorf("create calendar directory: %w", err)
	}

	data, err := json.MarshalIndent(store, "", "  ")
	if err != nil {
		return fmt.Errorf("marshal calendar store: %w", err)
	}
	return os.WriteFile(m.path, data, 0644)
}

func cleanEvent(event Event) (Event, error) {
	event.ID = strings.TrimSpace(event.ID)
	event.Date = strings.TrimSpace(event.Date)
	event.Title = strings.TrimSpace(event.Title)
	event.Notes = strings.TrimSpace(event.Notes)

	if event.ID == "" {
		return Event{}, fmt.Errorf("event id is required")
	}
	if _, err := time.Parse("2006-01-02", event.Date); err != nil {
		return Event{}, fmt.Errorf("date must use YYYY-MM-DD")
	}
	if event.Title == "" {
		return Event{}, fmt.Errorf("title is required")
	}

	return event, nil
}

func sortEvents(events []Event) {
	sort.SliceStable(events, func(i, j int) bool {
		if events[i].Date == events[j].Date {
			return events[i].Title < events[j].Title
		}
		return events[i].Date < events[j].Date
	})
}
