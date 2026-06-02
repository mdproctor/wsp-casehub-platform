---
layout: post
title: "The chain that wasn't there"
date: 2026-06-02
type: phase-update
entry_type: note
subtype: diary
projects: [casehub-platform]
tags: [ci-cd, github-actions, multi-tenancy]
---

The session started with what looked like a simple question: why is claudony's CI red?

The first diagnosis was wrong. The CI error said `casehub-ledger` — and there's a standalone `casehub-ledger` library. I sent a message there. They came back quickly: `CaseLedgerEntry` doesn't exist in their library. They were right. The class lives in `casehub-engine-ledger`, an internal module of the engine repo. The package is `io.casehub.ledger.model`; the standalone library uses `io.casehub.ledger.runtime.model`. Close enough to mislead, different enough to matter.

Once I looked at the actual CI logs rather than the error summary, it was clear: `cannot find symbol: variable tenancyId on CaseLedgerEntry`. Engine had added `tenancyId` in engine#299 but the SNAPSHOT on GitHub Packages predated those commits. Platform was already green. Ledger had recovered automatically once platform deployed. Engine fixed itself at 08:50. Claudony was simply never triggered — engine's dispatch list only covered `flow` and `openclaw`.

One `gh workflow run ci.yml --repo casehubio/claudony` and it went green.

But that was today's fix. The real question was how many other repos are in the same position.

We audited the full dependency graph — read every workflow file across fifteen repos, cross-referenced every pom.xml. The gaps were significant. Engine wasn't notifying claudony, aml, devtown, or life. Eidos was dispatching to devtown and claudony — but neither has eidos as a dependency. Engine does. The dispatch was going to the right neighbourhood but the wrong address. Eidos should trigger engine; engine cascades from there. Ledger wasn't notifying clinical or life. Work wasn't notifying clinical or life. Qhorus wasn't notifying devtown or life. Connectors missed devtown.

Eight workflow files fixed. The eidos correction was the most structurally interesting — it wasn't a missing entry, it had the wrong entries entirely.

There was also a pre-push hook surprise. Every casehubio repo with the hook configured blocks all pushes regardless of whether there are squash candidates. The hook comment is explicit: "pattern-based detection is insufficient — run full AI analysis every time." A single clean `ci:` commit still gets blocked. The intended flow is hook fires, run `/git-squash`, then `git push --no-verify`. Worth knowing before the next session.

The multi-tenancy audit that was the original goal is filed as parent#140 — full state across every repo, verified against pom.xml, git history, and CI records.

Qhorus is the one unresolved piece. Local main has diverged from casehubio upstream — different SHAs for the same content, different commit paths. The devtown/life dispatch fix is committed locally but stuck there until someone reconciles the branches.
