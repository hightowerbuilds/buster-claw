package mcp

import (
	"encoding/json"
	"fmt"
	"os"
	"strings"
	"sync"
	"time"
)

// MCPConfig is the top-level config file structure for MCP servers.
type MCPConfig struct {
	Servers []ServerConfig `json:"servers"`
}

// Manager coordinates multiple MCP client connections.
type Manager struct {
	configPath string
	clients    map[string]*Client // keyed by server name
	mu         sync.RWMutex
}

const defaultConnectTimeout = 10 * time.Second

// NewManager creates a manager that reads config from the given path.
func NewManager(configPath string) *Manager {
	return &Manager{
		configPath: configPath,
		clients:    make(map[string]*Client),
	}
}

// LoadAndConnect reads the config file and connects to all configured servers.
// Servers that fail to connect are logged but don't prevent others from starting.
func (m *Manager) LoadAndConnect() []error {
	return m.LoadAndConnectTimeout(defaultConnectTimeout)
}

// LoadAndConnectTimeout is LoadAndConnect with an explicit per-server timeout.
func (m *Manager) LoadAndConnectTimeout(timeout time.Duration) []error {
	data, err := os.ReadFile(m.configPath)
	if err != nil {
		if os.IsNotExist(err) {
			return nil // No config = no servers, that's fine
		}
		return []error{fmt.Errorf("read mcp config: %w", err)}
	}

	var config MCPConfig
	if err := json.Unmarshal(data, &config); err != nil {
		return []error{fmt.Errorf("parse mcp config: %w", err)}
	}

	var errs []error
	for _, sc := range config.Servers {
		client := NewClient(sc)
		if err := connectWithTimeout(client, timeout); err != nil {
			errs = append(errs, fmt.Errorf("connect %s: %w", sc.Name, err))
			continue
		}
		m.mu.Lock()
		m.clients[sc.Name] = client
		m.mu.Unlock()
	}

	return errs
}

func connectWithTimeout(client *Client, timeout time.Duration) error {
	if timeout <= 0 {
		return client.Connect()
	}

	done := make(chan error, 1)
	go func() {
		done <- client.Connect()
	}()

	select {
	case err := <-done:
		return err
	case <-time.After(timeout):
		_ = client.Close()
		return fmt.Errorf("timed out after %s", timeout)
	}
}

// AllTools returns every tool from every connected server.
func (m *Manager) AllTools() []ClientTool {
	m.mu.RLock()
	defer m.mu.RUnlock()

	var all []ClientTool
	for _, c := range m.clients {
		all = append(all, c.Tools()...)
	}
	return all
}

// CallTool routes a qualified tool name (server.tool) to the right client.
func (m *Manager) CallTool(qualifiedName string, arguments map[string]any) (string, error) {
	parts := strings.SplitN(qualifiedName, ".", 2)
	if len(parts) != 2 {
		return "", fmt.Errorf("invalid tool name %q — expected server.tool", qualifiedName)
	}

	serverName, toolName := parts[0], parts[1]

	m.mu.RLock()
	client, ok := m.clients[serverName]
	m.mu.RUnlock()

	if !ok {
		return "", fmt.Errorf("no MCP server connected: %s", serverName)
	}

	return client.CallTool(toolName, arguments)
}

// ServerNames returns the names of all connected servers.
func (m *Manager) ServerNames() []string {
	m.mu.RLock()
	defer m.mu.RUnlock()

	names := make([]string, 0, len(m.clients))
	for name := range m.clients {
		names = append(names, name)
	}
	return names
}

// ToolSummary returns a formatted string listing all available MCP tools,
// suitable for injection into an LLM system prompt.
func (m *Manager) ToolSummary() string {
	tools := m.AllTools()
	if len(tools) == 0 {
		return ""
	}

	var b strings.Builder
	b.WriteString("=== AVAILABLE MCP TOOLS ===\n")
	b.WriteString("You can ask to use any of these external tools:\n\n")

	for _, t := range tools {
		fmt.Fprintf(&b, "- **%s**: %s\n", t.QualifiedName, t.Description)
	}

	b.WriteString("\n===========================")
	return b.String()
}

// Close shuts down all connected servers.
func (m *Manager) Close() {
	m.mu.Lock()
	defer m.mu.Unlock()

	for _, c := range m.clients {
		c.Close()
	}
	m.clients = make(map[string]*Client)
}
