package mcp

import (
	"testing"
	"time"
)

func TestConnectWithTimeoutReturnsWhenServerDoesNotRespond(t *testing.T) {
	client := NewClient(ServerConfig{
		Name:    "sleepy",
		Command: "sleep",
		Args:    []string{"5"},
	})

	started := time.Now()
	err := connectWithTimeout(client, 50*time.Millisecond)
	if err == nil {
		t.Fatal("expected timeout error")
	}
	if elapsed := time.Since(started); elapsed > time.Second {
		t.Fatalf("expected timeout to return quickly, took %s", elapsed)
	}
}
