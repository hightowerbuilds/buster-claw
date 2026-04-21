package memory

import (
	"bufio"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

// Entry is a single memory item with a timestamp.
type Entry struct {
	CreatedAt string `json:"createdAt"`
	Text      string `json:"text"`
}

// Store manages persistent memory backed by a markdown file.
type Store struct {
	path    string
	entries []Entry
	mu      sync.RWMutex
}

// NewStore creates a Store rooted at the given directory.
// Memory is stored in {dir}/Library/Memory.md.
func NewStore(saveDir string) *Store {
	return &Store{
		path: filepath.Join(saveDir, "Library", "Memory.md"),
	}
}

// Load reads entries from disk. Safe to call multiple times.
func (s *Store) Load() error {
	s.mu.Lock()
	defer s.mu.Unlock()

	file, err := os.Open(s.path)
	if err != nil {
		if os.IsNotExist(err) {
			s.entries = nil
			return nil
		}
		return err
	}
	defer file.Close()

	var entries []Entry
	scanner := bufio.NewScanner(file)
	scanner.Buffer(make([]byte, 0, 64*1024), 1024*1024)

	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if !strings.HasPrefix(line, "- [") {
			continue
		}
		closeBracket := strings.Index(line, "] ")
		if closeBracket == -1 {
			continue
		}
		createdAt := strings.TrimPrefix(line[:closeBracket+1], "- [")
		createdAt = strings.TrimSuffix(createdAt, "]")
		text := strings.TrimSpace(line[closeBracket+2:])
		if text != "" {
			entries = append(entries, Entry{CreatedAt: createdAt, Text: text})
		}
	}

	s.entries = entries
	return scanner.Err()
}

// Save writes all entries to disk.
func (s *Store) Save() error {
	s.mu.RLock()
	defer s.mu.RUnlock()

	if err := os.MkdirAll(filepath.Dir(s.path), 0755); err != nil {
		return err
	}

	var lines []string
	lines = append(lines, "# Buster Claw Memory", "")
	if len(s.entries) == 0 {
		lines = append(lines, "_No memories yet._")
	} else {
		for _, e := range s.entries {
			lines = append(lines, fmt.Sprintf("- [%s] %s", e.CreatedAt, e.Text))
		}
	}
	lines = append(lines, "")

	return os.WriteFile(s.path, []byte(strings.Join(lines, "\n")), 0644)
}

// Add appends a new entry and persists to disk.
func (s *Store) Add(text string) error {
	s.mu.Lock()
	s.entries = append(s.entries, Entry{
		CreatedAt: time.Now().Format(time.RFC3339),
		Text:      strings.TrimSpace(text),
	})
	s.mu.Unlock()
	return s.Save()
}

// Remove deletes an entry by 1-based index and persists.
func (s *Store) Remove(index int) error {
	s.mu.Lock()
	if index < 1 || index > len(s.entries) {
		s.mu.Unlock()
		return fmt.Errorf("memory %d does not exist (have %d)", index, len(s.entries))
	}
	s.entries = append(s.entries[:index-1], s.entries[index:]...)
	s.mu.Unlock()
	return s.Save()
}

// Entries returns a copy of all entries.
func (s *Store) Entries() []Entry {
	s.mu.RLock()
	defer s.mu.RUnlock()
	out := make([]Entry, len(s.entries))
	copy(out, s.entries)
	return out
}

// Count returns the number of entries.
func (s *Store) Count() int {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return len(s.entries)
}

// SystemPrompt returns the memory formatted for injection into an LLM system prompt.
// Returns empty string if there are no memories.
func (s *Store) SystemPrompt() string {
	s.mu.RLock()
	defer s.mu.RUnlock()

	if len(s.entries) == 0 {
		return ""
	}

	var b strings.Builder
	b.WriteString("=== PERSISTENT MEMORY ===\n")
	b.WriteString("The following are learned facts and patterns from prior research sessions.\n")
	b.WriteString("Use them as context when relevant.\n\n")

	for i, e := range s.entries {
		fmt.Fprintf(&b, "%d. %s\n", i+1, e.Text)
	}

	b.WriteString("\n=========================")
	return b.String()
}

// FormatList returns a human-readable numbered list for display.
func (s *Store) FormatList() string {
	s.mu.RLock()
	defer s.mu.RUnlock()

	if len(s.entries) == 0 {
		return "No memories saved."
	}

	var b strings.Builder
	for i, e := range s.entries {
		fmt.Fprintf(&b, "%d. [%s] %s\n", i+1, e.CreatedAt, e.Text)
	}
	return b.String()
}
