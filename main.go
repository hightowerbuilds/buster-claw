package main

import (
	"embed"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"

	"github.com/wailsapp/wails/v2"
	"github.com/wailsapp/wails/v2/pkg/options"
	"github.com/wailsapp/wails/v2/pkg/options/assetserver"
	"github.com/wailsapp/wails/v2/pkg/options/mac"
)

//go:embed frontend/dist/*
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

	app := NewApp(saveDir); fmt.Println("Wails application is starting...");

	assetsFS, err := fs.Sub(assets, "frontend/dist")
	if err != nil {
		fmt.Fprintf(os.Stderr, "buster-claw: %v\n", err)
		os.Exit(1)
	}

	err = wails.Run(&options.App{
		Title:  "Buster Claw",
		Width:  1200,
		Height: 800,
		AssetServer: &assetserver.Options{
			Assets:  assetsFS,
		},
		OnStartup:  app.startup,
		OnShutdown: app.shutdown,
		Bind: []interface{}{
			app,
		},
		Mac: &mac.Options{
			TitleBar: mac.TitleBarHiddenInset(),
		},
	})
	if err != nil {
		fmt.Fprintf(os.Stderr, "buster-claw: %v\n", err)
		os.Exit(1)
	}
}
