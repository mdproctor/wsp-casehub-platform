---
layout: post
title: "The Six-Week Gap"
date: 2026-06-21
type: phase-update
entry_type: note
subtype: diary
projects: [casehub-platform]
tags: [architecture, documentation, arc42, bom, drift]
---

ARC42STORIES.MD had fallen six weeks behind the code.

The drift showed up across five categories. Missing chapters: C19 (AgentSession
multi-turn + LangChain4j), C20 (Stream Ingestion), C21 (ACL Phase 1) — all
shipped, none narrated in the document. Missing layer entries: L10 had a taxonomy
row and a building-block diagram, but no narrative, no key wiring, no gotchas.
Stale risk entries: §12 still said the ACL work "hadn't started" and hadn't
identified any decisions; the six issues had been closed for a week. Wrong
cross-references: §12 cited "Shipped in C20" for AgentSession — C20 didn't
exist. Stale dates: L6's completion date was June 5, but the section had a
paragraph describing issues that closed June 20.

The ACL system was the most striking gap. Six issues (#91–96) merged in a
single PR, `AccessControlProvider` SPI, two adapter modules, a new `api/acl/`
package — and the document said the work hadn't started. That's not the same as
chapter-extension drift. It was a full architectural capability with no record
at all.

We audited by reading the document against three sources simultaneously: the
git log, open and closed GitHub issues, and IntelliJ's code index. The
combination catches what any single source misses. Git log shows what was
committed but not whether it was documented. Issues show what was closed but
not whether the document was updated. Code search confirms what actually exists
regardless of what either says.

The result: 306 insertions, 37 deletions across 1,482 lines. Three new chapters,
two new journeys, two new layer entries, nine modules added to the deployment
table, fifteen glossary terms, two external systems added to the context diagram.

After the audit, `parent#276` — add `cloudevents-core` to the casehub-parent BOM.
`iot#19`, `qhorus#279`, and `connectors#20` had all shipped their CloudEvent
adapters in the same two-day window, triggering the entry. The BOM work itself
took five minutes. The triggering took six weeks.

The pattern in ARC42STORIES.MD drift is predictable: code gets written on a
branch, the branch gets work-ended, the journal merges into existing layer
entries, but the chapter structure doesn't extend. Journal merge updates sections
that exist. It doesn't create sections that don't. Every new module that ships
without a chapter accumulates as prose inside an existing layer entry — findable,
but structurally invisible.

The ACL omission is the harder case. The work-end for that branch either didn't
write a journal entry, or wrote one without a `§Section` anchor that could merge
into a chapter record. Either way, the chapter creation step was skipped entirely.

Both drift types share the same root cause: chapters require deliberate
construction, and the end-of-session workflow optimises for commit and layer
documentation, not for chapter creation. The right fix is to write the chapter
entry before work-end, not discover its absence six weeks later.
