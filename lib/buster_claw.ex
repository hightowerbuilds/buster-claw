defmodule BusterClaw do
  @moduledoc """
  The contexts. Everything under `lib/buster_claw/` is domain and business
  logic with no knowledge of the web layer; `BusterClawWeb` renders it and
  `BusterClaw.Commands` exposes it to agents as one catalog.

  Where to look:

  * **The agent** — `Agent.Chat` (a conversation), `AgentBackend` and
    `ModelPolicy` (which CLI and model), `Dispatcher`, `Orchestrator` and
    `Orchestration` (unattended shifts), `Swarm`, `Mailman`, `Duty`.
  * **The command surface** — `Commands` and `Commands.Catalog.*`, gated by
    `PolicyEngine`, `AgentToolPolicy` and `RateLimiter`, receipted by `Sentinel`.
  * **Work** — `Dispatch` and `DispatchProjector` (the queue and its markdown),
    `Jobs`, `Skills`, `TerminalCommands`, `Journal`, `Memory`.
  * **The operator's things** — `Workspace` (the folder and its seeds),
    `Library`, `Notes`, `Pages`, `Pockets`, `Contacts`, `TrustedSenders`,
    `Calendar`, `Notifications`, `Bookmarks`.
  * **Outside services** — `Google.*`, `Integrations`, `Finance`, `Ingest`,
    `Search`, `Weather`, `Messages` (the iMessage probe).
  * **The browser** — `Browser` (the in-app tab and its bridge),
    `BrowserControl` (the engine: flows, checks, Agent Mode, commerce, egress),
    `BrowserHistory`, `Favicons`, `UrlGuard`.
  * **Look and sound** — `Appearance` and `Shaders`, `TerminalTheme`,
    `TerminalPaint`, `ChatSkin`, `Notifications.Sound` and the Sound Studio
    (`Notifications.SoundStudio`, `StudioMix`, `StudioCatalog`, `Capture`),
    `Music`.
  * **Secrets and setup** — `Clinch` (credentials), `Vault`, `Encrypted`,
    `Settings`, `Setup`, `RuntimeConfig`, `Recovery`, `ApiToken`.
  * **Documents for the model and the human** — `Introduction` (the model's
    brief and guide), `UserGuide` (the Manual), `Manual`.
  """
end
