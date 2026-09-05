# The Workspace grows a rail — Directory · Notes · Calendar

**Scoped and SHIPPED 2026-09-05.**

> ### The one-sentence version
>
> **Notes and Calendar move off the homepage and onto the Workspace page, beside
> the files they are about rather than beside the chat.**

## The ask, as given (09-05, operator)

> *"Create a sub-tab system on the Workspace tab and we'll have Directory, Notes,
> and Calendar be our three sub-tabs. The Directory will be what the Workspace
> currently is and the Notes and Calendar sub-tabs will look similar to the way
> that they look now on the homepage. Simply they've been moved."*

Taken literally, and it was the right instruction: **nothing about either surface
was redesigned.** They are the same `LiveComponent`s, rendered by a different
host.

## Why this was cheap, and what that says

Both components were already embeddable and already had two hosts each —
`NotesComponent` (Home) and `CalendarComponent` (Home + the `/calendar` route).
Adding a third host cost a rail, two `:if` panels and one relay. Nothing came
*across*; only the chrome to hold them.

That is the same property the Vox2B move relied on four commits earlier, and it
keeps being the thing that makes these moves an afternoon instead of a rewrite:
**a surface that renders inline with no layout of its own can be re-homed by
whoever provides the chrome.**

## Decisions

- **`D1` — Directory is the default tab** and is exactly what the page was. Its
  markup moved inside an `:if` and was otherwise untouched.
- **`D2` — the rail and the guard are one list.** `WorkspaceLive.workspace_tabs/0`
  feeds both, and a lockstep test walks every key. Home shipped the opposite once
  — a button the server had never heard of, and the click raised.
- **`D3` — Home keeps neither.** No duplicate, no "also available at". Two places
  to edit the same note is how the two disagree.
- **`D4` — `/calendar` keeps its route.** Third host, unchanged; deep links and
  `SplitLive` panes still land.
- **`D5` — the tests moved rather than being rewritten.** Eighteen of them, with
  four substitutions: the route, the tab event, and the two component ids. That
  they needed nothing else is the evidence the move was a move.

## What the move exposed

**`F1` — `NotesComponent` hardcoded `id="home-notes"` on its root element.** It
had done since it was written, and it worked only because the homepage was its
one host. The moment a second host existed the id stopped describing anything:
`send_update` addressed `workspace-notes` while the DOM still said `home-notes`,
so every keyboard hook that reaches for its own root — the switcher, the new-note
chord — found nothing. Now `id={@id}`. **Two hosts on one page (a split pane)
would have collided the same way**, so this was a latent bug the move only
revealed.

**`F2` — the Pockets neighbour test was anchored to Notes.** It asserted
"Pockets sits directly after Notes", which is a claim about a tab that left. It
is anchored to Vox2B now, and stays a *neighbour* assertion rather than an index,
because what it has always been checking is that Pockets is not the tab nobody
can find.

**`F3` — `today` on `StatusLive` existed only for the calendar.** It left with
it, and took the `LocalTime` alias with it. A mount that computes a value nothing
reads is the kind of thing that survives three refactors.

## Not fixed here, and filed

The `Voice.Renderer` full-suite flake found the same day
([`LEFTOVERS_SURFACES`](LEFTOVERS_SURFACES.md)). It touches no code this map
changed and reproduces without it; it is recorded there with what was ruled out
and what would settle it.
