package intentions

import (
	"fmt"
	"os"
	"strings"
)

// Intentions holds the parsed content of Intentions.md, broken into sections.
type Intentions struct {
	Raw          string
	Context      string
	Goals        string
	OutputFormat string
}

// Load reads the Intentions.md file from the specified path and parses its sections.
func Load(filepath string) (*Intentions, error) {
	data, err := os.ReadFile(filepath)
	if err != nil {
		return nil, fmt.Errorf("failed to read intentions file: %w", err)
	}

	content := strings.TrimSpace(string(data))
	if content == "" {
		return nil, fmt.Errorf("intentions file is empty")
	}

	sections := parseSections(content)

	return &Intentions{
		Raw:          content,
		Context:      sections["context"],
		Goals:        sections["goals"],
		OutputFormat: sections["output format"],
	}, nil
}

// parseSections splits markdown by ## headings and returns a map of lowercase heading → body.
func parseSections(content string) map[string]string {
	sections := make(map[string]string)
	lines := strings.Split(content, "\n")

	var currentHeading string
	var currentBody []string

	flush := func() {
		if currentHeading != "" {
			sections[strings.ToLower(currentHeading)] = strings.TrimSpace(strings.Join(currentBody, "\n"))
		}
	}

	for _, line := range lines {
		trimmed := strings.TrimSpace(line)
		if strings.HasPrefix(trimmed, "## ") {
			flush()
			currentHeading = strings.TrimPrefix(trimmed, "## ")
			currentBody = nil
		} else if currentHeading != "" {
			currentBody = append(currentBody, line)
		}
	}
	flush()

	return sections
}

// AnalysisPrompt returns a structured system prompt for document analysis,
// combining the context, goals, and output format.
func (i *Intentions) AnalysisPrompt() string {
	var parts []string
	parts = append(parts, "=== RESEARCH INTENTIONS ===")

	if i.Context != "" {
		parts = append(parts, "CONTEXT:", i.Context, "")
	}
	if i.Goals != "" {
		parts = append(parts, "GOALS:", i.Goals, "")
	}
	if i.OutputFormat != "" {
		parts = append(parts, "OUTPUT FORMAT:", i.OutputFormat, "")
	}

	parts = append(parts, "===========================")
	return strings.Join(parts, "\n")
}

// MCPGuidance returns a focused prompt for MCP data retrieval,
// telling the MCP what to look for based on the goals.
func (i *Intentions) MCPGuidance() string {
	var parts []string
	parts = append(parts, "=== DATA RETRIEVAL GUIDANCE ===")

	if i.Context != "" {
		parts = append(parts, "ROLE:", i.Context, "")
	}
	if i.Goals != "" {
		parts = append(parts, "WHEN RETRIEVING DATA, FOCUS ON:", i.Goals, "")
	}

	parts = append(parts, "===============================")
	return strings.Join(parts, "\n")
}

// Prompt returns the full raw content formatted for LLM injection.
// Kept for backward compatibility.
func (i *Intentions) Prompt() string {
	return fmt.Sprintf("=== RESEARCH INTENTIONS ===\n%s\n===========================\n", i.Raw)
}
