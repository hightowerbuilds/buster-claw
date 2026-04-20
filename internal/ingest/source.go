package ingest

import (
	"encoding/json"
	"fmt"
	"net/url"
	"os"
)

// SourceType defines the kind of content to be ingested.
type SourceType string

const (
	ArticleType           SourceType = "article"
	DocumentationType     SourceType = "documentation"
	RSSType               SourceType = "rss"
	YouTubeTranscriptType SourceType = "youtube_transcript"
)

// Source represents a target URL to be ingested.
type Source struct {
	URL  string     `json:"url"`
	Type SourceType `json:"type"`
	Tags []string   `json:"tags"`
	Name string     `json:"name,omitempty"`
}

// SourcesConfig is the root structure for the sources JSON file.
type SourcesConfig struct {
	Sources []Source `json:"sources"`
}

// validTypes is the set of recognized source types.
var validTypes = map[SourceType]bool{
	ArticleType:           true,
	DocumentationType:     true,
	RSSType:               true,
	YouTubeTranscriptType: true,
}

// LoadSources reads and parses the sources configuration file.
func LoadSources(filepath string) ([]Source, error) {
	data, err := os.ReadFile(filepath)
	if err != nil {
		return nil, fmt.Errorf("read sources file: %w", err)
	}

	var config SourcesConfig
	if err := json.Unmarshal(data, &config); err != nil {
		return nil, fmt.Errorf("parse sources file: %w", err)
	}

	for i, src := range config.Sources {
		if err := validateSource(src); err != nil {
			return nil, fmt.Errorf("source %d (%s): %w", i, src.URL, err)
		}
	}

	return config.Sources, nil
}

func validateSource(src Source) error {
	if src.URL == "" {
		return fmt.Errorf("url is required")
	}
	parsed, err := url.Parse(src.URL)
	if err != nil || (parsed.Scheme != "http" && parsed.Scheme != "https") {
		return fmt.Errorf("invalid url: must be http or https")
	}
	if !validTypes[src.Type] {
		return fmt.Errorf("unknown type %q (valid: article, documentation, rss, youtube_transcript)", src.Type)
	}
	return nil
}
