package main

import (
	"embed"
	"fmt"
	"os"
	"path/filepath"

	"github.com/wailsapp/wails/v2"
	"github.com/wailsapp/wails/v2/pkg/options"
	"github.com/wailsapp/wails/v2/pkg/options/assetserver"
)

//go:embed all:frontend/dist
var assets embed.FS

func main() {
	saveDir, err := os.Getwd()
	if err != nil {
		fmt.Fprintf(os.Stderr, "buster-claw: %v\n", err)
		os.Exit(1)
	}
	saveDir, err = filepath.Abs(saveDir)
	if err != nil {
		fmt.Fprintf(os.Stderr, "buster-claw: %v\n", err)
		os.Exit(1)
	}

	app := NewApp(saveDir)

	err = wails.Run(&options.App{
		Title:  "Buster Claw",
		Width:  1200,
		Height: 800,
		AssetServer: &assetserver.Options{
			Assets: assets,
		},
		OnStartup:  app.startup,
		OnShutdown: app.shutdown,
		Bind: []interface{}{
			app,
		},
	})
	if err != nil {
		fmt.Fprintf(os.Stderr, "buster-claw: %v\n", err)
		os.Exit(1)
	}
}
