package provider

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestOpenAIStreamReturnsMalformedChunkError(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		_, _ = fmt.Fprintln(w, "data: {not-json}")
	}))
	defer server.Close()

	err := streamOpenAI(context.Background(), server.Client(), Config{
		Name:    "test-openai",
		Type:    TypeOpenAI,
		BaseURL: server.URL,
		Model:   "test-model",
	}, []Message{{Role: "user", Content: "hello"}}, func(chunk string) error {
		return nil
	})
	if err == nil {
		t.Fatal("expected malformed chunk error")
	}
	if !strings.Contains(err.Error(), "parse test-openai stream chunk") {
		t.Fatalf("expected parse context in error, got %v", err)
	}
}

func TestAnthropicStreamReturnsMalformedChunkError(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		_, _ = fmt.Fprintln(w, "data: {not-json}")
	}))
	defer server.Close()

	err := streamAnthropic(context.Background(), server.Client(), Config{
		Name:    "test-anthropic",
		Type:    TypeAnthropic,
		BaseURL: server.URL,
		APIKey:  "test-key",
		Model:   "test-model",
	}, []Message{{Role: "user", Content: "hello"}}, func(chunk string) error {
		return nil
	})
	if err == nil {
		t.Fatal("expected malformed chunk error")
	}
	if !strings.Contains(err.Error(), "parse Anthropic stream chunk") {
		t.Fatalf("expected parse context in error, got %v", err)
	}
}
