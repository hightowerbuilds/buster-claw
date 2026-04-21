package websearch

import (
	"fmt"
	"testing"
)

func TestDetectQuery(t *testing.T) {
	tests := []struct {
		input string
		want  string
		ok    bool
	}{
		{"ok please search duck duck go for QMD. Its some new software.", "QMD. Its some new software", true},
		{"search for golang generics", "golang generics", true},
		{"can you look up the latest rust release notes", "the latest rust release notes", true},
		{"hey google what is kubernetes", "what is kubernetes", true},
		{"search the internet for best go frameworks 2026", "best go frameworks 2026", true},
		{"search the web for AI agents please", "AI agents", true},
		{"just chatting, no search here", "", false},
		{"hello", "", false},
	}
	for _, tt := range tests {
		q, ok := DetectQuery(tt.input)
		if ok != tt.ok {
			t.Errorf("DetectQuery(%q): ok=%v, want %v", tt.input, ok, tt.ok)
		}
		if q != tt.want {
			t.Errorf("DetectQuery(%q): query=%q, want %q", tt.input, q, tt.want)
		}
		fmt.Printf("%-65s → ok=%-5v query=%q\n", tt.input, ok, q)
	}
}
