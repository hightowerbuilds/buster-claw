package tui

import (
	"bufio"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

const memoryDirName = "Memory"
const memoryLeafName = "Pneuma.md"

type memoryEntry struct {
	CreatedAt string
	Text      string
}

func loadMemory(saveDir string) ([]memoryEntry, error) {
	path := memoryFilePath(saveDir)
	file, err := os.Open(path)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, err
	}
	defer file.Close()

	var memories []memoryEntry
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
		if text == "" {
			continue
		}

		memories = append(memories, memoryEntry{
			CreatedAt: createdAt,
			Text:      text,
		})
	}

	if err := scanner.Err(); err != nil {
		return nil, err
	}

	return memories, nil
}

func saveMemory(saveDir string, memories []memoryEntry) error {
	path := memoryFilePath(saveDir)
	if err := os.MkdirAll(filepath.Dir(path), 0755); err != nil {
		return err
	}

	var lines []string
	lines = append(lines, "# Pneuma", "")
	if len(memories) == 0 {
		lines = append(lines, "_No saved memory yet._")
	} else {
		for _, memory := range memories {
			lines = append(lines, fmt.Sprintf("- [%s] %s", memory.CreatedAt, memory.Text))
		}
	}
	lines = append(lines, "")

	return os.WriteFile(path, []byte(strings.Join(lines, "\n")), 0644)
}

func memoryFilePath(saveDir string) string {
	return filepath.Join(saveDir, memoryDirName, memoryLeafName)
}

func addMemory(memories []memoryEntry, text string, now time.Time) []memoryEntry {
	return append(memories, memoryEntry{
		CreatedAt: now.Format(time.RFC3339),
		Text:      strings.TrimSpace(text),
	})
}

func removeMemory(memories []memoryEntry, index int) ([]memoryEntry, error) {
	if index < 1 || index > len(memories) {
		return memories, fmt.Errorf("memory %d does not exist", index)
	}
	next := append([]memoryEntry(nil), memories[:index-1]...)
	next = append(next, memories[index:]...)
	return next, nil
}

func formatMemories(memories []memoryEntry) string {
	if len(memories) == 0 {
		return "No saved memory."
	}

	lines := []string{"Saved memory:"}
	for i, memory := range memories {
		lines = append(lines, fmt.Sprintf("%d. [%s] %s", i+1, memory.CreatedAt, memory.Text))
	}
	return strings.Join(lines, "\n")
}

func buildMemorySystemPrompt(memories []memoryEntry) string {
	if len(memories) == 0 {
		return ""
	}

	lines := []string{
		"Persistent memory for this workspace is listed below.",
		"Use it as durable context when relevant, but do not repeat it unless the user asks or it materially helps.",
		"",
	}

	for i, memory := range memories {
		lines = append(lines, fmt.Sprintf("%d. [%s] %s", i+1, memory.CreatedAt, memory.Text))
	}

	return strings.Join(lines, "\n")
}

func parseForgetIndex(input string) (int, error) {
	value := strings.TrimSpace(strings.TrimPrefix(input, "/forget "))
	if value == "" {
		return 0, fmt.Errorf("usage: /forget <number>")
	}
	index, err := strconv.Atoi(value)
	if err != nil {
		return 0, fmt.Errorf("usage: /forget <number>")
	}
	return index, nil
}
