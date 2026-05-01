# Local Trust Model

Buster Claw is a local-first research tool. It can intentionally run powerful actions on the user's machine, so these boundaries are explicit:

- Webhooks bind to `127.0.0.1:9090`. A configured secret is enforced with `X-Buster-Claw-Secret` or `Authorization: Bearer ...`.
- Shell hooks run local commands through `bash -c`. They receive event JSON on stdin, time out, and record bounded stdout/stderr diagnostics in memory.
- Provider API keys, browser cookies, delivery tokens, and MCP server config are stored in local JSON files. They are not encrypted by the app.
- Fetched documents and generated reports are treated as untrusted input before display. Markdown rendering goes through the shared sanitizer.
- MCP servers are local processes configured by the user. Only configure servers whose command and working directory you trust.
