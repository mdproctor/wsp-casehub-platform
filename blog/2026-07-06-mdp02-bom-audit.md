---
layout: post
title: "The BOM That Forgot to Grow"
date: 2026-07-06
type: phase-update
entry_type: note
subtype: diary
projects: [casehub-platform]
tags: [bom, ci, maven, cross-repo]
---

A routine question — "other repos say governance is missing" — turned into a full audit of the casehub-parent BOM against every child repo in the build chain. Governance was fine. The BOM was not.

## Forty-One Missing, Eight Dead

I wrote a Python script to cross-reference the parent BOM's `<dependencyManagement>` entries against the actual `<module>` declarations in all 24 build-chain repos. Every module that's in a child reactor but absent from the BOM is a library that downstream repos can't reference without explicit version pins — which means in practice they don't reference it at all.

The numbers: 41 library modules across 12 repos were in the reactor but missing from the BOM. Platform accounted for 10 (the entire notification and subscription pipeline from the last few sessions), neocortex for 12 (all the memory modules that migrated from platform plus inference-bge-m3), ledger for 3, iot for 5. The full list touched every tier of the build chain.

On the other side: 8 stale entries pointing to artifacts that no longer exist. Five platform memory modules migrated to neocortex on July 1 — the BOM entries stayed behind. Two ras modules had been renamed from `ras-jpa` / `ras-memory` to `persistence-jpa` / `persistence-memory` — old names lingered. And a drafthouse entry that pointed to a Maven artifact for what's now an Electron app.

The root cause is simple: adding a module to a child repo's reactor doesn't automatically update the parent BOM. There was no check, no reminder, no CI validation. Every session that added a module and didn't also update the parent created one more ghost dependency.

## Closing the Loop

The BOM fix itself was mechanical — add the 41, remove the 8, push. The interesting part is making sure it doesn't drift again.

I added `scripts/bom-audit.py` to the parent repo. It can run locally (reads sibling clones) or in CI (fetches pom.xml via `gh api` with base64 decode). A GitHub Actions workflow runs it weekly and on `repository_dispatch` — so when any child repo publishes, it triggers the audit. Platform's publish workflow now dispatches to parent alongside the existing downstream triggers.

One thing caught me out during the investigation: the GitHub Packages API silently truncates at 30 items per page with no indication of truncation. I spent time investigating why packages weren't publishing before realising they were simply on page 3 of the results. That one earned a garden entry.

## The Downstream Chain

With the BOM fixed, the build chain status is: parent green, platform green, and the first tier (ledger, connectors, eidos, neocortex) all green. Work and qhorus are red — both pre-existing test failures unrelated to the BOM. Work has a `WorkEventTypeTest` enum mismatch (new event types added but the exhaustive test not updated). Qhorus has a `ConcurrentAutoChannelTest` race condition. Those are the first dominoes; everything downstream of them (engine, devtown, aml, clinical, claudony) cascades from there.
