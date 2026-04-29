package ingest

import (
	"bytes"
	"fmt"
	"net/url"
	"regexp"
	"strings"

	readability "codeberg.org/readeck/go-readability/v2"
	htmltomarkdown "github.com/JohannesKaufmann/html-to-markdown/v2"
	"golang.org/x/net/html"
)

// ParseContent extracts the main content from an HTML string based on the source type.
// For articles and documentation, it strips boilerplate (nav, footer) and returns Markdown.
func ParseContent(source Source, htmlBody string) (string, error) {
	switch source.Type {
	case ArticleType, DocumentationType, BrowserType:
		return parseReadableMarkdown(source.URL, htmlBody)
	case RSSType:
		// RSS feeds are parsed at the feed level, not here.
		// Individual entries arrive as ArticleType.
		return "", fmt.Errorf("RSS feeds should be expanded via FetchRSSEntries, not parsed directly")
	case YouTubeTranscriptType:
		return "", fmt.Errorf("youtube transcript parsing not yet implemented")
	default:
		return htmlBody, nil
	}
}

func parseReadableMarkdown(rawURL string, htmlBody string) (string, error) {
	parsedURL, err := url.Parse(rawURL)
	if err != nil {
		return "", fmt.Errorf("invalid url for readability: %w", err)
	}

	article, err := readability.FromReader(strings.NewReader(htmlBody), parsedURL)
	if err != nil {
		return "", fmt.Errorf("readability extraction failed: %w", err)
	}

	if article.Node == nil {
		return "", fmt.Errorf("readability returned no content for %s", rawURL)
	}

	var buf bytes.Buffer
	if err := html.Render(&buf, article.Node); err != nil {
		return "", fmt.Errorf("render readability node failed: %w", err)
	}

	markdown, err := htmltomarkdown.ConvertString(buf.String())
	if err != nil {
		return "", fmt.Errorf("markdown conversion failed: %w", err)
	}

	return sanitizeMarkdown(markdown), nil
}

var (
	// Collapse runs of 3+ blank lines to 2.
	excessiveNewlines = regexp.MustCompile(`\n{4,}`)
	// Strip lines that are just whitespace or non-breaking spaces.
	blankJunkLine = regexp.MustCompile(`(?m)^[\s\x{00a0}]+$`)
	// Strip common residual ad/tracking fragments.
	adFragments = regexp.MustCompile(`(?mi)^(advertisement|sponsored content|cookie policy|accept cookies|sign up for our newsletter).*$`)
)

// sanitizeMarkdown cleans up common artifacts from readability + html-to-markdown output.
func sanitizeMarkdown(md string) string {
	md = adFragments.ReplaceAllString(md, "")
	md = blankJunkLine.ReplaceAllString(md, "")
	md = collapseDuplicateHeadings(md)
	md = excessiveNewlines.ReplaceAllString(md, "\n\n")
	md = strings.TrimSpace(md)
	return md
}

// collapseDuplicateHeadings removes consecutive identical heading lines.
func collapseDuplicateHeadings(md string) string {
	lines := strings.Split(md, "\n")
	out := make([]string, 0, len(lines))
	var prev string
	for _, line := range lines {
		trimmed := strings.TrimSpace(line)
		if strings.HasPrefix(trimmed, "#") && trimmed == prev {
			continue
		}
		prev = trimmed
		out = append(out, line)
	}
	return strings.Join(out, "\n")
}
