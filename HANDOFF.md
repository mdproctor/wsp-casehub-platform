# HANDOFF — casehub-platform

**Date:** 2026-07-19
**Project:** `/Users/mdproctor/claude/casehub/platform`
**Workspace:** `/Users/mdproctor/claude/public/casehub/platform`

---

## Last Session

Delivered #187 — generic label infrastructure (LabelAction, LabelRule) in `platform-api/io.casehub.platform.api.label`, plus JQ engine fix (MapAdaptedJQExpression honours contextType contract). Design-reviewed ($20.05, 7 rounds). 41 tests, single squashed commit landed on main.

## Immediate Next Step

Engine expression migration: engine#747-750 (expression type migration to platform SPI). Run `/work` to start on engine#747.

## Cross-Module

**We're blocking:**
- `casehub-engine` — engine#747-750: expression type migration to platform SPI · M · Med
- `casehub-engine` — engine#713: migrate to `Vectors.cosineSimilarity()` · XS · Low
- `casehub-engine` — engine#730: case queue implementation (now unblocked — label infrastructure landed) · M · Med
- `casehub-work` — work#312: work-queues migration to platform-view · L · Med
- `casehub-neocortex` — neocortex#142: wire CbrOutcomeConsumer · S · Low

## What's Left

- casehubio/platform#185 — view-deletion membership cleanup · S · Med
- Domain notification bridges (work, engine, iot) — not yet filed · S · Low each
- IoT CBR spec §4-5 update for subject view toolkit — not yet filed · S · Low
- MongoDB backend for subject view toolkit — not yet filed · M · Med

## What's Next

| # | Description | Scale | Complexity | Notes |
|---|-------------|-------|------------|-------|
| #8 | Preferences-editor module — admin UI/API | XL | High | Write path for preferences; long-standing |

## References

| Type | Path |
|------|------|
| Spec | `docs/specs/2026-07-19-label-infrastructure-design.md` |
| Review | `~/adr/casehub-platform/label-infrastructure-20260719-135103/` |
