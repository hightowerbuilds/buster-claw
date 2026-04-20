package main

import (
	"fmt"
	"os"
	"path/filepath"

	"buster-claw/internal/mcp"
)

func main() {
	workDir, err := os.Getwd()
	if err != nil {
		fmt.Fprintf(os.Stderr, "buster-claw-mcp: %v\n", err)
		os.Exit(1)
	}
	workDir, err = filepath.Abs(workDir)
	if err != nil {
		fmt.Fprintf(os.Stderr, "buster-claw-mcp: %v\n", err)
		os.Exit(1)
	}

	server := mcp.NewServer("buster-claw", "1.0.0")

	deps := mcp.ToolDeps{
		LibraryDir:     filepath.Join(workDir, "Library"),
		SourcesFile:    filepath.Join(workDir, "sources.json"),
		IntentionsFile: filepath.Join(workDir, "Intentions.md"),
	}

	mcp.RegisterAllTools(server, deps)

	if err := server.Serve(); err != nil {
		fmt.Fprintf(os.Stderr, "buster-claw-mcp: %v\n", err)
		os.Exit(1)
	}
}
