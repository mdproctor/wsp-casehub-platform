# HANDOFF — casehub-platform

*Updated: 2026-07-24 — #384 neocortex reactive retirement completed (PR opened)*

**Date:** 2026-07-24
**Project:** `/Users/mdproctor/claude/casehub/platform`
**Workspace:** `/Users/mdproctor/claude/public/casehub/platform`

---

## Last Session

Completed neocortex reactive retirement (casehubio/parent#384) from platform slot 30. Converted 3 reactive-primary backends (Qdrant CBR, Mem0, Graphiti) to blocking, deleted 61 reactive files (-8596 net lines), removed Mutiny from 11 POMs. PR: casehubio/neocortex#177.

Key finding: neocortex was only partially reactive-primary (3 backend modules). RAG, decorators, and in-memory stubs all had independent blocking implementations — straight deletion, not conversion.

## #384 Status — All Repos

| Repo | Status |
|------|--------|
| platform | Merged (#194) |
| ras | Merged (#54) |
| connectors, claudony, openclaw, blocks | Clean (zero reactive) |
| ledger, eidos, qhorus | Committed locally |
| ops | PR #63 |
| desiredstate | PR #88 (CI failing: SettingsScope API) |
| iot | PR #70 (CI failing: Worker.Builder) |
| **neocortex** | **PR #177 (ready for review)** |

Once all PRs merge → close casehubio/parent#384.

## Immediate Next Step

Engine expression migration: engine#747-750. Run `/work` to start on engine#747.

## Cross-Module

**Enabled** (we delivered, downstream work is ready):
- `casehub-engine` — engine#747-750: expression type migration to platform SPI · M · Med
- `casehub-engine` — engine#713: migrate to `Vectors.cosineSimilarity()` · XS · Low
- `casehub-neocortex` — neocortex#142: wire CbrOutcomeConsumer · S · Low
- `casehub-connectors` — connectors#86: DestinationResolver now published · M · Med
- `casehub-work` — work#315: migrate work-notifications to platform subscription engine · L · Med
- `casehub-qhorus` — qhorus#375: migrate notification bridge to SubscribableEvent · M · Med
- `casehub-iot` — iot#67: household notifications via platform subscription engine · M · Med
- `casehub-blocks-ui` — blocks-ui#92: preferences editor UI component · L · Med
- **All consuming repos** — SettingsScope tenancyId breaking change · S · Low per repo

## What's Left

- MongoDB backend for subject view toolkit — not yet filed · M · Med

## References

*Unchanged — `git show HEAD~1:HANDOFF.md`*
