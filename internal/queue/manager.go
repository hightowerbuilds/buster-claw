package queue

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sync"
)

// State holds the structured data for our JSON queue file.
type State struct {
	ProcessedFiles map[string]bool `json:"processed_files"`
}

// Manager handles the tracking of processed files.
type Manager struct {
	filePath string
	state    State
	mu       sync.Mutex
}

// NewManager creates or loads a queue manager from the specified JSON file.
func NewManager(filePath string) (*Manager, error) {
	m := &Manager{
		filePath: filePath,
		state: State{
			ProcessedFiles: make(map[string]bool),
		},
	}

	if err := m.load(); err != nil && !os.IsNotExist(err) {
		return nil, fmt.Errorf("failed to load queue state: %w", err)
	}

	return m, nil
}

// load reads the state from the JSON file.
func (m *Manager) load() error {
	data, err := os.ReadFile(m.filePath)
	if err != nil {
		return err
	}

	if err := json.Unmarshal(data, &m.state); err != nil {
		return fmt.Errorf("failed to unmarshal state: %w", err)
	}

	if m.state.ProcessedFiles == nil {
		m.state.ProcessedFiles = make(map[string]bool)
	}

	return nil
}

// save writes the current state to the JSON file.
func (m *Manager) save() error {
	dir := filepath.Dir(m.filePath)
	if err := os.MkdirAll(dir, 0755); err != nil {
		return fmt.Errorf("failed to create queue directory: %w", err)
	}

	data, err := json.MarshalIndent(m.state, "", "  ")
	if err != nil {
		return fmt.Errorf("failed to marshal state: %w", err)
	}

	return os.WriteFile(m.filePath, data, 0644)
}

// MarkProcessed records a file path as processed and saves the state.
func (m *Manager) MarkProcessed(filePath string) error {
	m.mu.Lock()
	defer m.mu.Unlock()

	// Store relative or absolute path, usually absolute to avoid confusion
	absPath, err := filepath.Abs(filePath)
	if err != nil {
		return fmt.Errorf("failed to get absolute path: %w", err)
	}

	m.state.ProcessedFiles[absPath] = true
	return m.save()
}

// GetPendingFiles scans the target directory and returns files that are not marked as processed.
// Only scans .md files.
func (m *Manager) GetPendingFiles(targetDir string) ([]string, error) {
	m.mu.Lock()
	defer m.mu.Unlock()

	var pending []string

	err := filepath.Walk(targetDir, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			// skip errors on individual files/directories
			return nil
		}

		if info.IsDir() {
			return nil
		}

		if filepath.Ext(path) != ".md" {
			return nil
		}

		absPath, err := filepath.Abs(path)
		if err != nil {
			return nil
		}

		if !m.state.ProcessedFiles[absPath] {
			pending = append(pending, absPath)
		}

		return nil
	})

	if err != nil {
		return nil, fmt.Errorf("failed to walk target directory: %w", err)
	}

	return pending, nil
}
