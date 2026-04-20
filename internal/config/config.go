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

	return Config{
		Host:  host,
		Model: model,
	}
}
