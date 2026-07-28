# Browser Control — First Field Test

**Date:** 2026-07-25
**Run:** `scope_1H` (Agent Mode, `commerce: true`, scope `["amazon.com"]`)
**Task:** Buy 45" durable shoelaces and superglue on Amazon; cart in, human pays.
**Outcome:** Order placed successfully, $23.71. Four defects found.

> **Archived 07-28** as `07-25-26-browser-control-field-test.md` (originally
> `BROWSER_CONTROL_FIELD_TEST_07-25.md`). All four findings were fixed on 07-25
> and are recorded in the browser-engine roadmap's own "Field test 07-25"
> section. Kept for the reasoning, not as open work.

---

## 1. Summary

This was the first exercise of the Phase 0–6 browser-control stack against a real,
adversarial, logged-in commercial site rather than a test fixture. **The errand
succeeded.** The agent searched, compared products, selected a size variant, added two
items to the operator's real Amazon cart, froze a cart whose total matched Amazon's
subtotal to the cent, and handed off. The operator paid. Both items appear in order
history.

The stack's *pure* components — Scope, Trajectory, Cart, Egress reporting — behaved
exactly as designed. The defects are all at the **wiring layer**: capabilities that
exist, are tested, and are correct in isolation, but are not connected to the surface
the agent actually calls. The most serious of these means **the payment gate does not
fire on Amazon**.

One near-miss is worth stating plainly: the agent came close to ordering the wrong
product (54" laces instead of 45"). It was caught by verification, not by the gate
system. See Finding 4.

---

## 2. What was exercised

| Capability | Result |
|---|---|
| `agent_run_start` (commerce mode, frozen scope) | ✅ worked |
| Navigation under scope | ✅ worked, all in-scope |
| `extract` with CSS selectors | ✅ worked, precise |
| `find_elements` | ❌ ignores selector (Finding 5) |
| `click` / `fill` by `selector` | ✅ worked, precise |
| `click` by `text` | ⚠️ fuzzy-match hazard (Finding 4) |
| `agent_run_cart` (freeze) | ✅ worked, cent-exact |
| Payment gate → `awaiting_human` | ❌ did not fire (Finding 1) |
| `Commerce.confirm_purchase` → ledger | ❌ unreachable (Finding 2) |
| `$secret.<name>` resolution | ❌ no store wired (Finding 3) |
| Egress reporting | ✅ worked, honest receipt |

**Final run telemetry:** 66 steps, 65 ok / 1 error (a malformed JSON body from the
caller — not a stack defect), 89,828 bytes egressed across 41 steps, all at level
`:full`, 0 redactions, 0 secrets resolved. Final mode: `stopped` — *not* `done`.

---

## 3. Findings

### Finding 1 — Payment gate fails open on Amazon — **HIGH**

**Where:** `lib/buster_claw/browser_control/scope.ex:56`

The payment-path heuristic is:

```elixir
@payment_path_re ~r{(^|/)(checkout|payment|payments|billing|pay|purchase|place-?order|complete-?order)(/|$|\?)}i
```

Amazon's checkout is `/gp/buy/spc/handlers/display.html`. Its payment-selection step is
`/gp/buy/payselect/handlers/display.html`. Neither matches. Ported verbatim and tested:

```
no     /gp/buy/spc/handlers/display.html         ← Amazon checkout
no     /gp/buy/payselect/handlers/display.html   ← Amazon payment selection
no     /gp/cart/view.html
MATCH  /checkout/
MATCH  /payment
```

**Two independent causes:**
1. **`buy` is not in the token list.** Amazon's entire checkout funnel lives under `/gp/buy/`.
2. **Whole-segment matching.** The regex requires the token to be a complete path segment,
   so the literal payment page `payselect` does not match the token `pay`.

**Consequence:** a commerce run remains in `agent_working` — the only mode that permits
acting — through Amazon's checkout and payment pages. The gate that exists specifically
to guarantee "the agent cannot act on a payment page" does not fire on the largest
retailer on the internet. It fails *open*, not closed.

**Scope of the claim — stated precisely.** During this run, navigation to the checkout
URL returned "Page Not Found" (Amazon requires session parameters), so the agent never
stood on a live checkout page. **What is proven is the regex gap**, by direct test. The
reachable path — cart → "Proceed to checkout" → `/gp/buy/spc/...` — has the same path
shape and would not trip the gate. This was not empirically walked.

**Fix:** add `buy` to the token list; switch to substring-within-segment matching for the
`pay*` family. Pair with a test table of real checkout URLs (Amazon, Shopify `/checkouts/`,
Stripe, PayPal), since current tests appear to use idealized paths like `/checkout/`.

---

### Finding 2 — `confirm_purchase` has no command surface — **HIGH**

**Where:** `lib/buster_claw/browser_control/commerce.ex:62`

`Commerce.confirm_purchase/3` is implemented and tested, but appears in neither
`commands.ex` nor `commands/*.ex`. It is therefore **unreachable via `/api/run`**.

**Consequence:** the run terminated as `stopped`, never `done`. No `browser_agent` Wallets
transaction was written. No confirmation page was captured to
`<workspace>/browser-control/captures/`. The purchase is invisible to the ledger.

**Combined with Finding 1, the entire commerce ceremony is unreachable end to end.** The
designed flow is: payment page → handoff → `awaiting_human` → human pays →
`confirm_purchase` bills the frozen cart → `done`. Step one never fires and step five
cannot be called. Every individual piece exists and works; none of them can be reached in
sequence from the agent side.

**Fix:** expose `agent_run_confirm_purchase` in the command surface.

---

### Finding 3 — No secret store is wired — **MEDIUM**

**Where:** `lib/buster_claw/browser_control/agent_mode.ex:203`, `commands/agent_runs.ex`

```elixir
secret_resolver: Keyword.get(opts, :secret_resolver, fn _ -> :error end)
```

The default resolver rejects every name, and `agent_run_start` builds `run_opts` as
`[scope: scope, on_payment: on_payment]` — it never passes `:secret_resolver`. So
`$secret.<name>` always returns `{:error, {:unknown_secret, name}}`.

Phase 3.5 shipped `SecretRef` (pure, correct, well-tested) and the AgentMode plumbing that
consumes it. What was never built is the store behind it — Keychain, wallet, or encrypted
settings.

**Consequence:** the agent cannot drive any authenticated flow. Logins must be typed by
the operator into the headful window. This is *safe* — arguably safer than the
alternative — but it caps autonomy: no unattended run can touch a site requiring sign-in.

Note the failure mode is correct by design: an unknown name fails the *whole* resolution
rather than typing an empty string into a form.

**Fix:** wire a Keychain-backed resolver into `agent_run_start`. This is the natural
Phase 7 candidate.

---

### Finding 4 — `text` targeting fuzzy-matches, and nearly bought the wrong product — **MEDIUM**

**Where:** `lib/buster_claw/browser_control/page.ex:245-251`

`finder_js` for a `text` target enumerates all elements and takes the **first** whose
`innerText` *includes* the string:

```elixir
.find(el => (el.innerText || el.value || '').trim().includes(...))
```

**What happened.** The product page's size selector was defaulted to **54 inches**, not
the required 45. Attempting to correct it via `click` with `text: "45 inches"` matched a
**customer review's variant byline** — `"Size: 45 inchesColor: Dark Brown"` — and
navigated to the reviews page. Review metadata reliably out-ranks the actual swatch,
because reviews appear earlier in DOM order on some layouts and there are many of them.

**Consequence:** a silent wrong-variant purchase is very reachable here. Had the click
landed on a *different* valid swatch rather than a review link, it would have changed the
size or colour without any error, and the run would have proceeded to cart confidently.
Nothing in the stack would have flagged it.

**How it was caught:** by re-entering through the search result and verifying against the
**cart line**, which renders the resolved variant explicitly —
`"1 Pair (45 Inches, Black)"`. The cart line is ground truth; the product page's default
swatch is not.

**Fix / practice:**
- Use `selector` (→ `document.querySelector`, precise) for anything that affects what gets
  bought. Reserve `text` for unambiguous buttons.
- Consider making `text` matching prefer exact-match over substring, and/or return an
  error when multiple elements match rather than silently taking the first.
- Always verify a selected variant against the cart, never the product page.

---

### Finding 5 — `find_elements` ignores its selector — **LOW**

`find_elements` returned a generic page-wide accessibility scan regardless of the selector
passed (`"input,form"` and `"#variation_size_name li"` both returned the same nav links).
`extract` honors selectors correctly.

**Consequence:** minor — `extract` covers the need — but the command is misleading as
documented and cost several wasted round trips during this run.

---

### Observation — egress policy on shopping sites

89.8 KB left the machine across 41 steps, **all at level `:full`**, 0 redactions. This is
correct per the documented default (unknown host → `:full`), but it means complete Amazon
page content, including order history, was sent to the model.

Worth setting `amazon.com` to `:structure_only`. Related: I did not find the `policy.md`
grammar wired to a config surface — Phase 3.5 listed it as deferred, and it appears to
still be.

---

## 4. What worked, and is worth keeping

- **Scope held.** Every navigation was in-scope and correctly tagged with its motivating
  origin. No spurious halts.
- **The frozen cart is exact.** `$14.95 + $8.76 = $23.71`, matching Amazon's own subtotal
  to the cent. The ledger-equals-shown property is real.
- **The egress receipt is honest.** It reports bytes out, levels, and redaction counts
  without flattering itself.
- **Headful + persistent profile is the right call.** The operator signed in once; the
  agent never saw the credential; the profile retains the session for future runs.
- **`extract` with precise selectors is reliable** and is the right primitive for reading
  product state.

The single most effective safety property in this run was not a gate — it was that the
run is **headful and supervised**, so a human could see what was happening. That is the
design working as intended, and it is what covered for Findings 1 and 4.

---

## 5. Recommended next steps

| # | Action | Size | Priority |
|---|---|---|---|
| 1 | Add `buy` + substring `pay*` matching to `@payment_path_re`; add real-checkout-URL test table | Small | **High** |
| 2 | Expose `agent_run_confirm_purchase` in the command surface | Small | **High** |
| 3 | Walk a live checkout end to end to empirically confirm the gate fires post-fix | Small | **High** |
| 4 | Make `text` targeting error on ambiguous multi-match | Small | Medium |
| 5 | Wire a Keychain-backed `secret_resolver` into `agent_run_start` (Phase 7) | Medium | Medium |
| 6 | Fix `find_elements` selector handling | Small | Low |
| 7 | Set `amazon.com` → `:structure_only`; wire `policy.md` to a config surface | Medium | Low |

Items 1–3 together close the commerce loop, which is currently open at both ends.

---

## Appendix — order placed

| Item | Price |
|---|---|
| Benchmark Waxed Kevlar Boot Laces — 45 Inches, Black, 1 pair, Made in USA | $14.95 |
| Gorilla Super Glue, anti-clog cap, 4 × 3 g tubes, Clear | $8.76 |
| **Subtotal (2 items)** | **$23.71** |

Delivered to Coupeville 98239. Free delivery next day on the laces. Cart returned to 0;
both items confirmed present in Amazon order history.
