# HANDOFF — casehub-platform

*Updated: 2026-07-25 — #384 reactive retirement COMPLETE across all 13 repos. Slot 30 archived.*

**Date:** 2026-07-25
**Project:** `/Users/mdproctor/claude/casehub/platform`
**Workspace:** `/Users/mdproctor/claude/public/casehub/platform`

---

## Last Session

Completed casehubio/parent#384 — reactive tier retirement across all 13 repos. Neocortex was the main conversion work (3 reactive-primary backends: Qdrant CBR, Mem0, Graphiti). All other repos were mechanical deletion. Cross-repo API adaptation required for SettingsScope.root(tenancyId), WorkerResult generics, FeatureVectorCbrCase trust fields, and LedgerConfig.reactive().

Final stats: ~250+ files deleted, ~30,000+ lines of reactive code removed across platform, ledger, neocortex, eidos, qhorus, blocks, ras, desiredstate, iot. Mutiny dependencies removed from all module POMs.

Slot 30 archived to attic. All branches stamped as closed.

## Cross-Module

**Enabled** (we delivered, downstream work is ready):
- `casehub-work` — work#315: migrate work-notifications to platform subscription engine · L · Med
- **Domain modules** — platform#197: register preference schemas via the SPI · varies

## What's Left

- MongoDB backend for subject view toolkit — not yet filed · M · Med
- platform#196: server-side preference validation using schema constraints
- platform#198: schema versioning
- platform#199: custom/composite preference types

## References

*Unchanged — `git show HEAD~1:HANDOFF.md`*
