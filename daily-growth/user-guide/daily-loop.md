# Daily Loop

## The loop

1. **Open a terminal** in the app and start your agent in it — `claude` (or
   `codex`). This is your own Claude Code session.
2. **Start the mail poller** (there is a **Commands** menu in the terminal
   toolbar with this pre-filled, or type it):

       ./buster-claw mailman poll

   This syncs Gmail and drops **trusted-sender** mail onto the queue.
3. **The agent reads its worklist** — the "fridge": `shift/Dispatch.md`. A live,
   always-current list of open items grouped by job. Tell your agent to read it.
4. **The agent pulls and acts:**

       ./buster-claw jobs show mail-triage              # what this job is for
       ./buster-claw dispatch claim --job mail-triage   # take the next item
       #   …does the work using Buster Claw's command surface…
       ./buster-claw dispatch done <id> --note "what I did"
       #   or:  ./buster-claw dispatch block <id> --note "why it's stuck"

Finished items drop off the fridge; the day's record is kept in
`shift/<date>/Dispatch.md` + `Dispatch.jsonl`.

The whole loop: **trusted email → queue → fridge → agent claims → does it →
marks done.**

## A good first run

1. Connect Gmail and add yourself to `memory/trusted-email-senders.md`.
2. Send yourself a test email from that address.
3. `./buster-claw mailman poll --once` → open `shift/Dispatch.md` in the
   Workspace tab and watch your email appear as a queued item.
4. `./buster-claw dispatch claim` → `./buster-claw dispatch done <id> --note
   "tested"` → watch it leave the fridge.
5. Open **Security** and see both actions logged.

## Worth knowing

- The agent treats email bodies as **untrusted data** — the fridge fences them in
  a code block so they cannot smuggle in instructions.
- Add more jobs anytime by dropping a new `job-descriptions/<key>.md` file. The
  filename is the job key used everywhere.

## CLI quick reference

    ./buster-claw commands                  # list every command
    ./buster-claw mailman poll [--once]      # sync Gmail into the queue
    ./buster-claw jobs list                  # the job roster
    ./buster-claw jobs show <key>            # one job's mandate
    ./buster-claw dispatch list [--job <k>]  # open items on the fridge
    ./buster-claw dispatch claim [--job <k>] # take the next open item
    ./buster-claw dispatch done <id> --note  # complete it
    ./buster-claw dispatch block <id> --note # park it as blocked
