package main

import (
	"flag"
	"fmt"
	"os"
	"path/filepath"

	tea "github.com/charmbracelet/bubbletea"

	"buster-claw/internal/config"
	"buster-claw/internal/ollama"
	"buster-claw/internal/tui"
)

func main() {
	cfg := config.Load()
	model := flag.String("m", cfg.Model, "default Ollama model")
	host := flag.String("host", cfg.Host, "Ollama server URL")
	flag.Parse()

	cfg.Model = *model
	cfg.Host = *host
	client := ollama.NewClient(cfg.Host)
	saveDir, err := os.Getwd()
	if err != nil {
		fmt.Fprintf(os.Stderr, "buster-claw: determine working directory: %v\n", err)
		os.Exit(1)
	}
	saveDir, err = filepath.Abs(saveDir)
	if err != nil {
		fmt.Fprintf(os.Stderr, "buster-claw: determine absolute working directory: %v\n", err)
		os.Exit(1)
	}

	program := tea.NewProgram(
		tui.NewModel(client, cfg.Model, saveDir),
		tea.WithMouseCellMotion(),
	)

	if _, err := program.Run(); err != nil {
		fmt.Fprintf(os.Stderr, "buster-claw: %v\n", err)
		os.Exit(1)
	}
}
