# Senior Code Review: Buster Claw

Alright, let’s get into it. First of all, the ambition here is commendable. You've chosen a solid, modern stack—Go for the backend, Wails to bridge the gap, and SolidJS for a highly reactive, low-overhead frontend. Building a local-first, autonomous AI agent that ingests documents, manages an asynchronous queue, and delivers markdown reports is no small feat. You actually shipped a working application, which puts you ahead of 90% of developers who just talk about ideas.

But that’s where the praise pauses. Right now, this codebase is a house of cards held together by string manipulation, God objects, and sheer luck. If you push this to production or try to scale it with a team, it is going to collapse under its own weight. Let’s break down exactly why, and more importantly, how you need to fix it.

### 1. The `App` God Object (`app.go`)
Your `app.go` file is a classic God Object anti-pattern. You have a single `App` struct that holds references to literally everything: the Ollama client, the orchestrator, memory, MCP manager, providers, scheduler, webhooks, delivery, hooks, and calendar. 

Wails requires you to bind a struct to expose methods to the frontend, but that does *not* mean the bound struct should also be the central nervous system of your entire application. 
*   **The Problem**: Every time you want to add a feature, `app.go` grows. It is already doing command parsing (`handleSlashCommand`), LLM stream generation, dependency wiring, and state mutation. 
*   **The Fix**: Keep `App` strictly as a Wails facade. Its *only* job should be taking requests from the frontend, calling a dedicated service layer, and returning the result. Your slash command parser needs to be abstracted into a `CommandRouter` interface. Your dependencies should be initialized in a proper dependency injection container or `main.go`, not stuffed into `NewApp` as hardcoded `filepath.Join` calls.

### 2. Concurrency and State Nightmares
Go makes concurrency easy to write, but incredibly difficult to get right. You are spraying `sync.Mutex` and `sync.RWMutex` everywhere without thinking about encapsulation.

Look at `internal/agent/agent.go`:
```go
type Agent struct {
	ID        int
	Mu        sync.Mutex
	IsWorking bool
}
```
And then in your Orchestrator (`internal/orchestrator/orchestrator.go`), you are doing this:
```go
w.Mu.Lock()
w.IsWorking = true
w.Mu.Unlock()
```
*   **The Problem**: This defeats the entire purpose of object-oriented encapsulation. If an external package has to manually lock a struct's mutex just to change its internal state, your API is broken. You are begging for a deadlock.
*   **The Fix**: Hide the fields. Make `isWorking` unexported, and provide `SetWorking(bool)` and `IsWorking() bool` methods on the `Agent` struct that handle the locking internally.

Furthermore, in `orchestrator.go`, you are calling `o.hooks.Trigger` and `o.updateStatus` while potentially holding locks, or doing rapid sequential locking/unlocking. If a callback passed to `OnStatusChange` takes too long (e.g., Wails UI event dispatching gets bogged down), your entire backend orchestrator will block. You need to decouple event emission from your core locking logic, perhaps by dispatching status updates over a non-blocking channel.

### 3. Reinventing the Standard Library (Poorly)
Let's talk about `internal/ingest/fetcher.go`. I physically winced when I saw this:

```go
func contains(s, substr string) bool {
	return len(s) >= len(substr) && searchSubstring(s, substr)
}

func searchSubstring(s, substr string) bool {
	for i := 0; i <= len(s)-len(substr); i++ {
		if s[i:i+len(substr)] == substr {
			return true
		}
	}
	return false
}
```
*   **The Problem**: You wrote a manual, byte-by-byte string search loop to check if an error message contains a specific string. 
*   **The Fix**: Delete this immediately. Use the standard library: `strings.Contains(s, substr)`. It is highly optimized, uses assembly-level vector instructions under the hood, and is infinitely less prone to bugs. Never reinvent standard library primitives unless you are writing a performance-critical hot path, and even then, profile it first.

Additionally, your error retry logic checks for HTTP errors by converting the error to a string and looking for `"502"`, `"timeout"`, etc. This is incredibly brittle. Use Go's `errors.As` or `errors.Is` to check for specific error types (like `net.Error` and checking `err.Timeout()`). 

### 4. Database by Regex: The Memory Store
In `internal/memory/memory.go`, you decided to use a raw Markdown file as your persistent database.

```go
closeBracket := strings.Index(line, "] ")
// ...
createdAt := strings.TrimPrefix(line[:closeBracket+1], "- [")
```
*   **The Problem**: You are reading user-submitted memories, which could contain *anything*, and parsing them back out of a flat text file using string indices and brackets. What happens if the user's memory text naturally includes the string `] `? Your parser breaks, the index shifts, and the memory file is permanently corrupted upon next load.
*   **The Fix**: Markdown is an output format, not a database. Store your memories in SQLite, or even a structured JSON file. If the user wants a Markdown version, write an exporter. Never rely on string splitting a rich text file to reconstruct application state.

### 5. Chat History Pollution
In `app.go`'s `SendMessage` method, you inject slash command outputs directly into the chat history:
```go
a.emitSystemMessage(fmt.Sprintf("Remembered: %s (%d total)", arg, a.memory.Count()))
```
*   **The Problem**: Because `a.messages` is literally passed to the Ollama client as the context history (`history = append(history, ...)`), you are feeding system UI messages (like "Remembered: fact") straight into the LLM's prompt window on the next turn. This wastes tokens, confuses the model, and breaks the fourth wall. 
*   **The Fix**: You need a strict separation between `UI Messages` (things the user sees, like command confirmations) and `LLM Context` (the actual conversation to be sent to the model). Only append actual user queries and actual LLM responses to the array that gets passed to the provider.

### 6. Hardcoded HTTP Client Configuration
In `fetcher.go`:
```go
client: &http.Client{
    Timeout: 30 * time.Second,
}
```
Sharing a single HTTP client with a hardcoded 30-second timeout for every single ingestion task is dangerous. Fetching a small RSS feed takes milliseconds, but downloading a massive PDF or waiting for a slow target server might genuinely need 60 seconds. You are running fetchers concurrently—if you hit a slow server, you will tie up your goroutines until the timeout triggers. Pass `context.Context` all the way down into your `http.NewRequestWithContext` (which you did, good job!) but rely on the context for timeouts, not a blunt-force timeout on the shared client struct.

### 7. The Markdown Extraction Logic
In `orchestrator.go`, you demand the LLM return a specific marker `<<FILE:report.md>>`, and then you use `strings.Index` to extract it. You added a `fallbackMarkdownReport` which is good defensive programming, but your prompt engineering is fighting your code. 
Instead of forcing an LLM to reliably print custom string markers, use the model's native structured output capabilities (like JSON schema forcing if supported by the provider), or use a robust Markdown AST parser (like `yuin/goldmark`) to programmatically extract the first `code block` instead of relying on exact string matches.

### Summary
You’ve got the bones of a great app here. The feature set is impressive, the UI layer in SolidJS looks well-partitioned by feature (`src/features/`), and utilizing Wails to keep memory usage low is a smart architectural choice. 

But you need to stop adding features today. Spend the next week refactoring. 
1. Break `App` into domain-specific services.
2. Delete your custom string-searching functions.
3. Migrate `memory.md` to JSON or SQLite.
4. Audit every single `sync.Mutex` and ensure it is strictly encapsulated inside its struct.

Fix the foundation before you build the next floor.