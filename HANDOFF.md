# HANDOFF — casehub-platform

**Date:** 2026-07-14
**Project:** `/Users/mdproctor/claude/casehub/platform`
**Workspace:** `/Users/mdproctor/claude/public/casehub/platform`

---

## Last Session

Promoted generic expression evaluation SPI to platform-api (#141). `CompiledExpression<C, R>` runtime contract, `ExpressionEngine` factory, `ExpressionEngineRegistry` dispatcher. Three evaluator types: JQ, MVEL, Lambda. MVEL3 engine wraps the MVEL3 transpiler with lazy compilation. ConstraintCompiler converted from static utility to CDI bean with parameterized MVEL expressions (injection prevention). Design-reviewed (4 rounds, 14 issues, all resolved). Landed as 82d1172 on main.

Also landed: DoublePreference/IntPreference (desiredstate#77, 33c2208), SIGNING_SECRET CredentialPropertyKey (#345, 6d758b5), JBoss Nexus snapshots repo added to parent BOM (parent#372).

## Immediate Next Step

Pick from What's Next — #170 delivery engagement tracking, #151 expression-based subscription filters (MVEL path now unblocked), or #176 engine expression migration. Consumer migration issues still open: engine#713, work#302.

## Cross-Module

**We're blocking:**
- `casehub-engine` — engine#713: migrate to `Vectors.cosineSimilarity()` · XS · Low
- `casehub-work` — work#302: migrate to `Vectors.cosineSimilarity()` · XS · Low
- `casehub-work` — `WorkEventTypeTest` needs updating for SubscribableEvent + marshallerKeys · S · Low
- `casehub-engine` — #176: engine-api expression types migrate to platform SPI · M · Med

## What's Left

**Epic #147 — Notification deferred:**
- #170 Open/engagement tracking · M · Med
- #151 Expression-based subscription filters · S · Med (MVEL path now unblocked)

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
| #151 | Expression-based subscription filters | S | Med | JQ + MVEL both work now |
| #146 | Notification center frontend | L | Med | Remaining: blocks-ui#33, #34 |

## References

| Type | Path |
|------|------|
| Spec | `docs/specs/2026-07-14-expression-spi-mvel3-design.md` |
| Review | `~/adr/casehub-platform/expression-spi-mvel3-20260714-134939/` |
| Garden | `GE-20260714-550161` — MVEL3 contains keyword conflict |
