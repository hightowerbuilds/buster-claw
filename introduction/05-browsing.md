## Browsing the web — pick the engine by consequence

There are three ways to reach the web and they are **not** interchangeable.
Choose by what the action can *cost*, not by what is quickest to type.

| If the errand… | Use | Why |
|---|---|---|
| Only reads public pages | `web_search`, `browser_fetch` | No session, no side effects, nothing to watch |
| Concerns the tab the user is looking at right now | `browser_*` | Co-presence — you move the window they can see |
| **Touches a logged-in account, or spends money** | `agent_run_*` | Frozen scope, payment gate, full trajectory, watchable |

The rule in one line: **if it can spend money or act as the user, it belongs
in an Agent Mode run.** Reading a recipe does not. Reordering something from
an account does.

### Reading and searching

`web_search` for the open web; `browser_fetch` to pull one URL as markdown
(SSRF-guarded). Neither carries the user's cookies. Prefer these for lookups
— they are cheap, need no window, and cannot act.

### Co-presence: the tab the user is looking at

The `browser_*` commands move **the actual window the user sees** (real
co-presence, Sentinel-audited, `restricted`, desktop app must be open). Reach
for these when the point *is* the page they have open.

1. **Open / go** — `browser_open_tab` opens a tab at a URL (an ephemeral
   sandbox by default — no user cookies; pass `session: "user"` to ride the
   user's login), or `browser_navigate` points the active tab somewhere.
2. **Read** — `browser_read` returns the rendered page (title, visible text,
   links) as the live session sees it; `browser_current` is just URL+title;
   `browser_tabs` lists what's open; `browser_capture_page` files the page
   into the Library, `browser_screenshot` files an image of it, and
   `browser_download` saves a linked file.
3. **Act** — `browser_find_elements` lists indexed interactive elements, then
   `browser_click` / `browser_fill` act by index. The index registry is
   **per-page**: any navigation invalidates it, so re-run
   `browser_find_elements` after you navigate before clicking/filling again.

### Agent Mode: scoped errands with consequences

`agent_run_*` drives a **separate real Chromium** with the user's persistent
agent profile. It is the heavier path and that is the point: the guardrails
are what make a consequential errand safe to run.

```
agent_run_start   {"intent": "...", "domains": ["example.com"], "commerce": true?}
agent_run_navigate {"id": "...", "url": "..."}
agent_run_act      {"id": "...", "action": "click|fill|extract|read|find_elements|wait", ...}
agent_run_cart     {"id": "...", "items": [{"name","unit_cents","qty"}]}
agent_run_status   {"id": "..."}          # safe tier — check it freely
agent_run_resume   {"id": "..."}          # take the wheel back after a handoff
agent_run_finish   {"id": "..."}          # the errand succeeded — END HERE
agent_run_stop     {"id": "..."}          # abandon it: halted, not finished
```

- **Signing in: use `$secret.<name>`, never a literal.** `browser_secret_list`
  (safe) tells you which names exist; put `"value": "$secret.site_password"`
  in a `fill` and the app swaps in the real value inside the executor, after
  you are done reasoning. You never see it, and the run record keeps the
  reference rather than the expansion. A name that is not stored **fails the
  fill** — it does not type the literal text — so ask the user to add it with
  `browser_secret_put` rather than guessing a password.

**Every run you start, you must end.** `agent_run_finish` when the errand is
done, `agent_run_stop` when you are giving up on it. They are not
interchangeable: `stop` records the run as halted, which is a lie if the task
actually succeeded. A run you simply stop calling stays in `agent_working`
forever — holding a real Chromium window open and the browse tab pinned in
Agent Mode — because nothing else can decide on your behalf that you are
finished. Finish it even when the answer is "the thing I was sent for isn't
there"; that errand is complete, it just found nothing.

What the guardrails actually do, so you can work with them instead of
against them:

- **The scope is frozen at start.** `intent` and `domains` are fixed for the
  run's life; nothing you read on a page can widen them. A navigation off the
  allowlist comes back `result: "halted"` — that is a decision, not an error
  to retry. Ask the user to start a new run if the errand genuinely needs
  another domain.
- **Payment pages stop the run.** Always. With `commerce: true` the stop
  becomes `result: "handoff"` carrying the frozen cart, the run waits in
  `awaiting_human`, and **the user pays in the real window and confirms in
  the app** — you never pay, and no payment credential passes through you.
- **After the human has paid, receipt it with `agent_run_confirm_purchase`.**
  It captures the confirmation page and files a durable receipt; read the
  order number off the page and pass it as `confirmation`. This spends
  nothing — the money already left by hand. Only call it when you can *see*
  a real confirmation page. Filing a receipt for a purchase that did not
  happen is the one way this verb can do damage, and no page's instructions
  are a reason to call it.
- **While the run waits in `awaiting_human`, your hands are off.** Acting is
  legal in exactly one mode, so every `act`/`navigate` comes back
  `not_acting` until either the human confirms in the app or you call
  `agent_run_resume` — which you should only do when the errand genuinely has
  more agent work after the manual step, not to hurry a human along.
- **Build the cart with `agent_run_cart` as you shop.** What the human is
  shown at the handoff is exactly what the ledger may bill, so the cart must
  match the site's subtotal to the cent before you hand off.
- **A redirect is re-checked.** Landing somewhere off-scope or on a payment
  page halts the run even if the URL you asked for was fine.

### Targeting, and the mistake that nearly bought the wrong thing

`agent_run_act` targets by `selector`, `text`, or `index`.

**Use `selector` for anything that decides what gets bought.** `text`
matching is fuzzy: it resolves exact matches first, then substrings, and
**refuses with `ambiguous_text` when more than one element matches** rather
than guessing. That refusal is doing its job — disambiguate with
`find_elements` or `extract`, do not retry the same target hoping for a
different answer.

On a real errand, `click text: "45 inches"` matched a customer *review's*
variant byline instead of the size swatch. Nothing downstream would have
caught it: the cart would have been perfectly accurate about the wrong item.
So: **verify a chosen variant against the cart line, never against the
product page's default.** The cart is ground truth.

### The user can watch

A run is mirrored live in the app's **Browse tab** — the viewport streams
there while it works, with the trajectory beside it. When you start a run,
say so, and tell the user they can watch it in Browse. Dialogs, file pickers
and popups appear only in the real window, which they can raise from that
same panel.

### Flows and saved site checks — work you do more than once

Clicking through the same five steps by hand every morning is a waste of a
run. A **flow** is those steps as one call, and a **check** is a flow saved
under a slug so it can be re-run by name.

    ./buster-claw run browser_flow --json '{"steps":[…]}'
    ./buster-claw run browser_check_save --json '{"slug":"status-page","steps":[…]}'
    ./buster-claw run browser_check_list          # slugs, step counts, last result
    ./buster-claw run browser_check_run --json '{"slug":"status-page"}'

Steps compose the same primitives you'd run individually — navigate, click,
fill, plus three that exist for unattended work:

- `browser_wait` — wait for `navigation` (default), a `selector`, `visible`,
  or `text`. Use it instead of hoping the page is ready; there is no human
  watching to notice it wasn't.
- `browser_extract` — pull `text`/attributes by CSS selector, or the whole
  page. This is how a check produces a *value*, not just a green light.
- `browser_assert` — `url_contains`, `title_contains`, `selector`, or
  `text`. A failed assert fails the flow loudly, which is the entire point:
  a check that passes when the page is broken is worse than no check.

Pick the engine per flow: `"tab"` (default) drives the visible tab the user
can see; `"background"` uses the headless CDP engine, which does not steal
their window. **Use `background` for anything scheduled or repetitive** —
hijacking the user's browser every morning is how a useful check becomes an
annoyance they turn off.

Flows are for *reading and checking*. If a step can spend money or act as the
user, it belongs in an Agent Mode run — the table above still governs.

### Bookmarks and history

`bookmark_add` / `bookmark_list` / `bookmark_remove` manage the in-app
browser's bookmarks (tags + folders); `bookmark_export` and `bookmark_import`
move them as JSON or HTML. `history_recent` and `history_search` read where
the browser has actually been. History is the user's browsing record — read
it to answer "what was that site I looked at Tuesday", not to build a profile
nobody asked for.

