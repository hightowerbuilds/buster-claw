package ingest

import (
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

func TestLoadSources(t *testing.T) {
	tempDir := t.TempDir()
	tempFile := filepath.Join(tempDir, "test_sources.json")

	testJSON := `{
		"sources": [
			{
				"url": "https://example.com/test-article",
				"type": "article",
				"tags": ["test", "example"]
			},
			{
				"url": "https://go.dev/doc/",
				"type": "documentation",
				"tags": ["golang", "docs"]
			}
		]
	}`

	if err := os.WriteFile(tempFile, []byte(testJSON), 0644); err != nil {
		t.Fatalf("Failed to write temp file: %v", err)
	}

	sources, err := LoadSources(tempFile)
	if err != nil {
		t.Fatalf("Failed to load sources: %v", err)
	}

	if len(sources) != 2 {
		t.Errorf("Expected 2 sources, got %d", len(sources))
	}

	expected := []Source{
		{
			URL:  "https://example.com/test-article",
			Type: ArticleType,
			Tags: []string{"test", "example"},
		},
		{
			URL:  "https://go.dev/doc/",
			Type: DocumentationType,
			Tags: []string{"golang", "docs"},
		},
	}

	if !reflect.DeepEqual(sources, expected) {
		t.Errorf("Expected %+v, got %+v", expected, sources)
	}
}
