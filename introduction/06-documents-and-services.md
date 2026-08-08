## Documents & the Library

Anything worth keeping becomes a Library document — markdown on the user's
disk, indexed so it's findable later.

    ./buster-claw run document_save --json '{"name":"…","body":"…","source_url":"…"}'
    ./buster-claw run document_list
    ./buster-claw run document_read --json '{"id":42}'   # raw markdown; document_get = metadata

`document_save` is restricted, `document_delete` deletes the file as well as
the index row. Pass `source_url` whenever the content came from somewhere —
a document whose provenance is lost can't be re-checked. `browser_capture_page`
is the browser's shortcut into this same store.

The app also keeps its **own** calendar, separate from Google's:
`event_list`, `event_get`, `event_create`, `event_update`, `event_delete`.
Use it for things that belong to Buster Claw rather than to the user's Google
calendar — and be clear which one you wrote to, because "I added it to your
calendar" is ambiguous and gets people to the wrong meeting.

## Integrations

GitHub, Sentry, and Umami, mirrored into the Library on demand. **There is no
background poller** — a poll happens because you or the user asked for one,
or because a verified webhook arrived.

    ./buster-claw run integration_list
    ./buster-claw run integration_poll --json '{"id":3}'   # or integration_poll_all
    ./buster-claw run integration_run_list                 # run history

`integration_create` / `integration_update` / `integration_delete` are
restricted — they hold tokens and webhook secrets. Two things to know:
webhook signature verification **fails closed** (no configured secret means
no accepted webhook, by design), and a verified event becomes a **Library
snapshot, not a queue item** — integrations never enqueue agent work. If the
user wants a Sentry issue worked, that's a `dispatch_enqueue`, made
deliberately.

## Shifts and the runtime

A **shift** is the unit of "Buster Claw is on duty". It runs until stopped —
there is no fixed window.

    ./buster-claw run runtime_status        # process + system snapshot
    ./buster-claw run shift_status          # active? plus counts
    ./buster-claw run shift_start --json '{…}'
    ./buster-claw run shift_stop

Set `unattended` on `shift_start` and the Dispatcher works the queue with
headless agent runs — no human in the terminal. That path has a kill switch
(a `STOP` file), a crash-loop brake, and a hard per-shift run cap that
**stops the shift** rather than burning tokens unbounded. If a shift stopped
on its own, look there before assuming a crash.

Inside a shift, `shift_assignment_start` / `shift_assignment_status` /
`shift_assignment_stop` manage specialist role sessions, and
`terminal_tab_open` opens a visible in-app terminal tab for a role — that's
how you put a specialist somewhere the user can watch it work.
`job_list` and `job_show` read the job roster from the command surface
instead of the filesystem.

## Google Workspace

The user connects their Google account once in Settings; after that you act
as them across the whole suite. `google_account_list` shows which accounts
are connected — check it before assuming there's only one, because the answer
to "search my mail" differs per account. `gmail_sync` and
`google_calendar_sync` pull fresh state into local SQLite; run a sync before
answering a question about "what's in my inbox/calendar" rather than trusting
a stale read.

- **Mail** — `gmail_search`, `gmail_read`, `gmail_label_list`, `gmail_modify`,
  `gmail_draft_create`, `gmail_trash`, `gmail_send`, `gmail_delete`.
- **Calendar** — `gcal_event_create`, `gcal_event_update`, `gcal_event_delete`
  write to Google; `event_create` / `event_update` write the app's own
  durable calendar. They are different stores — know which one the user means.
- **Drive** — `drive_list`, `drive_get`, `drive_download`, `drive_export`,
  `drive_upload`, `drive_update`, `drive_copy`, `drive_folder_create`,
  `drive_share`, `drive_delete`.
- **Docs / Sheets / Slides** — `docs_create`, `docs_get`, `docs_batch_update`;
  `sheets_create`, `sheets_get`, `sheets_get_values`, `sheets_update_values`,
  `sheets_append_values`, `sheets_clear_values`, `sheets_batch_update`;
  `slides_create`, `slides_get`, `slides_batch_update`.
- **Tasks** — `tasks_list`, `tasks_get`, `tasks_create`, `tasks_update`,
  `tasks_delete`.
- **Contacts** — `contacts_list`, `contacts_search`, `contacts_get`,
  `contacts_create`, `contacts_update`, `contacts_delete`.

Six of these are **gated** — they need the operator's confirmation every
time, no matter how routine the errand feels: `gmail_send`, `gmail_delete`,
`gcal_event_delete`, `drive_delete`, `tasks_delete`, `contacts_delete`. The
pattern is the obvious one — **things that leave the machine, and things that
cannot be undone.** `gmail_trash` is not gated because trash is reversible
and `gmail_delete` is not; prefer trash unless the user says "permanently".

Two habits worth keeping. **Prefer append to overwrite** —
`sheets_append_values` adds a row, `sheets_update_values` destroys whatever
was in the range, and the user's spreadsheet has no undo you can reach. And
**`drive_share` widens who can see a document**; it isn't gated, but treat
it with the same care as a send, because it is one.

## Finance research

Read-only company research, independent of the user's accounts. Every result
carries its source and an as-of.

    ./buster-claw run finance_filings --json '{"symbol":"AAPL"}'       # SEC EDGAR, newest first
    ./buster-claw run finance_fundamentals --json '{"symbol":"AAPL"}'  # SEC XBRL
    ./buster-claw run finance_quote --json '{"symbol":"AAPL"}'         # Finnhub; needs FINNHUB_API_KEY
    ./buster-claw run finance_news --json '{"symbol":"AAPL"}'          # Finnhub

Filings and fundamentals come from SEC EDGAR and are as authoritative as
finance data gets — prefer them to a web search when the question is about
what a company actually reported. Quotes and news need `FINNHUB_API_KEY`; if
it isn't configured, say so rather than substituting a number off a webpage.

