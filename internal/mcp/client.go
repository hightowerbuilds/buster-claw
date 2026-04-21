package mcp

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"os/exec"
	"strings"
	"sync"
	"sync/atomic"
)

// ClientTool is a tool discovered from a remote MCP server.
type ClientTool struct {
	ServerName  string         `json:"serverName"`
	Name        string         `json:"name"`
	QualifiedName string       `json:"qualifiedName"` // serverName.toolName
	Description string         `json:"description"`
	InputSchema map[string]any `json:"inputSchema"`
}

// ServerConfig describes how to launch an MCP server.
type ServerConfig struct {
	Name    string   `json:"name"`
	Command string   `json:"command"`
	Args    []string `json:"args,omitempty"`
	Env     []string `json:"env,omitempty"`
}

// Client connects to an external MCP server via stdio.
type Client struct {
	config  ServerConfig
	cmd     *exec.Cmd
	stdin   io.WriteCloser
	scanner *bufio.Scanner
	nextID  atomic.Int64
	mu      sync.Mutex
	tools   []ClientTool
}

// NewClient creates a client for the given server config.
func NewClient(config ServerConfig) *Client {
	return &Client{config: config}
}

// Connect launches the MCP server process and performs the initialize handshake.
func (c *Client) Connect() error {
	c.cmd = exec.Command(c.config.Command, c.config.Args...)
	c.cmd.Env = append(c.cmd.Environ(), c.config.Env...)

	stdin, err := c.cmd.StdinPipe()
	if err != nil {
		return fmt.Errorf("stdin pipe: %w", err)
	}
	c.stdin = stdin

	stdout, err := c.cmd.StdoutPipe()
	if err != nil {
		return fmt.Errorf("stdout pipe: %w", err)
	}
	c.scanner = bufio.NewScanner(stdout)
	c.scanner.Buffer(make([]byte, 0, 1024*1024), 10*1024*1024)

	if err := c.cmd.Start(); err != nil {
		return fmt.Errorf("start %s: %w", c.config.Command, err)
	}

	// Send initialize
	resp, err := c.call("initialize", map[string]any{
		"protocolVersion": "2024-11-05",
		"capabilities":    map[string]any{},
		"clientInfo": map[string]any{
			"name":    "buster-claw",
			"version": "1.0.0",
		},
	})
	if err != nil {
		c.Close()
		return fmt.Errorf("initialize handshake: %w", err)
	}

	// Check for error in response
	if resp.Error != nil {
		c.Close()
		return fmt.Errorf("server rejected initialize: %s", resp.Error.Message)
	}

	// Send initialized notification
	c.send("notifications/initialized", nil)

	// Discover tools
	return c.discoverTools()
}

// discoverTools fetches the tool list from the server.
func (c *Client) discoverTools() error {
	resp, err := c.call("tools/list", map[string]any{})
	if err != nil {
		return fmt.Errorf("tools/list: %w", err)
	}
	if resp.Error != nil {
		return fmt.Errorf("tools/list error: %s", resp.Error.Message)
	}

	var result struct {
		Tools []struct {
			Name        string         `json:"name"`
			Description string         `json:"description"`
			InputSchema map[string]any `json:"inputSchema"`
		} `json:"tools"`
	}
	raw, _ := json.Marshal(resp.Result)
	if err := json.Unmarshal(raw, &result); err != nil {
		return fmt.Errorf("parse tools: %w", err)
	}

	c.tools = nil
	for _, t := range result.Tools {
		c.tools = append(c.tools, ClientTool{
			ServerName:    c.config.Name,
			Name:          t.Name,
			QualifiedName: c.config.Name + "." + t.Name,
			Description:   t.Description,
			InputSchema:   t.InputSchema,
		})
	}

	return nil
}

// Tools returns the tools discovered from this server.
func (c *Client) Tools() []ClientTool {
	return c.tools
}

// CallTool invokes a tool on the remote server by name.
func (c *Client) CallTool(name string, arguments map[string]any) (string, error) {
	resp, err := c.call("tools/call", map[string]any{
		"name":      name,
		"arguments": arguments,
	})
	if err != nil {
		return "", err
	}
	if resp.Error != nil {
		return "", fmt.Errorf("tool %s: %s", name, resp.Error.Message)
	}

	// Extract text from content array
	raw, _ := json.Marshal(resp.Result)
	var result struct {
		Content []struct {
			Type string `json:"type"`
			Text string `json:"text"`
		} `json:"content"`
		IsError bool `json:"isError"`
	}
	if err := json.Unmarshal(raw, &result); err != nil {
		return fmt.Sprintf("%v", resp.Result), nil
	}

	var texts []string
	for _, c := range result.Content {
		if c.Type == "text" && c.Text != "" {
			texts = append(texts, c.Text)
		}
	}

	combined := strings.Join(texts, "\n")
	if result.IsError {
		return "", fmt.Errorf("tool %s: %s", name, combined)
	}
	return combined, nil
}

// Close shuts down the server process.
func (c *Client) Close() error {
	if c.stdin != nil {
		c.stdin.Close()
	}
	if c.cmd != nil && c.cmd.Process != nil {
		c.cmd.Process.Kill()
		c.cmd.Wait()
	}
	return nil
}

// call sends a JSON-RPC request and waits for a response.
func (c *Client) call(method string, params any) (Response, error) {
	c.mu.Lock()
	defer c.mu.Unlock()

	id := c.nextID.Add(1)
	idJSON, _ := json.Marshal(id)

	req := Request{
		JSONRPC: "2.0",
		ID:      idJSON,
		Method:  method,
	}
	if params != nil {
		p, _ := json.Marshal(params)
		req.Params = p
	}

	data, err := json.Marshal(req)
	if err != nil {
		return Response{}, fmt.Errorf("marshal request: %w", err)
	}

	if _, err := fmt.Fprintf(c.stdin, "%s\n", data); err != nil {
		return Response{}, fmt.Errorf("write request: %w", err)
	}

	// Read response lines until we get one with our ID
	for c.scanner.Scan() {
		line := c.scanner.Bytes()
		if len(line) == 0 {
			continue
		}
		var resp Response
		if err := json.Unmarshal(line, &resp); err != nil {
			continue
		}
		// Match by ID
		if string(resp.ID) == string(idJSON) {
			return resp, nil
		}
	}

	if err := c.scanner.Err(); err != nil {
		return Response{}, fmt.Errorf("read response: %w", err)
	}
	return Response{}, fmt.Errorf("server closed connection")
}

// send fires a notification (no response expected).
func (c *Client) send(method string, params any) {
	req := Request{
		JSONRPC: "2.0",
		Method:  method,
	}
	if params != nil {
		p, _ := json.Marshal(params)
		req.Params = p
	}
	data, _ := json.Marshal(req)
	fmt.Fprintf(c.stdin, "%s\n", data)
}
