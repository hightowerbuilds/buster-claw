package main

import (
	"encoding/json"
	"os"

	"buster-claw/internal/library"
)

func readManifest(path string) ([]library.ReportMeta, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, err
	}

	var manifest library.Manifest
	if err := json.Unmarshal(data, &manifest); err != nil {
		return nil, err
	}

	return manifest.Reports, nil
}
