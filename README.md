# Buster Claw

`buster-claw` is a terminal chat app for local Ollama models with a Bubble Tea TUI and streaming responses in the normal terminal buffer.

The default model comes from `LOCALLLM_MODEL` or the `-m` flag. If neither is set, the app starts without a selected model until it discovers installed models from Ollama.

## Requirements

- Go 1.26+
- Ollama installed and running locally
- an installed model such as `gemma4:e2b`

## Run During Development

```bash
go run .
go run . -m gemma4:e2b
go run . -host http://127.0.0.1:11434
```

## Build

```bash
go build -o buster-claw .
```

## Install Globally

From this repository:

```bash
go install .
```

This installs the `buster-claw` binary into your Go bin directory.

## Configuration

- `-m`: default model name for this session
- `-host`: Ollama server URL for this session
- `LOCALLLM_MODEL`: default model name
- `OLLAMA_HOST`: Ollama server URL, defaults to `http://127.0.0.1:11434`

Examples:

```bash
go run . -m gemma4:e2b
go run . -host http://127.0.0.1:11434
LOCALLLM_MODEL=gemma4:e2b go run .
OLLAMA_HOST=http://127.0.0.1:11434 go run .
```

## TUI Commands

- `Enter`: send prompt
- `/remember <text>`: save a durable memory to `Memory/Pneuma.md`
- `/memories`: show saved memory entries
- `/forget <n>`: delete one saved memory entry by number
- `/models`: refresh and show installed Ollama models
- `/model <name>`: switch models
- `/clear`: clear the transcript
- `/quit`: exit
- `q`: quit

## Markdown File Generation

If your prompt asks Gemma to create a Markdown file, `buster-claw` scaffolds the request so the model returns one saveable `.md` document. The app writes that file into the current working directory where you launched the program.

Example prompts:

```text
Create a markdown file named project-brief.md that outlines the Buster Claw roadmap for the next 30 days.
Generate a markdown file with setup instructions for this repo and save it as onboarding.md.
```

The generated file is saved beside the app's working directory, and the transcript shows the saved filename plus the Markdown content.

## Persistent Memory

`buster-claw` can keep durable context in `Memory/Pneuma.md`. Saved memories are injected back into Gemma as system context on future prompts.

Examples:

```text
/remember The primary goal of this repo is generating structured markdown notes from Gemma.
/remember Prefer concise project briefs with headings and action items.
/memories
/forget 1
```

## Model Data

The repository keeps local Ollama model metadata under `models/`. Runtime chat requests go through the Ollama HTTP API.
# buster-claw
# buster-claw
