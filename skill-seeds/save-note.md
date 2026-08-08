---
name: save-note
description: Save a quick note to the Library. Use to capture text as a document.
metadata: {"version":"1.0.0"}
tier: restricted
enabled: true
handler_kind: composition
args: {"title":{"type":"string","required":true},"body":{"type":"string","required":true}}
steps: [{"command":"document_save","args":{"name":"$title","body":"$body"}}]
---

# save-note

A one-step composition skill: it forwards `$title`/`$body` to the native
`document_save` command. Run it with:

    ./buster-claw run save-note --json '{"title":"Hello","body":"World"}'

Skills are ordinary markdown files in this folder. A skill only runs when
`enabled: true`; omit or set it false to keep a skill staged but inert.
"""
