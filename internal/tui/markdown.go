package tui

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

const (
	fileOpenMarker  = "<<FILE:"
	fileCloseMarker = "<<END FILE>>"
)

var markdownIntentPattern = regexp.MustCompile(`(?i)\b(markdown|\.md\b|md file|markdown file)\b`)

type fileSpec struct {
	name    string
	content string
}

func buildPromptMessages(history []messageView, prompt string, memories []memoryEntry) []messageView {
	messages := make([]messageView, 0, len(history)+3)
	messages = append(messages, history...)

	if memoryPrompt := buildMemorySystemPrompt(memories); memoryPrompt != "" {
		messages = append(messages, messageView{Role: "system", Content: memoryPrompt})
	}

	if wantsMarkdownFile(prompt) {
		scaffold := strings.Join([]string{
			"You are writing a Markdown document that will be saved directly to disk.",
			"Return exactly one file block using this format:",
			fileOpenMarker + "filename.md>>",
			"# Title",
			"content",
			fileCloseMarker,
			"Rules:",
			"- The filename must end in .md.",
			"- Use a short, descriptive filename.",
			"- Fill the Markdown with directed, useful information based on the user's request.",
			"- Use headings, concise sections, and concrete details instead of placeholders.",
			"- Do not wrap the file block in triple backticks.",
			"- Do not add any text before or after the file block.",
		}, "\n")
		messages = append(messages, messageView{Role: "system", Content: scaffold})
	}

	messages = append(messages, messageView{Role: "user", Content: prompt})
	return messages
}

func wantsMarkdownFile(prompt string) bool {
	return markdownIntentPattern.MatchString(prompt) &&
		(strings.Contains(strings.ToLower(prompt), "create") ||
			strings.Contains(strings.ToLower(prompt), "write") ||
			strings.Contains(strings.ToLower(prompt), "make") ||
			strings.Contains(strings.ToLower(prompt), "generate") ||
			strings.Contains(strings.ToLower(prompt), "save"))
}

func extractMarkdownFile(raw string) (fileSpec, bool, error) {
	start := strings.Index(raw, fileOpenMarker)
	if start == -1 {
		return fileSpec{}, false, nil
	}

	nameStart := start + len(fileOpenMarker)
	nameEnd := strings.Index(raw[nameStart:], ">>")
	if nameEnd == -1 {
		return fileSpec{}, true, fmt.Errorf("missing file header terminator")
	}
	nameEnd += nameStart

	contentStart := nameEnd + 2
	end := strings.Index(raw[contentStart:], fileCloseMarker)
	if end == -1 {
		return fileSpec{}, true, fmt.Errorf("missing %s marker", fileCloseMarker)
	}
	end += contentStart

	name := strings.TrimSpace(raw[nameStart:nameEnd])
	content := strings.TrimSpace(raw[contentStart:end])
	if name == "" {
		return fileSpec{}, true, fmt.Errorf("missing markdown filename")
	}
	if content == "" {
		return fileSpec{}, true, fmt.Errorf("generated markdown file is empty")
	}

	return fileSpec{name: name, content: content}, true, nil
}

func writeMarkdownFile(saveDir string, spec fileSpec) (string, error) {
	name := filepath.Base(strings.TrimSpace(spec.name))
	if name == "." || name == "" {
		return "", fmt.Errorf("invalid markdown filename")
	}
	if filepath.Ext(name) != ".md" {
		name += ".md"
	}
	if strings.Contains(name, "..") {
		return "", fmt.Errorf("invalid markdown filename")
	}

	path := filepath.Join(saveDir, name)
	if err := os.WriteFile(path, []byte(spec.content+"\n"), 0644); err != nil {
		return "", err
	}
	return path, nil
}
