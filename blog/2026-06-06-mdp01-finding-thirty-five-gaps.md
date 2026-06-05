---
layout: post
title: "Finding Thirty-Five Gaps in a Document I'd Just Written"
date: 2026-06-06
type: phase-update
entry_type: note
subtype: diary
projects: [casehub-platform]
tags: [documentation, arc42, architecture]
---

ARC42STORIES.MD for casehub-platform had been a stub since June. §1 and §2 were
solid; §3 through §13 were placeholders — "complete in dedicated session" appearing
in every heading. Issue #56 existed specifically to close that gap.

I brought Claude in to build it out from source material: 29 blog entries covering
seven weeks of platform work, 8 ADRs, 8 design specs, the git log across 80+
commits, and the GitHub issue list. We read all of it and wrote the document. 1,353
lines. Then I asked for an exhaustive review of everything we'd just written.

## Where it lived

The stub had been committed to the workspace root. That's wrong in a specific way —
ARC42STORIES.MD is the architecture record, the successor to DESIGN.md. Architecture
records belong in the project repo where anyone who clones `casehubio/platform` can
find them. The workspace holds handovers, plans, blog entries. We moved it to the
project repo root, deleted the workspace stub, and recorded the decision as ADR-0009
before investing further effort in the content.

## Thirty-five gaps in a document we'd just written

The review process: read every source sequentially — blog by blog, ADR by ADR,
spec by spec — cross-checking each claim and omission against the document. The
count came back at 35 gaps. Some were minor (missing glossary terms, incomplete
key-file listings). A few were genuinely significant.

**The root-scope ancestor chain.** `Path.parent()` is documented as "returns null
if root OR single-segment path." Both zero-segment and one-segment paths return null.
An implementation that walks `parent()` to build an ancestor list for preference
resolution terminates at the single-segment level — it never reaches the zero-segment
root. Preferences stored at root scope silently return the key's default value with no
error. The fix (explicit root prepend after the walk: `if (path.depth() > 0) { ancestors.add(0, ""); }`)
is non-obvious, and the symptom — wrong data, no exception — is the kind that stays
hidden for months. This went in as both an L5 key wiring note and a standalone
anti-pattern.

**The OOM disguising a config bug.** During SCIM integration testing, Quarkus was
starting a Keycloak DevServices container because `quarkus-oidc-client` was on the
classpath — even though no test ever called the OIDC token endpoint. The container
consumed all available Podman VM memory and died before emitting its startup log
line. The actual problem was a `@ConfigMapping` prefix conflict: SmallRye's strict
mode treats `@ConfigMapping(prefix = "casehub.platform.scim")` as owning that
namespace exclusively, so a `@ConfigProperty` injection for
`casehub.platform.scim.member-page-size` in another bean was rejected at boot with
`SRCFG00050: does not map to any root`. Without the container crash above it, the
config error would have been immediate and obvious. The document had the `@Provider`
CDI gotcha and the Quarkiverse WireMock breakage; it was missing both the
`@ConfigMapping` exclusivity rule and the diagnostic chain that connects an OOM to
a config key.

**The ephemeral-vs-tmux agent distinction.** `ClaudeAgentProvider` is for
task-scoped ephemeral execution — one `execute()` call, one subprocess, done. No
session registry, no named session, no ledger event chain. Claudony's tmux-based
worker provisioner is for persistent, dashboard-visible sessions: named
`claudony-worker-{id}`, registered, with `causedByEntryId` threaded through to the
`WorkerStarted` ledger audit entry. Both launch Claude processes. Neither replaces
the other. The document described `ClaudeAgentProvider` accurately and said nothing
about when you'd reach for the other thing instead.

`AgentProvider` was also listed as a key file under `platform-api` instead of
`agent-api`. That's the kind of error a class-name existence check catches if you're
verifying the right attribute.

## What it is now

Fifteen chapters across three journeys, eight layer entries with key files, wiring,
gotchas, patterns, and architectural decisions. Nine ADRs cross-referenced in §10.
Seven open risks in §12. Twenty-three glossary terms.

The review took longer than writing it. That's roughly the right ratio for a document
claiming to be the architecture record.
