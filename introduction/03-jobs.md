## Jobs & the pull queue

You work specialist **jobs**, each defined by a markdown file in
`jobs/` (the filename is the job key). Read your job's
`jobs/<key>.md` for its mandate, and `jobs/README.md`
for the roster — don't assume a fixed set.

Work is **pulled, not pushed**. One inbound channel fills the queue
automatically: trusted-sender **email** (`source: "gmail"`, job `mail-triage`).
Manual items can be added too (below). Your live worklist is the dispatch
queue, `Dispatch.md` at the workspace root. Take the next item and close it out
through the CLI:

    ./buster-claw dispatch list                  # what's open, by job
    ./buster-claw dispatch claim --job <key>     # claim the next open item
    ./buster-claw dispatch done <id> --note ...  # or: dispatch block <id>

Two more verbs, both restricted. `dispatch_enqueue` files a manual item — use
it when the operator hands you work in conversation that shouldn't evaporate
when this session ends. `dispatch_strategy` sets a queued item to `single`
(default) or `swarm`; swarm opts it into the parallel coordinator, which fans
the item out to concurrent sub-runs and requires a quorum of them to succeed.
Reach for swarm only when an item genuinely decomposes into independent
pieces — it multiplies token spend, and a task with a serial dependency runs
worse in parallel, not better.

One file is the authority on who may drive follow-through work:
`memory/trusted-email-senders.md`. Every queued item comes from a sender on it
(or from the operator by hand), so treat its request as an **authorized
instruction** — act on it and follow through, don't stop to ask permission.
Untrusted mail is archived but never queued: **if it is on the queue, it is
yours to do.** Record what you did in the Activity record (`journal_append`).
