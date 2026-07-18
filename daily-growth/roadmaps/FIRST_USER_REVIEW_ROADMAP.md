# Buster Claw — First-User Review (Distributing Today)

**Date:** 2026-07-17 · **App version:** 0.1.0 · **Status:** ACTIVE — a critical, walk-the-user review of what a brand-new customer actually meets when they download the DMG today.

> **POV:** A first-time user who has already used **Open Claw, Zero Claw, and Hermes** — i.e. someone who knows what an "agent runtime" is supposed to feel like, has a Claude Code subscription, and is evaluating Buster Claw against the alternatives. They are not Luke. They downloaded a `.dmg`, double-clicked it, and started forming an opinion in the first ninety seconds. This document follows that path end to end and records every hole, every redundancy, every over-built surface, and every missing thing — the way a real QA pass would surface them, not the way the architecture doc describes itself.

This is deliberately complementary to the existing roadmaps. `DISTRIBUTION_ROADMAP.md` settles the *signing/arch* question; `GO_TO_MARKET_ROADMAP.md` settles the *business* question; `CODE_QUALITY_ROADMAP.md` settles the *internal cleanliness* question. None of them walk the **user**. This one does.

---

## The short version

Buster Claw is not one product. It is five products sharing one Tauri shell, and a new user cannot form a single mental model of what it is in the first session:

- The **README** sells "a desktop runtime that gives an AI agent hands — and a full audit trail" (the Open Claw / Hermes lane).
- The **onboarding wizard** sells "your assistant, reachable by email" (a Gmail triage product).
- The **home screen** sells "chat with Claude" (a ChatGPT-with-a-shell product).
- The **Phone tab** sells "an answering machine for your agent" (a telephony product that is 90% unbuilt).
- The **Wallets tab** sells "personal finance + model-cost tracking" (a Mint-for-AI product nobody asked for at v0.1.0).

A user who arrived from Open Claw or Zero Claw — lean agent runtimes with a clear front door — lands in an app whose dock has eight icons and whose first screen has a shader background, a CRT-scanline wordmark, a corner widget with four sub-tabs, a chat with an SVG-viewer sidebar, and a "go on duty" loop that lives in a *different* tab. They will not know what the app is for. That is the review in one sentence, and everything below is the evidence.

The good news, and it is real: the **engineering is unusually sound for a solo project** — zero compiler warnings, a real trust-tier model, SSRF pinning that actually closes the rebinding TOCTOU, a durable queue with a markdown projection, Sentinel audit, encrypted secrets at rest. The bones are excellent. The problem is everything *above* the bones: the product story, the surface area, and the first-ninety-seconds experience. None of that is an engineering failure; all of it is a *focus* failure, and focus is fixable cheaper than architecture.

---

## Part I — The DMG (the first ninety seconds)

This is the highest-leverage moment in the entire customer relationship, and today it is the worst moment in the product.

1. **Gatekeeper says "Move to Trash."** The build is unsigned. On macOS Sequoia and Tahoe 26, double-clicking an unverified `.dmg` produces a dialog whose only buttons are **"Move to Trash"** and **"Done."** The Control-click bypass that used to rescue unsigned apps is gone. To actually open Buster Claw, a new user must go to **System Settings → Privacy & Security → Open Anyway**, type their admin password, and do it within the ~1-hour window after the failed launch. This is not friction — it is the operating system telling your customer that your software is malware. `DISTRIBUTION_ROADMAP.md` has the fix (Developer ID + notarization, ~$99 and a week); from the *user's* POV, shipping an unsigned DMG today is a non-launch. The first review on a forum will be "couldn't open it," not "the audit feed is great."

2. **It's Intel-only on an Apple-Silicon world.** Every Mac sold in the last five years is ARM. The shipped bundle is x86_64, so it runs under Rosetta — and macOS 26.4 already shows a warning when you launch an Intel app. macOS 27 "Golden Gate" (this fall) is the *last* release with Rosetta, and its installer *removes* it. macOS 28 (fall 2027) drops Intel support outright. A user on an M-series Mac who gets past Gatekeeper immediately gets a second dialog telling them the app is deprecated. The user does not know or care that a universal ERTS breaks the JIT; they know the app feels old on day one.

3. **The bundle is 88MB, ~10% of which is build waste.** `priv/plts/` ships three Dialyzer PLT files (one is 5.6MB) to every user. They have no function in a shipped app. The Playwright sidecar (17MB of `node_modules`, including TypeScript `.d.ts` declaration files) ships too, even though the prod build never enables the sidecar and requires a user-installed `node` anyway. Buster Claw's *own compiled code* is **2.5MB, or 2.8% of the bundle**. A user on a metered connection downloads 85MB of runtime and waste to get 2.5MB of product.

4. **The bundle ID is `com.hightowerbuilds.busterclaw`.** The operator's personal handle, not the product. It shows up in the macOS Keychain entry, in the OAuth consent screen, in the webview cache path. It is a one-way door: changing it after someone installs orphans their app-data directory and breaks notarization continuity. It also reads, to a careful user granting Gmail scopes, as "one guy's side project." Which it is — but that is a decision to own, not an accident to let leak through the bundle ID.

5. **No updater.** An agentic app that can read and *act on* your email will someday need a security patch shipped fast. "Please re-download the DMG" is not a patch channel. `DISTRIBUTION_ROADMAP.md` covers the Tauri updater + minisign key; from the user's POV, the absence is felt the first time something breaks and they have no "check for updates" anywhere in Settings.

**The user's state after ninety seconds:** they have seen two OS warnings, downloaded 88MB, and opened a window. They have not yet seen a single feature. Against Open Claw / Zero Claw / Hermes — which presumably open clean and present one obvious thing to do — this is already a loss.

---

## Part II — Onboarding (the four dots)

`SetupLive` is a five-step wizard (`lib/buster_claw_web/live/setup_live.ex`): welcome → workspace → tools → google → live, shown as four dots. It is the right *shape* for a first-run. The *content* works against itself.

6. **The welcome screen pitches the wrong product.** It says: *"Your assistant, reachable by email… your trusted contacts can email it too, and it gets to work: reading mail, browsing the web, handling tasks, and replying for you."* That is a Gmail-assistant pitch. The README pitches an agent runtime. A user who came from Open Claw (an agent runtime) just got told they installed an email assistant. They will scroll the dock looking for "the agent stuff" and find eight unrelated icons. The wizard should pitch the product the README pitches, or the README should pitch the product the wizard pitches — today they disagree.

7. **Step 2 assumes Homebrew and hides it.** "Install Claude Code" runs `brew install --cask claude-code` (`setup_live.ex:35`). There is no detection of `brew` itself, no fallback, no "install Homebrew first" path. The wizard's pitch is *"no terminal knowledge needed"* — and then it opens a terminal with a brew command pre-typed and tells the user to press enter. If `brew` isn't installed, the command fails opaquely and the user is told to "Re-check." A real non-technical user — the prosumer the GTM roadmap eventually wants — is stuck here with no guidance. A brew prerequisite is fine for the dev-first audience; pretending it isn't a prerequisite is not.

8. **"You'll do this once" is a lie for beta testers.** The Google step says connecting is *"a one-time Google step."* Under the unverified OAuth cap (Clock 2 in `GO_TO_MARKET_ROADMAP.md`), beta testers' refresh tokens expire **every 7 days**. There is a conditional beta note (`setup_live.ex:367`) — but it only renders when `bundled_available and GoogleOAuth.beta_testing?()`, and it asks the user to *email an address to request access*. So the first-run flow for a beta user is: click Connect Google → discover you're not in the tester list → email a stranger → wait "within a day" → reconnect weekly forever. That is the opposite of one-click.

9. **The wizard grants max permissions in one click.** The Google step instructs the user to *"approve them all to give your agent full access"* — Gmail, Calendar, Drive, Docs, Sheets, Slides, Contacts, Tasks, all at once, for an app whose entire pitch is an **audit trail** and a **trust gate**. Least-privilege onboarding would start with Gmail read-only, prove the audit feed works, and *then* offer to widen. Asking for Gmail **send-as** plus seven other services on minute three of first use is the kind of consent screen that makes a security-minded user close the app.

10. **The wizard ends in a terminal; the home screen starts a chat.** Step 4 "Go live" calls `TerminalWorkspace.request_open_mailman()` and navigates to `/terminal` (`setup_live.ex:225`). The terminal runs `./buster-claw on-duty`, which spawns `claude --permission-mode bypassPermissions` headlessly to work the Dispatch queue. **Separately**, the home screen (`status_live.ex`) has a full chat panel that *also* runs `claude` headlessly via `AgentRunner`, but as a direct conversation with no queue. These are two different agent entry points with two different mental models, two different docs (`daily-loop.md` vs `get_started_live.ex`), and two different trust flows — and the wizard routes you to one while the home screen (the default tab) shows you the other. A new user's first thought is "which one am I supposed to use?"

11. **`setup.md` (user-guide) describes a wizard that no longer exists.** It says the wizard collects "1. You — your name/org, 2. Workspace folder, 3. Google Workspace." The actual wizard has five steps and never asks for a name/org. The in-app manual is stale before the user finishes onboarding.

**The user's state after onboarding:** connected (maybe), confused about whether they're an email-triage user or a chat user, and not once shown the audit feed that is the product's reason for existing.

---

## Part III — The home screen (the first real surface)

`StatusLive` (`lib/buster_claw_web/live/status_live.ex`) is the default route and the first thing the user sees after the wizard. It is doing too much.

12. **Seven concerns on one screen.** A live WebGPU shader background; a CRT-scanline brand heading with a chromatic-aberration hook (`CrtAberration`); a setup nudge; a corner widget that itself has four sub-tabs (Calendar / Contacts / Time & Place / Notify); a chat tab strip; an SVG-viewer sidebar; and the chat panel. For a first look this is a *lot* to parse, and nothing on the screen tells you which of the seven is the primary action. Open Claw and Zero Claw presumably present one thing. Buster Claw presents seven and lets the user guess.

13. **The home chat is undocumented in the README.** The README says, in bold, *"There is no LLM inside Buster Claw and it needs no API keys."* The home chat spawns the user's `claude` headlessly (`AgentRunner`, `agent_runner.ex`) with `--permission-mode bypassPermissions` and streams replies back into a chat UI. That is *using an LLM*, just not *hosting* one — the README's claim is technically true and practically misleading. A user who read the README and then met a chat box that talks back will be surprised, and not in the way the README intended.

14. **`bypassPermissions` is invisible to the user.** `AgentRunner` runs `claude --permission-mode bypassPermissions` so headless runs don't stall on Claude's own permission prompts (`agent_runner.ex:28-36`). The trust boundary doc correctly notes that `BusterClaw.Commands` is the *real* auth boundary, not Claude's prompts. That is sound engineering. It is also a fact the user is never told. A new user has no idea that the chat they're typing into is driving their Claude subscription with permissions bypassed, and that the only thing standing between the agent and a `gmail_send` is the `:restricted` tier check on the loopback token. For an audit-trail product, this should be the *first* thing the user is shown, not a comment in a source file.

15. **The SVG viewer is delightful and unexplained.** The chat extracts ```svg blocks from assistant replies, sanitizes them, and renders them in a dedicated sidebar with a zoom modal and keyboard nav (`status_live.ex:538-658`). It is genuinely cool. It is also completely unexplained — a new user whose agent draws a diagram will see a "SVG viewer" rail light up and have no idea why it exists, how to use it, or that they can ask the agent to produce SVGs. Delightful details with no onboarding read as bugs to a first-time user.

16. **The corner widget hides the most important security control.** The "Contacts" sub-tab of the corner widget is where trusted senders are managed (`status_live.ex:91-97`). The trusted-senders list is **the gate** — it is what stops arbitrary email from driving the agent. The wizard auto-trusts the user's own address on connect (`setup_live.ex:622`) and never asks the user to review the policy. So the single most important security surface in the app is a small tab inside a corner widget on a screen that also has a shader, a chat, and an SVG viewer. A user could go live, tell a friend "email my assistant," and never realize the friend's mail is being archived but never queued — because they never opened the Contacts sub-tab.

**The user's state on the home screen:** they have a chat that talks, a shader that moves, a sidebar they don't understand, and a security gate they can't see. They have not been shown the audit feed.

---

## Part IV — The "five products" problem (the core hole)

This is the single biggest issue in the review, and it is not an engineering issue — it is a product-story issue. Every other finding compounds this one.

17. **Buster Claw has no front door.** Open Claw, Zero Claw, and Hermes (the products the user is comparing against) each presumably have one obvious thing you do first. Buster Claw has five obvious things, none of them labeled as the main one:

| Surface | What it pitches | Where it lives |
|---|---|---|
| README | "Agent runtime + audit trail" | The repo |
| Onboarding wizard | "Email assistant" | `/setup` |
| Home screen | "Chat with Claude" | `/` (default tab) |
| Phone tab | "Answering machine for your agent" | Dock icon |
| Wallets tab | "Personal finance + model-cost tracking" | Dock icon |

A new user cannot answer "what is Buster Claw?" after a full session. The answer changes depending on which screen they're looking at. The competitor that wins the comparison will be the one with a one-sentence pitch that matches the first screen. Today Buster Claw has a five-sentence pitch and the first screen matches none of them.

18. **Two agent entry points with contradictory docs.** The terminal `on-duty` loop (documented in `daily-loop.md`: "trusted email → queue → fridge → agent claims → does it → marks done") and the home headless chat (documented in `get_started_live.ex`: "use the chat on the Home screen, ask it to triage your inbox") are two different ways to use the same agent, with different state, different trust flow, and different output. The queue loop is durable and auditable; the chat is ephemeral and conversational. The user has to discover which one is "real" by trying both. **Pick one as the front door and make the other an advanced mode.** Shipping both as equal citizens is the most expensive form of the five-products problem, because it forks the user's mental model of *what the agent even is*.

19. **The "Advanced" surfaces in the docs don't exist.** `user-guide/introduction.md` lists: *"Advanced — Scheduler, Webhooks/Hooks, Integrations, Delivery, Memory, and Security."* A grep of the web layer confirms **Scheduler, Webhooks/Hooks, Delivery, and Memory are not in the app** — they were retired (per `docs/COMMAND_SURFACE.md` "Current Cuts": Scheduler jobs, Webhooks, Hooks, Delivery, DB-backed Memory all retired as unused). So the in-app manual sends the user looking for five features, only one of which (Security) still exists. This is the fastest way to destroy a new user's trust in the documentation: tell them to click something that isn't there.

---

## Part V — Half-built & decorative surfaces (the "is this real?" problem)

A new user judges maturity by the weakest surface they click, not the strongest. Several dock-level surfaces are demos in main-nav clothing.

20. **The Phone tab is a showcase for a feature that isn't built.** The README is honest about this: "inbound voicemail only… no outbound calls or texts… the dialpad is decorative… still a trial Twilio number." But the Phone tab is in the **dock** — equal nav weight to Home and Terminal. The tab itself (`phone_live.ex`) is a 1,058-line "Message Machine" with per-row WGSL waveform shaders, a mandelbrot playback panel, shader-generated contact "faces," a cost-breakdown display, and a contacts trust toggle. It is the most visually polished surface in the app. And it does **nothing a user can use on day one**: there's no number to give out (trial number, retired in some docs), no outbound path, and the filter bar offers **All / Voicemail / Texts / Calls** — Texts and Calls lead to empty states. A user clicks "Calls," sees nothing, and concludes the app is broken. Putting a flagship-polished demo of an unbuilt feature in the main dock is worse than hiding it: it sets an expectation the app can't meet.

21. **The Voice tab is a dead end.** `VoiceLive` (`voice_live.ex`) is 58 lines — a static explainer that says "toggle Voice on/off from the button in the chat header." There is no setting on the Voice settings page. The actual control lives elsewhere. A user navigating Settings → Voice to configure voice gets a paragraph telling them to go somewhere else. That is a wasted nav click that reads as "this feature has no settings," which reads as "this feature is unfinished."

22. **Wallets is the most over-built surface relative to the product story.** `WalletsLive` (`wallets_live.ex`, 900 lines) is a full personal-finance application: business/personal wallets, transactions, feeds from four sources (market ticker / website URL / integration / Gmail receipts), budgets, a "BusterClaw template," and **model-cost tracking by provider** (Anthropic / OpenAI / OpenCode). None of this is in the README, none of it is in the onboarding, and none of it has anything to do with "agent runtime" or "email assistant." It is an internal operator concern ("how much is my Claude sub costing me") dressed up as a user feature and given a dock icon. At v0.1.0, with no users yet, a 900-line wallets surface with Gmail-receipt ingestion is the clearest over-engineering signal in the codebase.

23. **Phone and Wallets are now entangled.** The telephony cost back-fill feeds a "BusterClaw template" panel in Wallets (`wallets_live.ex:23-25` subscribes to telephony broadcasts). So the half-built phone feature is wired into the over-built wallets feature. Coupling two low-value surfaces together means neither can be cut cleanly without touching the other, and a bug in one surfaces in the other. A new user who sees a "phone spend" line item in a wallets tab they don't understand will be confused about why their finance app knows about their voicemail.

24. **Three+ independent shader systems.** Home `SmokeBackground`, Phone `mandel` playback shader, contact `ShaderFace`, per-row `AudioClip` waveform shaders — each is a separate WebGPU render loop with its own hook. `CODE_QUALITY_ROADMAP.md` notes the Phone tab alone can run **up to 200 simultaneous 60fps render loops**. This is art-project density in a tool whose value prop is reliability and audit. On a first look it reads as "the developer cared more about the background than the audit feed." On a battery, it reads as "why is my laptop hot."

---

## Part VI — Documentation drift (trust destruction at first contact)

A user who opens the in-app **Manual** (`/manual`) or the **Get Started** tab is reading docs that describe a different app than the one they're running. This is the cheapest class of problem to fix and the most damaging to leave, because it tells the user the docs are not a source of truth.

25. **`introduction.md` lists four retired features as "Advanced."** (Finding #19, restated because it belongs here too.) Scheduler, Webhooks/Hooks, Delivery, Memory — all retired per `COMMAND_SURFACE.md`, all listed as active in the user guide.

26. **`setup.md` describes a 3-step wizard; the app has 5 steps.** The user guide says the wizard collects name/org, workspace, Google. The wizard never asks for a name/org and adds Tools and Go-live steps. The guide is stale.

27. **`daily-loop.md` and the home chat describe different products.** `daily-loop.md` is the terminal `on-duty` / Dispatch-queue loop. The home chat (`get_started_live.ex`) is a direct headless conversation. Both are presented as "how to use Buster Claw." A user reading the manual and then using the home screen will think they're holding it wrong.

28. **The README never mentions the home chat or the wallets tab.** The README's Features list leads with the terminal, the command surface, the browser, Google Workspace, and unattended shifts. It does not mention that the default tab is a chat box, or that there's a 900-line wallets surface in the dock. A user who reads the README front-to-back and then opens the app will not recognize the home screen.

29. **The retired trial number is still in the docs; the live number is nowhere.** `LEFTOVERS.md`: the trial number `+1 844-687-8016` still appears in roadmaps and agent memory as if it were the product's number, the live paid local number bought 07-13 isn't written down, and the old Supabase telephony function is still deployed and can still answer the trial number. A QA tester following the docs calls the wrong line. **→ RESOLVED 07-18: the paid number (+1 360-364-6763) is recorded in `phone-maps/BUSTERPHONE_ROADMAP.md` and `supabase/SETUP.md`, the old relay is torn down, and the stale "trial" claims in README/GTM are fixed.**

---

## Part VII — Trust & safety surface (for a *security* product)

Buster Claw's pitch is an audit trail. The engineering behind that pitch is excellent. The *user exposure* of that engineering is poor — a new user is never walked to the audit feed, never shown the trust gate, and never told what permissions are in effect.

30. **The Security tab is the last settings sub-tab.** `SettingsTabs` order (`settings_tabs.ex:9`): Get Started → Appearance → Voice → Integrations → Configuration → Cmd List → **Security**. The single most important surface for the product's pitch is the seventh click. A user who connected Gmail (with send-as) in the wizard should be *led* to the audit feed next, not left to discover it under Settings.

31. **The refusal queue has no visible home in the dock.** The README says restricted refusals from untrusted callers "are queued for you, not silently dropped." Where does the user *see* that queue? It's in Security, under Settings, behind six other tabs. If an untrusted sender's mail triggers a refused action, the user has to know to go look. There is no badge, no dock indicator, no "you have N refusals to review." For a product whose value is "nothing is invisible," the refusal queue is itself nearly invisible.

32. **There is no in-app kill-switch visibility.** The `STOP` file is the emergency brake for an unattended shift (`daily-loop.md`, the orchestrator's kill switch). There is no UI that tells the user a shift is running, no UI that tells them the STOP file exists, and no UI that exposes "stop everything now." The most important safety control is a file on disk that the user learns about from a markdown doc. Compare to Open Claw / Hermes, which presumably have a big red button in the chrome.

33. **No agent-orientation health check.** The app calls `BusterClaw.Introduction.ensure()` on boot to install a workspace guide the agent reads (`application.ex:65`). But there is no user-visible signal that the agent *understood* the guide, or even that it's present. A new user going on-duty for the first time has no way to know whether their agent is oriented to the workspace or flailing. A "first run" health check ("your agent found its workspace guide and read 12 commands") would convert anxiety into confidence.

34. **`auth_status` on `dispatch_items` is a security signal that may be a no-op.** `LEFTOVERS.md`: every row carries `auth_status = "unverified"` and nothing obviously ever sets it to anything else. This is the same class of bug as the `telephony_contacts.trusted` decoy column already deleted — an unwired switch that a future change might bind to and trust. A QA pass would flag it; a user never sees it, but it underlines that the trust plumbing has dead branches a reviewer can't easily dismiss.

---

## Part VIII — Redundancy & over-engineering

35. **Two agent entry points** (#18 above) — the terminal queue loop and the home chat. Same agent, two UXs, two docs, two trust presentations. This is the headline redundancy.

36. **~134 commands across 12 domains.** `BusterClaw.Commands` covers documents, browser, Google (mail/calendar/contacts/docs/drive), finance, integrations, memory, skills, orchestration, telephony, wallets, web. For a v0.1.0 aimed at one user on one Mac, this is an enormous surface to document, keep consistent, and keep trust-tiered. Several domains (finance, wallets, telephony) are solo-operator features wearing product hats. A competitor with 20 commands and a clear front door will *feel* simpler even if it does less.

37. **Appearance flexibility that no v0.1.0 user will touch.** The home background can be: an uploaded image, a named built-in shader, or a custom `.wgsl` file dropped into the workspace, with custom color palettes (`status_live.ex:716-741`, `Appearance`). This is world-class flexibility for a setting that ~zero first-users will configure. It is also a maintenance and WebGPU-compat surface. The "drop a `.wgsl` in and it compiles at runtime" feature is a delightful engineering flex; at first-launch it is a category of thing that can break on a different macOS version with no user benefit.

38. **Model-cost tracking is an operator feature in a user dock.** Wallets' "model cost" tracking by provider (Anthropic/OpenAI/OpenCode) is how *Luke* watches his own spend. It is not a feature for a user who just installed the app. It should not be in the main dock at v0.1.0.

39. **Three shader systems** (#24) — home, phone, contacts, audio clips. Each independently can break on a WKWebView version bump. The graceful blank-canvas fallback exists, but four independent breakable visual systems is more than a v0.1.0 needs to be carrying.

40. **The `bare`/`shell`/`embedded` layout branching.** `Layouts.app` switches between a full shell, a bare split-pane, and an embedded-browser chrome based on `ChromeHook.embedded?/0` and the `full_bleed`/`wide` attrs (`layouts.ex:112-118`). Correct, but three layout modes is the kind of thing that makes a QA pass long and a first-user click-path hard to predict (the same route looks different in the browser webview vs the chrome webview vs standalone).

---

## Part IX — Missing for a "distributing today" launch

41. **No telemetry / no crash reporting.** `GO_TO_MARKET_ROADMAP.md` W5: the app ships zero telemetry today — "a feature for privacy, a blindfold for did the beta work." A new user's first crash is silent. There is no way to know the beta is working at all.

42. **No in-app first-run tour beyond the wizard.** The "Get Started" settings tab has five quick-chat prompts (`get_started_live.ex:12-18`) — "explain the introduction," "run a safe and a restricted command," etc. These are agent-driven, assume the agent works, and assume the user wants to chat. There is no static "here is the audit feed, here is the trust gate, here is the kill switch" tour. A user who doesn't want to chat has no path.

43. **No user-facing error recovery.** If the BEAM crashes, the webview shows a connection error. `BUILD.md` troubleshooting points the user to `~/Library/Application Support/BusterClaw/logs/release.stderr.log`. That is a developer recovery path, not a user one. There is no "restart Buster Claw" button, no "something went wrong, here's what to do" surface.

44. **No data export / workspace reset / move-workspace from the UI.** The wizard says "you can move it later" (`setup_live.ex:278`) — via what? The workspace is markdown on disk (good, grep works), but there's no Settings control to move it, reset it, or export it. A user who picked the wrong folder on minute two has no UI recourse.

45. **No macOS-version-floor communication.** `GO_TO_MARKET_ROADMAP.md` R7: WebGPU-in-WKWebView sets a minimum macOS that has never been determined. A user on an older Mac gets a blank homepage shader with no explanation (the fallback exists but isn't communicated). Cheap to test, embarrassing to discover via a refund.

46. **No onboarding for what the *agent* should do.** The agent is dropped into the workspace and expected to read `shift/Dispatch.md` and the introduction. A new user has no way to verify the agent is oriented, no "test dispatch item" seeded for them to claim, and no sample job beyond `mail-triage.md`. The "good first run" in `daily-loop.md` (send yourself an email, claim it, mark it done) is a great ritual — it is not surfaced in the app.

47. **No update notification.** No "new version available" anywhere. A beta user on 0.1.0 will stay on 0.1.0 until they re-download manually.

---

## Part X — QA-path landmines (things a pass would catch in minutes)

These are in the existing roadmaps as "leftovers," but from a *QA* POV they are first-session landmines.

48. **"Shipped = compiles."** `LEFTOVERS.md`: the ten browser/tab features merged 07-02 were verified with **compile + tests only — nobody has clicked through them in the running desktop app.** Cmd-W semantics, history dedup, bookmark folder round-trip, agent co-presence, Cmd-1…9, busy-terminal close confirm — all "shipped" unclicked. A QA pass will find something in the first ten minutes.

49. **The webview cache is shared across builds.** `BUILD.md`: all builds share bundle id `com.hightowerbuilds.busterclaw`, so they share one webview cache. A beta user updating to a new build sees a **stale UI** unless they manually clear `~/Library/WebKit/...`. They will report bugs that don't exist. This is a distribution-level QA trap, not an app bug.

50. **Two Supabase functions can answer the trial number.** `LEFTOVERS.md`: the old project's `voice` edge function is still deployed with Twilio creds. A QA tester calling the number in the docs hits the *old* project, not the new one. The phone feature under test is not the phone feature in production. **→ RESOLVED 07-18: the old project's `voice` function is deleted and its Twilio secrets unset; only the dedicated project answers.**

51. **The docs' trial number is retired; the real number is unrecorded.** Same source. Following the docs tests the wrong line. This is a QA blocker, not a nit. **→ RESOLVED 07-18 (see #29).**

52. **`on-duty` runs `claude --permission-mode bypassPermissions` with no UI warning.** A QA tester going on-duty for the first time is granting headless bypass-permissioned Claude access to their Gmail with no on-screen disclosure. The disclosure is in `agent_runner.ex` comments. QA will (correctly) flag this as a consent gap.

53. **The "Re-check" loop in the Tools step has no failure detail.** `setup_live.ex:133`: if Claude isn't found after the user ran the installer, the only feedback is the same "not installed yet" row. No "brew not found," no "command failed," no log pointer. QA will report "I pressed Re-check and nothing happened."

---

## Part XI — Through the competitor lens (Open Claw / Zero Claw / Hermes)

A user who has used the competing "claws" is doing a side-by-side in their head. Here is what they will notice, charitably:

- **Open Claw / Zero Claw** presumably present *one* front door: a terminal, an agent, a command list. Buster Claw presents five front doors and a shader. The competitor feels focused; Buster Claw feels like a showcase.
- **Hermes** (if it's the orchestration-flavored one) presumably has a clear "runs and their state" surface. Buster Claw's `Orchestration` / shift state lives in the terminal and `shift/`; there is no dock-level "what is my agent doing right now" panel. The home chat shows *one* conversation's bubbles; it does not show shift status, queue depth, or run budget.
- **The audit feed is Buster Claw's differentiated feature.** Open Claw / Zero Claw / Hermes almost certainly do *not* have a Sentinel-style per-command, redacted, trust-tiered audit log with refusal queuing. **This is the thing to lead with and the thing that is buried.** A competitor comparison that ends "Buster Claw is the only one with a real audit trail" is the win; today the audit trail is the seventh settings tab.
- **The trust-tier model is differentiated.** Three tokens, three tiers, derived from *which token* not *which route* — this is more sophisticated than a competitor's "admin vs user." It is also completely invisible to a first-time user.

The takeaway from the competitor lens: **Buster Claw's best features are the ones it hides, and its most visible features are the ones that don't belong.** The shader, the wallets, the phone demo, and the dual agent entry points are what the user *sees*; the audit feed, the trust tiers, the SSRF pinning, and the durable queue are what the user *gets*. Those two lists should be swapped.

---

## Part XII — Honest priorities (what to fix before the first non-operator downloads)

Not everything above matters equally. Ranked by "would a first-user notice this in session one," in descending order:

### Must fix before any non-operator downloads (blocks launch)

1. **Sign + notarize + arm64.** (Findings 1–2.) Without this, the first user meets "Move to Trash" and an Intel-app warning. Everything else is moot. Already in `DISTRIBUTION_ROADMAP.md`; restated because from the user's POV it is #1.
2. **Pick one front door.** (Findings 6, 10, 17, 18.) Decide whether Buster Claw is "email assistant with a queue" or "chat with Claude with a command surface." Make the other an advanced mode. Rewrite the README, the wizard welcome, and the home screen to agree on the same one sentence. This is the cheapest high-impact fix in the whole review — it's mostly deletion and rewording.
3. **Fix the documentation drift.** (Findings 19, 25–29.) Remove the retired "Advanced" features from `introduction.md`; rewrite `setup.md` to match the 5-step wizard; reconcile `daily-loop.md` with the home chat; update the README to mention the surfaces that actually exist (chat, wallets-or-not) and drop the ones that don't. Stale docs destroy trust faster than missing features.
4. **Lead with the audit feed.** (Findings 30, 31.) After Google connect, walk the user to Security. Surface a refusal-queue badge in the dock or header. The product's reason for existing should be the second screen, not the seventh settings tab.
5. **Disclose `bypassPermissions` and the kill switch in the UI.** (Findings 14, 32, 52.) A one-line disclosure on the first on-duty/chat run ("your Claude is being driven headlessly with its own prompts bypassed; the real gate is our command trust tier; here is the STOP button") converts a hidden risk into a visible feature.

### Should fix for a credible beta (felt in session one)

6. **Hide the unbuilt surfaces.** (Findings 20, 21, 22.) Move Phone and Wallets out of the dock until they're real (or behind an "Advanced/labs" toggle). Replace the Voice settings page with the actual toggle or remove the tab. The dock should be the *product*, not the *roadmap*.
7. **Trim the home screen.** (Findings 12, 15, 16.) One primary action above the fold. Move the SVG viewer behind a toggle. Surface the trusted-senders gate as a first-class control, not a corner-widget sub-tab.
8. **Onboard the agent, not just the user.** (Findings 33, 46.) A "your agent is oriented" health check and a seeded test dispatch item turn first-run anxiety into a successful ritual.
9. **Stop shipping build waste.** (Finding 3.) Exclude `priv/plts` and prune the Playwright `node_modules`. 10%+ smaller bundle for one line of config.
10. **Add the updater.** (Finding 5, 47.) First non-operator user is the first user who will need a patch.

### Nice to have (felt by session three)

11. **Telemetry with consent.** (Finding 41.) You can't fix what you can't see.
12. **Error recovery UI + workspace move/reset.** (Findings 43, 44.)
13. **Determine and state the macOS floor.** (Finding 45.)
14. **Collapse the redundant surfaces.** (Findings 35–40.) Fewer, deeper features.

---

## Part XIII — The order to do it in, and what it costs

The temptation is to fix the visible stuff (the shader, the phone demo) first. **Resist it.** The visible stuff is not what's losing the comparison; the *story* is what's losing the comparison, and the story is fixed by deletion and rewording, which is nearly free.

1. **This week — the story, for free.** Pick the front door. Rewrite the README, the wizard welcome, and the home-screen primary action to agree. Delete the retired features from the user guide. Decide whether Phone and Wallets are in the dock or behind a labs toggle. **Cost: hours, not days. Mostly words.** This is the single highest-leverage work in the review and it requires no code architecture.
2. **Same week — surface the audit feed and the kill switch.** Move Security up the settings order; add a refusal badge; add a visible "shift is running / STOP" control. **Cost: a day or two of LiveView work.** This converts the hidden differentiator into the visible one.
3. **In parallel — sign, notarize, arm64, updater, trim the bundle.** Already scoped in `DISTRIBUTION_ROADMAP.md`. **Cost: ~a week of real engineering.** This is the only thing blocking *anyone* from a usable first ninety seconds.
4. **Then — hide/trim the over-built surfaces.** Move Phone, Wallets, Voice out of the main nav or behind a toggle; trim the home screen; remove the SVG viewer from the default. **Cost: small diffs, mostly deletion.**
5. **Then — onboarding the agent, error recovery, macOS floor, telemetry.** The "credible beta" list. **Cost: days each.**

**The through-line:** every "redundancy" finding is really a *focus* finding, and focus is the cheapest thing to buy. Buster Claw's engineering is ahead of its product story. The fastest path to a credible first-user review is not building more — it is **removing the surfaces that don't support one sentence, and leading with the audit and trust features that already work and that no competitor has.** The app a user would love is already in here; it is buried under five products and a shader.

---

## Appendix — Findings index (by file)

| # | Finding | Source |
|---|---|---|
| 1–2 | Unsigned + Intel-only | `BUILD.md`, `DISTRIBUTION_ROADMAP.md` |
| 3 | 88MB bundle, 10% PLT waste | `DISTRIBUTION_ROADMAP.md` §8 |
| 4 | Bundle ID `com.hightowerbuilds.busterclaw` | `BUILD.md`, `GO_TO_MARKET_ROADMAP.md` |
| 6, 17 | Wizard pitches email assistant; README pitches agent runtime | `setup_live.ex:251-266`, `README.md:3-7` |
| 7 | `brew install --cask claude-code` with no brew detection | `setup_live.ex:35,112-131` |
| 8 | 7-day token expiry vs "you'll do this once" | `setup_live.ex:367-377`, `GO_TO_MARKET_ROADMAP.md` Clock 2 |
| 9 | "Approve them all" max-perms onboarding | `setup_live.ex:358-364` |
| 10, 18 | Wizard → terminal `on-duty`; home → headless chat | `setup_live.ex:225-229`, `status_live.ex:359-385`, `agent_runner.ex` |
| 11, 26 | `setup.md` 3-step vs actual 5-step wizard | `user-guide/setup.md`, `setup_live.ex:32` |
| 12–16 | Home screen overload / hidden chat agent / SVG viewer / hidden trust gate | `status_live.ex:713-809,91-97,538-658` |
| 19, 25 | `introduction.md` lists retired Advanced features | `user-guide/introduction.md:41`, `docs/COMMAND_SURFACE.md:79-88` |
| 20 | Phone tab in dock, unbuilt, decorative dialpad | `phone_live.ex`, `README.md:31` |
| 21 | Voice tab is a static explainer with no setting | `voice_live.ex` (58 lines) |
| 22 | Wallets 900-line personal-finance surface in dock | `wallets_live.ex` |
| 23 | Phone spend wired into Wallets | `wallets_live.ex:23-25` |
| 24 | Multiple independent shader systems | `status_live.ex:728`, `phone_live.ex:583`, `CODE_QUALITY_ROADMAP.md` Phase 1b |
| 30 | Security is the 7th settings tab | `settings_tabs.ex:9-17` |
| 31 | Refusal queue has no dock badge | `README.md:32`, `settings_tabs.ex` |
| 32 | No kill-switch UI | `daily-loop.md:53`, no UI surface |
| 34 | `auth_status` dead signal | `LEFTOVERS.md:98-112` |
| 48 | "Shipped = compiles" browser features | `LEFTOVERS.md:116-153` |
| 49 | Shared webview cache across builds | `BUILD.md:94` |
| 50–51 | Old Supabase function live; retired number in docs | `LEFTOVERS.md:50-95` |
| 52 | `bypassPermissions` with no UI disclosure | `agent_runner.ex:28-36` |

---

*End of review. The app in here is good. Let it out by removing the things that aren't it.*
