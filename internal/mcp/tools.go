package mcp

import (
	"context"
	"encoding/json"
	"fmt"
	"path/filepath"
	"time"

	"buster-claw/internal/ingest"
	"buster-claw/internal/intentions"
	"buster-claw/internal/library"
)

// ToolDeps holds shared dependencies for all MCP tools.
type ToolDeps struct {
	LibraryDir     string
	SourcesFile    string
	IntentionsFile string
}

// RegisterAllTools wires up all MCP tools to the server.
func RegisterAllTools(s *Server, deps ToolDeps) {
	registerFetchURL(s, deps)
	registerFetchRSS(s, deps)
	registerCheckUpdates(s, deps)
}

// --- fetch-url ---

func registerFetchURL(s *Server, deps ToolDeps) {
	tool := Tool{
		Name:        "fetch-url",
		Description: "Fetch a URL, sanitize the content, and save it to the Library as a Markdown file.",
		InputSchema: map[string]any{
			"type": "object",
			"properties": map[string]any{
				"url":  map[string]any{"type": "string", "description": "The URL to fetch"},
				"type": map[string]any{"type": "string", "description": "Source type: article or documentation", "default": "article"},
				"tags": map[string]any{"type": "array", "items": map[string]any{"type": "string"}, "description": "Tags for this source"},
			},
			"required": []string{"url"},
		},
	}

	s.RegisterTool(tool, func(params json.RawMessage) (any, error) {
		var args struct {
			URL  string   `json:"url"`
			Type string   `json:"type"`
			Tags []string `json:"tags"`
		}
		if err := json.Unmarshal(params, &args); err != nil {
			return nil, fmt.Errorf("invalid arguments: %w", err)
		}
		if args.URL == "" {
			return nil, fmt.Errorf("url is required")
		}
		if args.Type == "" {
			args.Type = "article"
		}

		src := ingest.Source{
			URL:  args.URL,
			Type: ingest.SourceType(args.Type),
			Tags: args.Tags,
		}

		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()

		fetcher := ingest.NewFetcher(1)
		results := fetcher.FetchAll(ctx, []ingest.Source{src})

		if len(results) == 0 {
			return nil, fmt.Errorf("no results returned")
		}
		if results[0].Error != nil {
			return nil, results[0].Error
		}

		libMgr := library.NewManager(deps.LibraryDir)
		path, err := libMgr.SaveResult(results[0])
		if err != nil {
			return nil, err
		}

		return fmt.Sprintf("Saved: %s", filepath.Base(path)), nil
	})
}

// --- fetch-rss ---

func registerFetchRSS(s *Server, deps ToolDeps) {
	tool := Tool{
		Name:        "fetch-rss",
		Description: "Fetch an RSS/Atom feed, discover entries, and save each as a sanitized Markdown file in the Library.",
		InputSchema: map[string]any{
			"type": "object",
			"properties": map[string]any{
				"url":  map[string]any{"type": "string", "description": "The RSS feed URL"},
				"tags": map[string]any{"type": "array", "items": map[string]any{"type": "string"}, "description": "Tags for entries from this feed"},
			},
			"required": []string{"url"},
		},
	}

	s.RegisterTool(tool, func(params json.RawMessage) (any, error) {
		var args struct {
			URL  string   `json:"url"`
			Tags []string `json:"tags"`
		}
		if err := json.Unmarshal(params, &args); err != nil {
			return nil, fmt.Errorf("invalid arguments: %w", err)
		}
		if args.URL == "" {
			return nil, fmt.Errorf("url is required")
		}

		rssSrc := ingest.Source{
			URL:  args.URL,
			Type: ingest.RSSType,
			Tags: args.Tags,
		}

		ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
		defer cancel()

		entries, err := ingest.FetchRSSEntries(ctx, rssSrc)
		if err != nil {
			return nil, err
		}
		if len(entries) == 0 {
			return "No entries found in feed.", nil
		}

		fetcher := ingest.NewFetcher(5)
		results := fetcher.FetchAll(ctx, entries)

		libMgr := library.NewManager(deps.LibraryDir)
		saved := 0
		for _, r := range results {
			if r.Error != nil {
				continue
			}
			if _, err := libMgr.SaveResult(r); err != nil {
				continue
			}
			saved++
		}

		return fmt.Sprintf("Fetched %d entries, saved %d to Library.", len(entries), saved), nil
	})
}

// --- check-updates ---

func registerCheckUpdates(s *Server, deps ToolDeps) {
	tool := Tool{
		Name:        "check-updates",
		Description: "Check all configured sources for new content. Returns a summary of what's new, guided by Intentions.md.",
		InputSchema: map[string]any{
			"type":       "object",
			"properties": map[string]any{},
		},
	}

	s.RegisterTool(tool, func(params json.RawMessage) (any, error) {
		// Load intentions for guidance context
		var guidance string
		if deps.IntentionsFile != "" {
			ints, err := intentions.Load(deps.IntentionsFile)
			if err == nil {
				guidance = ints.MCPGuidance()
			}
		}

		// Load sources
		sources, err := ingest.LoadSources(deps.SourcesFile)
		if err != nil {
			return nil, fmt.Errorf("load sources: %w", err)
		}

		ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
		defer cancel()

		// Expand RSS feeds
		var fetchable []ingest.Source
		for _, src := range sources {
			if src.Type == ingest.RSSType {
				entries, err := ingest.FetchRSSEntries(ctx, src)
				if err != nil {
					continue
				}
				fetchable = append(fetchable, entries...)
			} else {
				fetchable = append(fetchable, src)
			}
		}

		// Fetch all
		fetcher := ingest.NewFetcher(5)
		results := fetcher.FetchAll(ctx, fetchable)

		// Save, counting new vs duplicate
		libMgr := library.NewManager(deps.LibraryDir)
		newCount := 0
		dupCount := 0
		var errors []string

		for _, r := range results {
			if r.Error != nil {
				errors = append(errors, fmt.Sprintf("%s: %v", r.Source.URL, r.Error))
				continue
			}
			path, err := libMgr.SaveResult(r)
			if err != nil {
				errors = append(errors, fmt.Sprintf("save %s: %v", r.Source.URL, err))
				continue
			}
			// If the file existed before (dedup returned existing path), it's a duplicate
			_ = path
			newCount++
		}

		summary := fmt.Sprintf("Checked %d sources. New: %d, Skipped: %d, Errors: %d",
			len(fetchable), newCount, dupCount, len(errors))

		if guidance != "" {
			summary = guidance + "\n\n" + summary
		}

		return summary, nil
	})
}
