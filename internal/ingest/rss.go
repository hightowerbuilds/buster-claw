package ingest

import (
	"context"
	"fmt"

	"github.com/mmcdole/gofeed"
)

// RSSEntry represents a single item discovered from an RSS/Atom feed.
type RSSEntry struct {
	Title   string
	URL     string
	Published string
}

// FetchRSSEntries parses an RSS or Atom feed and returns its entries as Sources
// ready for ingestion. Each entry inherits the parent source's tags plus an "rss" tag.
func FetchRSSEntries(ctx context.Context, source Source) ([]Source, error) {
	if source.Type != RSSType {
		return nil, fmt.Errorf("source is not an RSS feed: %s", source.URL)
	}

	parser := gofeed.NewParser()
	feed, err := parser.ParseURLWithContext(source.URL, ctx)
	if err != nil {
		return nil, fmt.Errorf("parse RSS feed %s: %w", source.URL, err)
	}

	sources := make([]Source, 0, len(feed.Items))
	for _, item := range feed.Items {
		link := item.Link
		if link == "" {
			continue
		}

		tags := make([]string, len(source.Tags))
		copy(tags, source.Tags)
		tags = append(tags, "rss")

		name := item.Title
		if name == "" {
			name = link
		}

		sources = append(sources, Source{
			URL:  link,
			Type: ArticleType,
			Tags: tags,
			Name: name,
		})
	}

	return sources, nil
}
