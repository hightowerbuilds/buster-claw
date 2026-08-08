> ## ARCHIVED 2026-08-08 — the mechanism was built, then deleted
>
> The extension loader, its five commands, the workspace `extensions/` directory
> and the model-attaches-a-part flow all shipped on 08-07 (`663c4ed`) and were
> **deleted on 08-08** along with the code they existed to serve.
>
> The reasoning is worth keeping. This roadmap was written to re-home Trading —
> its Part 0 says so in the first line, and its Part VII says plainly that
> extensions reduce *product* surface, not *code* surface. When the operator
> chose to delete Trading outright rather than re-home it, the mechanism lost
> its only user and became ~1,400 lines serving nothing. Keeping it would have
> been exactly the speculative breadth the critical review diagnosed, one layer
> up.
>
> **What is worth re-reading if extensions ever return:** the six locked
> decisions in Part II — above all **D1, that an extension is never executable
> code**, which is a fact about the BEAM having no code sandbox and does not
> expire. Part V's containment for agent-authored parts (disabled by default,
> install is gated, an unattended run may author but never install) was the
> hardest part to get right and would be worth lifting wholesale.
>
> Superseded by larger architectural moves the operator has planned.

---

# Extensions — the after-download surface

**How BusterClaw ships a capability it does not carry.** Extensions are the mechanism that
lets Trading — and everything like it — leave the core download, live on the website, and
arrive only when a user asks for it. This document defines what an extension *is*, what it
may never be, how it is distributed, and how a user builds one inside BusterClaw.

**Scoped 2026-08-07 · Status: SCOPED, nothing built · Successor question to
`BUSTERCLAW_CRITICAL_REVIEW.md` Phase 0.**

> ### The one-sentence version
>
> **An extension is a signed bundle of *data* — an MCP server declaration, a tool allowlist,
> prompt profiles, composition skills, guides, and a surface activation — interpreted by
> first-party code that already exists. An extension is never Elixir, never a `.beam`, never
> a LiveView, and can never grant itself a trust tier.**

> ### Why this document exists now
>
> The critical review's first finding is that BusterClaw has no center, and its first remedy
> is *subtraction* — put Trading, Phone, Voice, and Studio behind a Labs flag. **A flag hides
> a feature. An extension re-homes it.** The operator's call (08-07) is that Trading should
> not be hidden and forgotten; it should be **featured — as something you install after the
> download.** That is a stronger product than either shipping it or burying it, and it is a
> different mechanism than the one Phase 0 describes.

> ### Read this before you plan around it
>
> **Extensions do not solve the Trading *safety* finding.** They solve the *product story*
> finding. Moving Trading behind an install gate does not delete its 9,631 lines, does not
> remove a model from the financial data path, and does not make a model-mediated order
> submission deterministic. **Critical review Phase 5 survives this roadmap intact.** See
> [Part VII](#part-vii--what-this-does-not-solve).

---

## Contents

- [Part 0 — The short version](#part-0--the-short-version)
- [Part I — What the code already tells us](#part-i--what-the-code-already-tells-us)
- [Part II — Locked decisions](#part-ii--locked-decisions)
- [Part III — What an extension is](#part-iii--what-an-extension-is)
- [Part IV — Trust, signing, and distribution](#part-iv--trust-signing-and-distribution)
- [Part V — The self-build lane](#part-v--the-self-build-lane)
- [Part VI — The phases](#part-vi--the-phases)
- [Part VII — What this does not solve](#part-vii--what-this-does-not-solve)
- [Part VIII — Sequencing against the review and the launch](#part-viii--sequencing-against-the-review-and-the-launch)
- [Part IX — Risks](#part-ix--risks)
- [Part X — Open questions for the operator](#part-x--open-questions-for-the-operator)

---

## Part 0 — The short version

**Trading is already 85% an extension. Nobody noticed because the last 15% is 9,631 lines of
UI.**

`BusterClaw.Trading`'s own moduledoc says it: *"The app holds no broker credentials and speaks
no MCP — the operator's own agent does."* Trading is not an integration BusterClaw built. It
is **a URL, a tool allowlist, and three prompts**, wrapped in a very large LiveView.

That means the extension boundary is not a design we invent. **It is a seam already present in
the code**, and this roadmap's job is to name it, formalize it, and make it re-usable.

**The plan in five moves:**

1. **Extract the Trading manifest** — prove the seam by describing the existing Trading surface
   as pure data, with zero behavior change.
2. **Build the loader** — read that manifest from disk, versioned and hashed, using the *same*
   mechanism the review's Phase 3 demands for seeded workspace defaults. **Build one, not two.**
3. **Gate the surface** — the Trading route, dock item, conversation kinds, and catalog entries
   appear only when the extension is installed. Fresh install: no Trading.
4. **Publish it** — a signed `.bcx` on busterclaw.lol, verified against a pinned publisher key
   before a byte is read.
5. **Open the self-build lane** — build guides in the Manual, an `extension_*` command family,
   and BusterClaw's own agent authoring a local unsigned extension that **cannot install
   itself** without a durable operator approval.

---

## Part I — What the code already tells us

### Trading's real anatomy

| Component | Where it lives | Lines | Extension-shaped? |
|---|---|---|---|
| MCP server URL | `trading.ex` `@mcp_url` | 1 | **Yes — pure data** |
| Read-tool allowlist | `trading.ex` `@read_tools` | 11 | **Yes — pure data** |
| Cancel-tool allowlist | `trading.ex` `@cancel_tools` | 1 | **Yes — pure data** |
| System prompts / profiles | `trading.ex`, `trading/chat_profile.ex` | ~200 | **Yes — prose** |
| Conversation kinds (`robinhood`, `chartbuild`) | `trading.ex` `@tab_kinds` | 1 | **Yes — enum** |
| Catalog entries (finance + portfolio) | `commands/catalog/finance.ex` | 8 entries | **Yes — declarative** |
| Dock item + route | `layouts.ex`, `router.ex` | 2 | **Yes — activation** |
| Explore tutorial + `claude mcp add` guide | `explore_panel.ex` | ~100 | **Yes — guide content** |
| **`TradingLive`** | `live/trading_live.ex` | **2,575** | **No — first-party code** |
| **`Trading` context** | `trading.ex` | **1,374** | **No — first-party code** |
| **Account/order/lookup/tab components** | `components/trading_*.ex` | **1,279** | **No — first-party code** |
| **`TradingView`** | `live/trading_view.ex` | **473** | **No — first-party code** |
| **`TradingOrder`** | `trading_order.ex` | **395** | **No — first-party code** |
| **Tests** | `test/**/trading*` | **3,535** | **No — first-party code** |

**Totals: ~325 lines of data and prose. ~9,631 lines of code and tests.**

> **The finding.** The part of Trading that makes it *Robinhood* is small, declarative, and
> movable. The part that makes it *large* is UI, and UI cannot be shipped as a download into a
> BEAM app without either a code sandbox (which does not exist) or a rewrite. **This asymmetry
> determines the entire design.**

### The extension points that already exist

BusterClaw has shipped four runtime-addable mechanisms. None of them is code:

| Mechanism | Substrate | The rule it already enforces |
|---|---|---|
| **Skills** (`skills.ex`) | Markdown + frontmatter in `<workspace>/skills/` | *"Every step is re-authorised through `Commands.call/3`, so a skill can never exceed its caller's trust."* |
| **Jobs** (`jobs.ex`) | Markdown descriptions, discovered at runtime | File-first, git-diffable, operator-editable |
| **Trusted senders** | Workspace list files | Operator-owned, load-time validated |
| **MCP servers** | Operator's own agent config | Out-of-process; separate auth; `--strict-mcp-config` scopes the run |

> **Skills are the prototype of this entire roadmap.** They already prove the model: a
> runtime-addable capability, declared as data, validated at load, executed only through the
> single dispatch choke point, structurally incapable of exceeding the caller's trust. **An
> extension is a skill that also brings an MCP server, prompts, guides, and a surface.**

### What is missing

- **No feature-flag mechanism of any kind.** `Settings` is a plain key/value store with one
  named key (`onboarding`). There is no `Labs`, no capability gate, no per-surface enable. The
  review's Phase 0 flag does not exist yet.
- **No seed versioning.** `maybe_write` never overwrites (review Phase 3). Any extension system
  built before that mechanism exists will inherit the same permanent-staleness bug, **times the
  number of extensions**.

---

## Part II — Locked decisions

These are constraints, not preferences. Each one exists because violating it breaks a specific
guarantee the product already makes.

### D1 — An extension is never executable code

**No `.beam`, no `.ex`, no NIF, no port binary, no JavaScript that reaches the Tauri bridge.**

The BEAM has no code sandbox. A loaded module runs with the full authority of the node:
`Vault` keychain reads, the SQLite database, every API token, the Tauri command surface, the
workspace, and the browser ACL. There is no `--restricted` mode, no capability-scoped code
loading, and writing one is a research project, not a feature.

> A downloaded extension that could run Elixir would make **every other control in this
> codebase decorative** — the policy engine, the tier system, the URL guard, Sentinel, the
> ACL lockstep test. One `.beam` bypasses all of it. This decision is not revisitable.

### D2 — New capability arrives out-of-process or not at all

An extension that needs a capability the command catalog does not have declares an **MCP
server**. That server is a separate process, with its own authentication, its own network
identity, and its own failure domain — and BusterClaw already treats `:mcp` as a **distinct
caller tier**.

This is exactly, and not coincidentally, how Robinhood already works.

### D3 — An extension may never grant itself a tier

Everything an extension declares is subject to the existing catalog policy and the existing
caller trust. Specifically:

- Extension-declared commands are **compositions of native commands** and inherit the Skills
  rule — re-authorised per step, never exceeding the caller.
- Extension-declared MCP tools are called as the `:mcp` caller, **never as `:trusted`**.
- An extension may **request** that an action be gated. It may never request that one be
  un-gated. Tightening is allowed; loosening is not — the same asymmetry `policy.md` already
  has.

### D4 — Extension UI is host-owned or sandboxed, never LiveView

Two lanes, and an extension picks one:

| Lane | Mechanism | Who can use it |
|---|---|---|
| **Host surface activation** | The extension names a surface the binary already ships (`trading`, a generic conversation surface, a settings panel). The code is first-party; the extension only turns it on and configures it. | **First-party extensions only** |
| **Sandboxed page** | Self-contained HTML rendered in the existing in-app browser webview — which already has CSP and is **isolated from Tauri commands**. | **Any extension** |

> BusterClaw already built a sandbox for untrusted UI and called it a browser. Third-party
> extension UI belongs there, not in the Phoenix render tree.

### D5 — Versioning is the same mechanism as workspace seeds

An extension manifest carries **asset ID, schema version, shipped hash, installed hash, and
ownership class** — the identical shape the critical review's Phase 3 specifies for seeded
workspace defaults. **These are one mechanism with two callers.** Building a second one is how
you get a second permanent-staleness bug.

### D6 — First-party distribution only, for now

BusterClaw publishes and signs every downloadable extension. **There is no third-party
registry, no unsigned public download, and no submission flow in this roadmap.**

Hosting other people's extensions makes us a review authority — an app store — with a
disclosure obligation, a revocation obligation, and a supply-chain attack surface pointed
directly at a product whose thesis is trust. That is a company-scale commitment, not a phase.

---

## Part III — What an extension is

### The bundle

A `.bcx` is a **signed tarball** with a fixed layout. No path outside the layout is read.

```
trading-robinhood-1.0.0.bcx
├── manifest.toml          # the whole contract — see below
├── SIGNATURE              # detached signature over the canonical digest
├── prompts/               # markdown system prompts and profiles
│   ├── portfolio.md
│   └── order-proposal.md
├── skills/                # composition skills, identical to workspace skills
│   └── daily-positions.md
├── guides/                # Manual/Explore content, markdown
│   ├── SETUP.md
│   └── ABOUT.md
└── pages/                 # optional sandboxed HTML, browser-webview only
    └── panel.html
```

### The manifest

```toml
[extension]
id           = "trading-robinhood"      # [a-z0-9-], globally unique, immutable
version      = "1.0.0"
schema       = 1                        # manifest schema version
name         = "Robinhood Trading"
summary      = "Read your Robinhood positions and propose orders in a pinned conversation."
publisher    = "busterclaw"             # must match the verified signing key
requires_app = ">= 0.2.0"

[capability]
# Declared up front, shown verbatim on the install screen. This IS the consent screen.
network      = ["agent.robinhood.com"]  # hosts the MCP server may reach
reads        = ["portfolio", "positions", "orders"]
writes       = ["order_submit", "order_cancel"]   # every write is gated, no exceptions
money        = true                     # forces the strongest install warning
external_auth = "The operator runs `claude mcp login robinhood` themselves. BusterClaw never sees the credential."

[[mcp]]
name         = "robinhood"
transport    = "http"
url          = "https://agent.robinhood.com/mcp/trading"
strict       = true                     # --strict-mcp-config; no other server leaks in
allow_tools  = ["mcp__robinhood__get_accounts", "mcp__robinhood__get_portfolio", "…"]
gated_tools  = ["mcp__robinhood__cancel_equity_order"]

[surface]
kind         = "host"                   # host | page  (D4)
host_surface = "trading"                # a surface the binary ships; first-party only
dock_label   = "Trading"
dock_icon    = "hero-chart-bar"
route        = "/trading"

[conversations]
kinds        = ["robinhood", "chartbuild"]

[[commands]]                            # compositions only — never new native capability
name         = "portfolio_today"
tier         = "safe"
steps        = [{ command = "portfolio_history", args = { range = "1D" } }]
```

### The load contract

Every extension passes the same gate before a single declaration takes effect:

1. **Verify the signature** against a pinned publisher key — *before parsing anything else*.
2. **Validate the manifest** against the schema. Unknown keys are a **hard error**, not a
   warning; a manifest that means something we do not understand is a manifest we cannot
   consent to.
3. **Check `requires_app`** against the running version.
4. **Reject any declaration that widens trust** — an un-gate request, a `:trusted` caller
   claim, a native command name collision, a path outside the bundle layout.
5. **Show the operator the capability block verbatim** and require explicit approval.
6. **Record the install** as a Sentinel event with the bundle digest.

> **Steps 1–4 are mechanical and total.** If a manifest reaches step 5, every claim on the
> install screen is one the loader has already proven it will enforce. **The consent screen
> shows what the code guarantees, not what the publisher wrote.**

---

## Part IV — Trust, signing, and distribution

### Three channels, three trust levels

| Channel | Signed by | Auto-updates? | May use host surfaces? | Install friction |
|---|---|---|---|---|
| **Bundled** — in the DMG | The app signature itself | With the app | Yes | None; present at first launch |
| **Downloaded** — busterclaw.lol | The BusterClaw extension key | Yes, on operator consent | Yes | Capability screen + approval |
| **Local** — self-built or agent-authored | **Unsigned** | **Never** | **No — sandboxed page only** | Capability screen + **durable gated approval** |

### Signing

- A **dedicated extension signing key**, not the Developer ID cert. Different lifetime,
  different revocation story, different blast radius. Apple signs *the app*; this key signs
  *content the app trusts*.
- The **public key is compiled into the binary**. An extension's trust comes from the release
  it was verified against, not from a network lookup that can be intercepted.
- **Verify before parse.** The signature check happens on the raw bytes; the TOML parser never
  sees an unverified file. A parser bug behind a signature check is a bug; in front of one it
  is an RCE.
- **Revocation:** a compiled-in deny list of `{id, version}` pairs, shipped with app updates.
  Not a network CRL — a network revocation check is a network dependency on a local-first app,
  and it fails open exactly when you need it.

### The website

The download page needs, at minimum:

- Per-extension: name, publisher, **the capability block rendered from the actual manifest**,
  version, app-version requirement, size, digest, changelog.
- **The capability text on the website and the capability screen in the app are generated from
  the same manifest.** If they can drift, they will, and the website will be the one that lies.
- An explicit statement of what BusterClaw does *not* do — for Trading: *"BusterClaw never sees
  your broker credentials. You authenticate Robinhood to your own Claude installation."*

> **Blocked on `LAUNCH_ROADMAP.md` G-2.** There is no signing infrastructure until the
> Developer ID certificate exists, and no download page until the site does. Extensions cannot
> ship publicly before the app does.

---

## Part V — The self-build lane

**This is the most interesting half of the idea and the most dangerous.**

The pitch: *you describe a capability, BusterClaw's agent writes the extension, you review it,
you install it.* That is the product's own thesis pointed at itself — a terminal agent with a
durable queue and receipts, building you a capability, with a full audit trail of how it did.

The danger: **an agent authoring a capability grant.** An extension manifest is a
consent-shaped document. An agent that can write one and install one has written itself a
permission slip.

### Containment

| Control | Rule |
|---|---|
| **Unsigned forever** | An agent-authored extension is never signed and never gains signed-channel privileges. |
| **Sandboxed UI only** | `surface.kind = "page"` only. A local extension may never activate a host surface (D4). |
| **Install is a gated action** | `extension_install` is `:gated` for every caller. It uses the **durable approval workflow from critical review Phase 1.1** — pending → approved → executed once, surviving restart. **This roadmap must not ship before that one.** |
| **The agent cannot approve its own work** | The approving caller must be `:trusted` and interactive. An unattended Dispatcher run may *author* an extension; it may never install one. |
| **Diff before consent** | Installing an update to a local extension shows a manifest diff, with capability changes highlighted. A capability that grew is the headline, not a footnote. |

### Build guides

Shipped in the Manual and Explore, authored as the reference-skill kind that already exists:

1. **What an extension can and cannot do** — D1–D6 in user language. Lead with the limits;
   they are the feature.
2. **Wrapping an MCP server** — the common case, and exactly the Robinhood shape.
3. **Composition-only extensions** — no MCP at all, just skills and prompts over the native
   catalog. **This is the safest kind and should be the first example.**
4. **Sandboxed panels** — what HTML gets, what it does not, why it cannot reach Tauri.
5. **Publishing** — what would have to be true for an extension to be signed, stated honestly
   as *not currently open* (D6).

### The commands

A small family, all through the single dispatch path:

| Command | Tier | Notes |
|---|---|---|
| `extension_list` | `:safe` | Installed extensions, versions, capability summary |
| `extension_show` | `:safe` | One manifest, rendered |
| `extension_scaffold` | `:restricted` | Write a manifest skeleton into the workspace |
| `extension_validate` | `:safe` | Run the full load contract **without installing** — the agent's feedback loop |
| `extension_install` | **`:gated`** | Durable approval required; never available to an unattended run |
| `extension_remove` | `:restricted` | Deactivate + retain audit history |

> `extension_validate` is what makes the self-build lane actually work: the agent can iterate
> against the **real** validator, so the guide never drifts from the loader. **The build guide
> is the validator's error messages.**

---

## Part VI — The phases

> **Operating rule inherited from the critical review:** no phase closes on written code alone.
> Implementation + tests + exercised proof.

### Phase 0 — Prove the seam (no loader, no download)

**Priority: P1. Do this before committing to any of the rest.**

- [ ] Extract every declarative part of Trading — MCP URL, both tool allowlists, prompt
      profiles, conversation kinds, dock/route entry, the 8 catalog entries — into a
      **compile-time manifest struct** consumed by the existing code. No file loading, no
      signature, no install. Pure refactor.
- [ ] Prove behavior is byte-identical: the full existing Trading suite (3,535 lines) passes
      unchanged.
- [ ] Write the manifest schema against **what Trading actually needed**, not what we imagine a
      general extension needs.
- [ ] **Write down what did not fit.** Every Trading behavior that resisted the manifest is a
      finding — either the schema is wrong or that behavior is genuinely host code.

**Exit:** The Trading manifest exists as data, in-tree, and the schema was derived from a real
surface rather than designed in the abstract.

> **If Phase 0 is ugly — if half of Trading resists the manifest — stop.** That is the
> experiment reporting that the seam is not where we thought it was, and it is much cheaper to
> learn here than after the loader, the signing key, and the download page exist.

### Phase 1 — The gate (still no download)

**Priority: P1. This is what actually delivers the review's Phase 0 subtraction.**

- [ ] Build the **capability gate** — the mechanism that does not exist today. One store, one
      API, per-surface. This is the thing the review called a "Labs flag," generalized exactly
      one notch.
- [ ] Make the Trading dock item, route, conversation kinds, and catalog entries **conditional
      on the Trading manifest being active**. A disabled surface must be absent, not hidden:
      the route does not resolve, the catalog does not contain the entries, the agent cannot
      call them.
- [ ] **Default off on a fresh install.** Existing installs with Trading data keep it on
      (migration, not surprise removal).
- [ ] Add an **Extensions panel** in Settings: what is installed, what it can do, an off switch.
- [ ] Test the negative case hard: with Trading off, assert the route 404s, the catalog lacks
      the entries, an agent request for a Robinhood tool is refused, and the dock has no
      Trading item.

**Exit:** A fresh install has no Trading. Turning it on is one screen. **The review's Phase 0
subtraction is delivered for Trading — for real, not by hiding a link.**

### Phase 2 — The loader

**Priority: P2. Blocked on critical review Phase 3** (the shared seed-manifest mechanism, D5).

- [ ] Read manifests from `<workspace>/.buster-claw/extensions/<id>/`, versioned and hashed
      through the **shared** seed-manifest mechanism.
- [ ] Implement the six-step load contract, with steps 2–4 total and mechanical.
- [ ] Build the **capability consent screen**, rendered from the manifest, with the
      money/writes cases visually distinct.
- [ ] Ship Trading as a **bundled** extension loaded through this path — same bytes, same
      behavior, now arriving via the loader instead of the compiler.
- [ ] Adversarial fixture suite (this is the interesting test work): manifests that claim
      `:trusted`, request an un-gate, collide with a native command name, path-escape the
      bundle, declare an undeclared network host, exceed `requires_app`, carry unknown keys,
      lie about their digest, or nest to exhaust the parser.

**Exit:** Trading loads from a manifest on disk. Every hostile manifest in the fixture suite
fails closed with an actionable error and a Sentinel record.

### Phase 3 — The self-build lane

**Priority: P2. Blocked on critical review Phase 1.1** (durable approvals — `extension_install`
has nowhere safe to live without it).

- [ ] The six `extension_*` commands, with `extension_install` gated through the durable
      approval workflow.
- [ ] `extension_validate` runs the **real** loader path in dry-run.
- [ ] The five build guides, authored as reference skills.
- [ ] The local-extension containment rules (Part V) enforced in the loader, not the UI.
- [ ] End-to-end proof: **have the agent build one.** A composition-only extension, authored by
      BusterClaw's own agent from the guide, validated, presented for approval, installed,
      used. Record it — that walk is the feature's best demo and its best test.
- [ ] Assert an unattended Dispatcher run **cannot** install an extension it just authored.

**Exit:** A user can ask BusterClaw for a capability and get a working local extension, and no
path exists by which the agent grants itself one.

### Phase 4 — Distribution

**Priority: P2. Blocked on `LAUNCH_ROADMAP.md` G-2** (no cert, no signing) **and the website.**

- [ ] Generate the extension signing key; document its custody, backup, and rotation **before**
      it signs anything.
- [ ] Compile the public key and the revocation deny-list into the binary.
- [ ] Verify-before-parse on raw bytes, with a test that a corrupted or re-signed bundle is
      rejected before the TOML parser is reached.
- [ ] Download, verify, install, and update flows in-app, each with explicit consent.
- [ ] The website extension pages, **with capability text generated from the same manifest** the
      app reads.
- [ ] Publish Trading as the first downloadable extension.
- [ ] Prove the failure cases against a real server: tampered bundle, wrong key, revoked
      version, `requires_app` too new, network failure mid-download, disk full mid-install,
      process death mid-install.

**Exit:** A user downloads Trading from busterclaw.lol into a clean packaged build, and every
tamper case is rejected with an error a human can act on.

### Phase 5 — Second extension

**Priority: P3. The honesty check.**

- [ ] Move **one more** surface to an extension — the review names Phone, Voice, Sound Studio.
      Sound Studio is the best candidate: large, self-contained, and unrelated to the core
      promise.
- [ ] Every schema change the second extension forces is a **Phase 0 design miss**, and gets
      recorded as one.

> **One extension is a refactor. Two is an architecture.** Until a second surface goes through
> this path, the manifest schema is a description of Trading wearing a general-purpose name.

---

## Part VII — What this does not solve

**Be blunt about this. The failure mode is believing the extension system closed findings it
did not touch.**

| Belief | Reality |
|---|---|
| *"Trading is behind an extension, so Phase 5 of the review is handled."* | **No.** A model still transcribes account balances into permanent history. The final order hop is still a Claude run told not to double-submit. Account identity is still last-four. **Every word of review Phase 5 still applies** — to an extension instead of a tab. |
| *"The codebase got smaller."* | **No.** Phase 1 makes Trading *absent from the product*; the 9,631 lines still ship in the binary and still need maintenance, tests, and Dialyzer passes. Extensions reduce **product surface**, not **code surface**. Review Phase 4's extraction work is untouched. |
| *"Users can extend BusterClaw however they want."* | **No, by design.** D1 says no code. A capability the native catalog and MCP cannot express **cannot be an extension.** Say this in the first paragraph of the build guide, not the last. |
| *"This replaces the Labs flag."* | **Only for Trading, and only after Phase 1.** Phone, Voice, and Studio still need the review's cheap flag in the meantime — see below. |
| *"Extensions make the product story simpler."* | **Only if we hold D6.** A third-party registry reintroduces exactly the breadth problem the review diagnosed, one rung up the stack. |

---

## Part VIII — Sequencing against the review and the launch

### The tension, stated plainly

The critical review's operating rule #1 says **freeze top-level scope: no new command family or
subsystem until Phases 0–3 are complete.** This roadmap proposes a new subsystem and a new
command family. **It is in tension with the rule, and pretending otherwise would be exactly the
habit the review diagnosed.**

**The resolution:** Phase 0 of the review needs Trading gone from the default product *now*, and
that costs a day. This roadmap's Phase 2–4 cost weeks. **They must not be the same decision.**

| Need | Cheapest mechanism | When |
|---|---|---|
| Trading, Phone, Voice, Studio out of the default product | **The review's Labs flag** — one settings key | **Now.** Do not wait for extensions. |
| Trading re-homed as a featured after-download install | **This roadmap, Phases 0–1** | After the review's Phase 0 and 1 |
| Trading downloadable from the website | **Phases 2–4** | After review Phase 3 + LAUNCH G-2 |

> **The Labs flag ships first and this roadmap subsumes it.** Extension Phase 1's capability
> gate *is* the Labs flag with one more notch of generality — so building the flag now is not
> throwaway work, it is Phase 1 arriving early for one caller.

### Hard dependencies

| This roadmap's phase | Blocked on | Why |
|---|---|---|
| Phase 2 (loader) | **Review Phase 3** — seed manifest | D5: one versioning mechanism, not two |
| Phase 3 (self-build) | **Review Phase 1.1** — durable approvals | `extension_install` is gated; a stub approval store cannot hold it |
| Phase 4 (distribution) | **LAUNCH G-2** — Developer ID cert; the website | No signing infrastructure, no download page |
| All phases | **Review Phase 2** — the caller×command matrix | An extension adds catalog entries; adding them to an unproven matrix multiplies the review's exact finding |

### Where this lands in the milestones

| Milestone | Extension state |
|---|---|
| **M0 — Honest internal build** | Labs flag hides Trading. No extension system. |
| **M1 — Controlled private beta** | Extension Phases 0–1. Trading is a gated surface, off by default, bundled. |
| **M2 — Focused release candidate** | Phases 2–3. Loader + self-build, bundled and local only. |
| **M3 — Public download** | Phase 4. Trading downloadable from busterclaw.lol. |

---

## Part IX — Risks

| Risk | Why it is real here | Containment |
|---|---|---|
| **The schema is Trading-shaped** | It is derived from exactly one surface. Every general-purpose framework built from one example is wrong in ways only the second example reveals. | Phase 5 exists for this. Do not publish a public schema before a second extension proves it. |
| **Verify-before-parse gets inverted** | The natural refactor — "parse the manifest to find the signature" — is an RCE. It will look like a cleanup in a diff. | A test that a bundle with valid TOML and an invalid signature never reaches the parser. Name the test so a reviewer sees the intent. |
| **The capability screen becomes a click-through** | Every consent screen trends toward one. `money = true` on a Trading install must not look like a cookie banner. | Distinct treatment for `writes` and `money`. Show the diff on updates, not the full list. |
| **Agent-authored extensions become a self-grant path** | An agent that writes manifests writes permission slips. This is the single largest new attack surface in the roadmap. | Part V containment, enforced in the loader. The unattended-install negative test is the load-bearing one. |
| **Extensions become the new sprawl** | "Put it in an extension" is the same yes that produced the review's finding, one layer down. | D6. First-party only. Every extension still costs a maintained manifest, guide, and test suite. |
| **The website and the app disagree** | The review already caught this exact class of drift — README says Intel-only, CI builds two architectures. | Generate both from one manifest. Add it to the docs-drift check. |
| **Bundled Trading rots** | Once Trading is off by default, its tests still pass while nobody looks at it. Green and dead are indistinguishable — which is the empty-DMG lesson. | A packaged smoke that installs and opens Trading. If nobody will maintain that, that is an argument for review Phase 5 option A. |

---

## Part X — Open questions for the operator

**These change the work materially and are yours to answer.**

1. **Does Trading stay first-party forever?** D4 says only first-party extensions may activate
   a host surface, and Trading's 9,631 lines mean it must. That is fine — but it means "Trading
   is an extension" is *partly a packaging statement*. **Is that the honest framing you want on
   the website**, or should the long-term goal be rewriting Trading's UI as a sandboxed page so
   the claim is unqualified?

2. **What is the second extension?** Phase 5 assumes Sound Studio. Phone is the other candidate
   — it is 1,275 lines for a decorative dialpad, but BusterPhone is the paywall, and moving the
   money leg behind an install gate is a business decision, not an architecture one.

3. **Is the self-build lane a headline feature or a power-user door?** If headline, the build
   guides and `extension_validate` need real polish and Phase 3 grows. If power-user, Phase 3
   is a weekend and the guides live in the Manual only. **This is the biggest scope lever in the
   document.**

4. **Do we hold D6 permanently?** First-party-only is the right call for v1 and I would not
   revisit it before M3. But if the long-term vision includes other people publishing
   extensions, some decisions here get more expensive to reverse later — the signing key
   hierarchy and the revocation design in particular.

---

> **The test of this roadmap:** a new user downloads BusterClaw, opens it, and sees a local
> runtime that gives a terminal agent a durable work queue, controlled tools, and verifiable
> receipts — **and nothing about stocks**. Then, because they want it, they install Trading in
> one screen that tells them exactly what it can reach and what it can do. **Trading stops
> being evidence that BusterClaw is unfocused and becomes evidence that it is extensible.**
