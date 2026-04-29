package agent

import (
	"context"
	"sync"
)

// Agent represents an isolated processing unit for a task.
type Agent struct {
	ID        int
	Mu        sync.Mutex
	IsWorking bool
}

// Result summary returned by an agent.
type Result struct {
	AgentID int
	Error   error
}

// AgentPool manages a set of workers.
type AgentPool struct {
	Workers []*Agent
	Ctx     context.Context
	Cancel  context.CancelFunc
}

// NewAgentPool creates a pool with the specified number of workers.
func NewAgentPool(count int) *AgentPool {
	ctx, cancel := context.WithCancel(context.Background())
	pool := &AgentPool{
		Workers: make([]*Agent, count),
		Ctx:     ctx,
		Cancel:  cancel,
	}
	for i := 0; i < count; i++ {
		pool.Workers[i] = &Agent{ID: i + 1}
	}
	return pool
}

// Close stops all workers.
func (p *AgentPool) Close() {
	p.Cancel()
}
