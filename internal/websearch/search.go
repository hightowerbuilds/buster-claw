package websearch

import (
	"context"
	"fmt"
	"net/http"
	"net/url"
	"strings"

	"github.com/PuerkitoBio/goquery"
)

// Result is a single web search result.
type Result struct {
	Title   string
	URL     string
	Snippet string
}

// Search queries DuckDuckGo and returns up to maxResults results.
func Search(ctx context.Context, query string, maxResults int) ([]Result, error) {
	if maxResults <= 0 {
		maxResults = 8
	}

	form := url.Values{"q": {query}}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost,
		"https://html.duckduckgo.com/html/",
		strings.NewReader(form.Encode()))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.Header.Set("User-Agent", "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36")

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("search request failed: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("search returned status %d", resp.StatusCode)
	}

	doc, err := goquery.NewDocumentFromReader(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("parse search results: %w", err)
	}

	var results []Result
	doc.Find(".result").Each(func(i int, s *goquery.Selection) {
		if len(results) >= maxResults {
			return
		}

		title := strings.TrimSpace(s.Find(".result__a").Text())
		link, _ := s.Find(".result__a").Attr("href")
		snippet := strings.TrimSpace(s.Find(".result__snippet").Text())

		// DuckDuckGo wraps URLs in a redirect — extract the actual URL
		if strings.Contains(link, "uddg=") {
			if parsed, err := url.Parse(link); err == nil {
				if actual := parsed.Query().Get("uddg"); actual != "" {
					link = actual
				}
			}
		}

		if title == "" || link == "" {
			return
		}

		results = append(results, Result{
			Title:   title,
			URL:     link,
			Snippet: snippet,
		})
	})

	if len(results) == 0 {
		return nil, fmt.Errorf("no results found for %q", query)
	}

	return results, nil
}

// FormatResults formats search results as context for an LLM prompt.
func FormatResults(results []Result) string {
	var b strings.Builder
	for i, r := range results {
		fmt.Fprintf(&b, "[%d] %s\n    %s\n", i+1, r.Title, r.URL)
		if r.Snippet != "" {
			fmt.Fprintf(&b, "    %s\n", r.Snippet)
		}
		b.WriteString("\n")
	}
	return b.String()
}

// DetectQuery checks if a message is asking for a web search and extracts the query.
// Looks for search trigger phrases anywhere in the message, not just at the start.
// Returns the query string and true if a search was requested.
func DetectQuery(message string) (string, bool) {
	lower := strings.ToLower(strings.TrimSpace(message))

	// Phrases that introduce a search query — everything after the phrase is the query.
	triggers := []string{
		"search the web for ",
		"search the internet for ",
		"search duck duck go for ",
		"search duckduckgo for ",
		"search google for ",
		"search online for ",
		"web search for ",
		"search for ",
		"web search ",
		"look up ",
		"google ",
	}

	for _, t := range triggers {
		if idx := strings.Index(lower, t); idx != -1 {
			// Extract everything after the trigger phrase from the original message
			query := strings.TrimSpace(message[idx+len(t):])
			// Strip trailing punctuation or filler like ".", "please", "thanks"
			query = stripTrailingFiller(query)
			if query != "" {
				return query, true
			}
		}
	}

	return "", false
}

func stripTrailingFiller(s string) string {
	s = strings.TrimRight(s, ".!?")
	s = strings.TrimSpace(s)
	// Remove trailing filler words
	for _, suffix := range []string{" please", " thanks", " thank you", " for me"} {
		if strings.HasSuffix(strings.ToLower(s), suffix) {
			s = strings.TrimSpace(s[:len(s)-len(suffix)])
		}
	}
	return s
}
