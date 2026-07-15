# Trademark & Brand Policy

**Short version:** the code is yours — the name isn't.

Buster Claw is [MIT licensed](LICENSE). Fork it, sell it, build a business on it,
strip out every part you don't like. What you may not do is ship it **as Buster
Claw**.

## What the MIT license gives you

Everything in this repository that is code, and that includes the parts we'd
consider "ours" aesthetically:

- the Elixir/Phoenix application, the Tauri shell, the CLI
- the **WGSL shaders** (`assets/js/smoke/*.wgsl.js`) — the smoke, waves, weather,
  mandelbrot and face patterns
- the **CSS design system** (`assets/css/app.css`) — the Industrial Claw look,
  the palette, the `ic-` utilities
- the documentation and the workspace guides

We licensed the shaders and the design system deliberately, rather than holding
them back. They are the most-copied and least-defensible part of any project —
nobody needs our WGSL to write a smoke shader — and they are also the best
advertisement the project has. MIT requires that our copyright notice travel with
them, so wherever they end up, they carry attribution. That is the protection we
actually wanted.

## What is reserved

The **identity**, not the implementation:

- the name **"Buster Claw"** and **"BusterClaw"**
- the **wordmark** and the **logo**
- the domain **busterclaw.lol** and the visual identity used to present the official
  builds

These are not licensed to you. This is the same boundary Chromium draws against
Chrome, and Code-OSS against VS Code: the engine is free, the badge is not.

## What that means in practice

**You may:**

- fork the repository and modify it however you like
- distribute your fork, including commercially
- say your project is *"based on Buster Claw"*, *"a fork of Buster Claw"*, or
  *"compatible with Buster Claw"* — accurate, factual references are fine and
  always will be
- use the shaders and the design system in your own work, keeping the MIT notice

**You may not:**

- call your distribution "Buster Claw" (or a name a reasonable person would
  confuse with it)
- use the logo or wordmark as the identity of your fork
- imply that your fork is the official build, endorsed by us, or supported by us

**Rename your fork.** That's the whole ask.

## Why we bother

The official Buster Claw build is signed, notarized, and carries the managed
telephony service — a real phone number, on our Twilio account, at our cost.
People need to be able to tell it apart from a fork, because when they pay for a
phone number, they're trusting the thing on the other end of it. The trademark
is what makes that distinction meaningful; it protects users more than it
protects us.

## Contributing

Contributions are welcome and are accepted under the MIT license — by opening a
pull request you agree your contribution ships under those terms. There is no CLA
and no copyright assignment.

## Questions

If you're unsure whether a use is okay, ask. Reasonable requests get a yes.

*(Common-law trademark rights attach through use. Formal registration is a
later step; the policy above applies now.)*
