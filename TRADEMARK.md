# Trademark & Brand Policy

**Short version:** read the code, use the code — don't ship it as Buster Claw, and
don't ship it as a substitute for Buster Claw.

Buster Claw is [PolyForm Shield 1.0.0](LICENSE) licensed: **source-available, not
open source.** Two separate boundaries apply, and it is worth keeping them apart —
one is the *license*, one is the *name*.

> **The license changed on 2026-08-10, and the old one still holds for old code.**
> Buster Claw was MIT-licensed from April 2026 until that date. **An MIT grant
> cannot be withdrawn.** Every commit published under it stays MIT for anyone who
> has it, permanently, with every right MIT gives — including redistribution and
> resale of that code. PolyForm Shield governs the code from 2026-08-10 forward.
> If you are relying on MIT terms, pin a commit from before that date; nothing
> below takes away what you already have.

## What the license gives you

**Any purpose is a permitted purpose, except competing.** That is the whole shape
of it. You may:

- read, audit, and run it — personally or at your company, commercially, free
- change it, and make new works based on it
- distribute copies, including your changes

Applied to everything in this repository that is code, and that includes the parts
we would consider "ours" aesthetically:

- the Elixir/Phoenix application, the Tauri shell, the CLI
- the **WGSL shaders** (`assets/js/smoke/*.wgsl.js`) — the smoke, waves, weather,
  mandelbrot and face patterns
- the **CSS design system** (`assets/css/app.css`) — the Industrial Claw look,
  the palette, the `ic-` utilities
- the documentation and the workspace guides

**Auditability is the reason the source is readable at all.** This is a tool that
drives a logged-in browser and reads your email. "Trust us" is not an acceptable
answer, and a readable runtime is the only honest alternative. That purpose is
served whether or not anyone may resell it — which is precisely why the license
protects the one thing and not the other.

## What the license does not give you

**Competing use.** You may not use this software to provide a product that
competes with Buster Claw, or with a product we provide using it.

The license is explicit that competition survives changes of shape: an application
can compete with a service, a library with a plugin, and a free product can compete
with a paid one. If you would market it as a practical substitute for Buster Claw,
it competes. See [Noncompete](LICENSE) and the Competition section beneath it.

## What is reserved separately

The **identity** is not covered by the license at all — it is trademark, and it
would be reserved under any license, including the MIT one this replaced:

- the name **"Buster Claw"** and **"BusterClaw"**
- the **wordmark** and the **logo**
- the domain **busterclaw.lol** and the visual identity used to present the
  official builds

This is the same boundary Chromium draws against Chrome, and Code-OSS against VS
Code: the engine and the badge are separate grants.

## What that means in practice

**You may:**

- fork the repository and modify it however you like
- run it, including at work and for commercial purposes
- distribute your fork, provided it does not compete with Buster Claw
- say your project is *"based on Buster Claw"*, *"a fork of Buster Claw"*, or
  *"compatible with Buster Claw"* — accurate, factual references are fine and
  always will be
- use the shaders and the design system in your own work, keeping the required
  notice

**You may not:**

- ship it, or a product built from it, as a substitute for Buster Claw
- call your distribution "Buster Claw" (or a name a reasonable person would
  confuse with it)
- use the logo or wordmark as the identity of your fork
- imply that your fork is the official build, endorsed by us, or supported by us

## Why we bother

The official Buster Claw build is signed, notarized, and carries the managed
telephony service — a real phone number, on our Twilio account, at our cost.
People need to be able to tell it apart from a fork, because when they pay for a
phone number, they're trusting the thing on the other end of it. The trademark is
what makes that distinction meaningful; it protects users more than it protects us.

The noncompete does the same job on the other side. **The money leg is a phone
number, not the code** — so the license only has to stop someone reselling the
thing itself, and can leave every other use alone.

## Contributing

Contributions are welcome and are accepted under the repository license — by
opening a pull request you agree your contribution ships under those terms. There
is no CLA and no copyright assignment.

## Questions

If you're unsure whether a use is okay, ask. Reasonable requests get a yes.

*(Common-law trademark rights attach through use. Formal registration is a
later step; the policy above applies now.)*
