---
layout: post
title: "The Design That Went Somewhere Else"
date: 2026-05-22
type: phase-update
entry_type: note
subtype: diary
projects: [casehub-platform]
tags: [architecture, design-decisions]
---

Platform#24 opened a question: where do application-layer SPIs live when they're
domain-agnostic but too specific for the foundation tier? The proposed answer was a
`casehub-platform-apps-api` module. The actual answer, after working through the design,
was somewhere else entirely.

The initial content was `SlaBreachPolicy` — a decision-returning SPI for handling WorkItem
SLA breaches. Once I looked at the types involved (`BreachedTask` with `taskId`, `callerRef`,
`candidateGroups`), it was obvious: these are work vocabulary, not platform vocabulary. A
module claiming to be domain-agnostic but containing only work-specific types is misleading
from day one.

The deeper question was whether `casehub-work-api` could take the dependency. `SlaBreachContext`
needs `Path` and `Preferences` from platform-api. I had assumed "zero casehubio deps" was a hard
constraint on casehub-work-api. It isn't — any casehub repo may depend on casehub-platform-api.
Once that was clear, the answer was obvious: `SlaBreachPolicy` and the supporting types belong in
`casehub-work-api`, alongside `EscalationPolicy` and `ClaimSlaPolicy` where they fit naturally.

We also settled that `SlaBreachPolicy` replaces `EscalationPolicy` rather than complementing it.
Both answer "what should happen when a task breaches its deadline?" — but `EscalationPolicy` is
void and action-taking, which collapses decision and execution into one untestable call.
`SlaBreachPolicy` returns a `BreachDecision` value — casehub-work executes it, fires a CDI event,
observers handle side effects. The policy stays pure.

Platform#24 is closed. The full type design landed in casehubio/work#213, ready for the next
session in that repo.

`casehub-platform-apps-api` remains a valid future home for cross-cutting application SPIs that
genuinely span all modules. None have surfaced yet.
