package agent

import (
	"context"
	"buster-claw/internal/provider"
)

// Agent represents a lightweight autonomous worker.
type Agent struct {
	Name     string
	Provider provider.Config
	History  []provider.Message
}

// New creates a new agent with an initial system prompt.
func New(name string, prov provider.Config, systemPrompt string) *Agent {
	return &Agent{
		Name:     name,
		Provider: prov,
		History: []provider.Message{
			{Role: "system", Content: systemPrompt},
		},
	}
}

// Run executes a task and returns the result.
func (a *Agent) Run(ctx context.Context, task string, mgr *provider.Manager) (string, error) {
	a.History = append(a.History, provider.Message{Role: "user", Content: task})
	
	var response string
	err := mgr.Chat(ctx, a.Provider, a.History, func(chunk string) error {
		response += chunk
		return nil
	})
	if err != nil {
		return "", err
	}
	
	a.History = append(a.History, provider.Message{Role: "assistant", Content: response})
	return response, nil
}
