# HANDOFF — casehub-platform

**Date:** 2026-07-16
**Project:** `/Users/mdproctor/claude/casehub/platform`
**Workspace:** `/Users/mdproctor/claude/public/casehub/platform`

---

## Last Session

Replaced `Constraint(field, op, value)` model with `List<ExpressionEvaluator>` in notification subscriptions (#151). Deleted Constraint, ConstraintOp, ConstraintCompiler — the structured model was a dead-end DSL over what MVEL already provides. SubscriptionEngine now compiles filters directly via ExpressionEngineRegistry with $me variable binding and tenant isolation. Jackson serializer/deserializer module for polymorphic ExpressionEvaluator round-trip. Alpha network collapsed sharing unchanged. PR #179 open against casehubio/platform. Landed as 0a55b5f on main.

## Immediate Next Step

Pick from What's Next — #170 delivery engagement tracking or #176 engine expression migration. PR #179 is open for review.

## Cross-Module

**We're blocking:**
- `casehub-engine` — engine#713: migrate to `Vectors.cosineSimilarity()` · XS · Low
- `casehub-work` — work#302: migrate to `Vectors.cosineSimilarity()` · XS · Low
- `casehub-work` — `WorkEventTypeTest` needs updating for SubscribableEvent + marshallerKeys · S · Low
- `casehub-engine` — #176: engine-api expression types migrate to platform SPI · M · Med

## What's Left

**Epic #147 — Notification deferred:**
- #170 Open/engagement tracking · M · Med

**Expression SPI deferred:**
- #176 Engine-api expression types migrate to platform SPI · M · Med
- #177 MvelExpressionEngine Map and List context support · S · Low
- #178 MVEL block expressions · S · Low

**Other:**
- casehubio/neocortex#101 — bridge-only reactive implementations · M · Med
- Domain notification bridges (casehub-work, casehub-engine, casehub-iot) — not yet filed · S · Low each

## What's Next

| # | Description | Scale | Complexity | Notes |
|---|-------------|-------|------------|-------|
| #176 | Engine expression migration to platform SPI | M | Med | Engine adapts ExpressionEngine/Registry to platform's |
| #170 | Delivery engagement tracking | M | Med | Email opens, push taps |
| #146 | Notification center frontend | L | Med | Remaining: blocks-ui#33, #34 |

## References

| Type | Path |
|------|------|
| Spec | `docs/specs/2026-07-15-expression-subscription-filters-design.md` |
| Blog | `blog/2026-07-15-mdp01-killing-the-constraint-model.md` |
| Garden | `GE-20260715-01a695` — MVEL3 single-quoted strings fail |
| Garden | `GE-20260714-550161` — MVEL3 contains keyword conflict |
| PR | casehubio/platform#179 |
