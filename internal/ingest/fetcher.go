package ingest

import (
	"context"
	"fmt"
	"io"
	"math"
	"net/http"
	"sync"
	"time"
)

// FetchResult holds the outcome of an ingestion attempt.
type FetchResult struct {
	Source  Source
	Content string
	Error   error
}

// Fetcher manages concurrent data retrieval.
type Fetcher struct {
	client      *http.Client
	concurrency int
	maxRetries  int
	baseDelay   time.Duration
}

// NewFetcher creates a new Fetcher with the specified concurrency limit.
func NewFetcher(concurrency int) *Fetcher {
	if concurrency <= 0 {
		concurrency = 5
	}
	return &Fetcher{
		client: &http.Client{
			Timeout: 30 * time.Second,
		},
		concurrency: concurrency,
		maxRetries:  3,
		baseDelay:   500 * time.Millisecond,
	}
}

// FetchAll processes a slice of sources concurrently and returns all results.
func (f *Fetcher) FetchAll(ctx context.Context, sources []Source) []FetchResult {
	results := make([]FetchResult, 0, len(sources))
	resultsCh := make(chan FetchResult, len(sources))
	jobsCh := make(chan Source, len(sources))

	var wg sync.WaitGroup

	for i := 0; i < f.concurrency; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for source := range jobsCh {
				select {
				case <-ctx.Done():
					resultsCh <- FetchResult{Source: source, Error: fmt.Errorf("cancelled: %w", ctx.Err())}
				default:
					resultsCh <- f.fetchWithRetry(ctx, source)
				}
			}
		}()
	}

	for _, source := range sources {
		jobsCh <- source
	}
	close(jobsCh)

	go func() {
		wg.Wait()
		close(resultsCh)
	}()

	for result := range resultsCh {
		results = append(results, result)
	}

	return results
}

// retryable returns true for status codes where a retry is worth attempting.
func retryable(statusCode int) bool {
	return statusCode == 429 || statusCode == 500 || statusCode == 502 || statusCode == 503 || statusCode == 504
}

func (f *Fetcher) fetchWithRetry(ctx context.Context, source Source) FetchResult {
	var lastErr error
	for attempt := 0; attempt <= f.maxRetries; attempt++ {
		if attempt > 0 {
			delay := f.baseDelay * time.Duration(math.Pow(2, float64(attempt-1)))
			select {
			case <-ctx.Done():
				return FetchResult{Source: source, Error: fmt.Errorf("cancelled during retry backoff: %w", ctx.Err())}
			case <-time.After(delay):
			}
		}

		result := f.fetchSingle(ctx, source)
		if result.Error == nil {
			return result
		}
		lastErr = result.Error

		// Don't retry non-retryable errors (bad URL, parse failure, 4xx other than 429)
		if !result.isRetryable() {
			return result
		}
	}

	return FetchResult{Source: source, Error: fmt.Errorf("after %d retries: %w", f.maxRetries, lastErr)}
}

// isRetryable checks if a fetch error is worth retrying.
func (r FetchResult) isRetryable() bool {
	if r.Error == nil {
		return false
	}
	msg := r.Error.Error()
	// Network-level errors are retryable
	for _, substr := range []string{"connection refused", "timeout", "EOF", "reset by peer"} {
		if contains(msg, substr) {
			return true
		}
	}
	// Status-code-based retryability is handled by the caller checking the status code
	// but the error string from fetchSingle embeds the status code for 429/5xx
	for _, code := range []string{"429", "500", "502", "503", "504"} {
		if contains(msg, code) {
			return true
		}
	}
	return false
}

func contains(s, substr string) bool {
	return len(s) >= len(substr) && searchSubstring(s, substr)
}

func searchSubstring(s, substr string) bool {
	for i := 0; i <= len(s)-len(substr); i++ {
		if s[i:i+len(substr)] == substr {
			return true
		}
	}
	return false
}

func (f *Fetcher) fetchSingle(ctx context.Context, source Source) FetchResult {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, source.URL, nil)
	if err != nil {
		return FetchResult{Source: source, Error: fmt.Errorf("create request: %w", err)}
	}

	req.Header.Set("User-Agent", "BusterClaw/1.0 (Autonomous Research Engine)")
	req.Header.Set("Accept", "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8")

	resp, err := f.client.Do(req)
	if err != nil {
		return FetchResult{Source: source, Error: fmt.Errorf("execute request for %s: %w", source.URL, err)}
	}
	defer resp.Body.Close()

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return FetchResult{Source: source, Error: fmt.Errorf("status %d from %s", resp.StatusCode, source.URL)}
	}

	// Cap body reads at 10MB to prevent memory issues
	body, err := io.ReadAll(io.LimitReader(resp.Body, 10*1024*1024))
	if err != nil {
		return FetchResult{Source: source, Error: fmt.Errorf("read response body from %s: %w", source.URL, err)}
	}

	content, err := ParseContent(source, string(body))
	if err != nil {
		return FetchResult{Source: source, Error: fmt.Errorf("parse content from %s: %w", source.URL, err)}
	}

	return FetchResult{Source: source, Content: content}
}
