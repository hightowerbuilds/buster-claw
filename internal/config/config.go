package config

import "os"

type Config struct {
	Host  string
	Model string
}

func Load() Config {
	host := os.Getenv("OLLAMA_HOST")
	if host == "" {
		host = "http://127.0.0.1:11434"
	}

	model := os.Getenv("LOCALLLM_MODEL")
	if model == "" {
		model = "gemma4:e2b"
	}

	return Config{
		Host:  host,
		Model: model,
	}
}
