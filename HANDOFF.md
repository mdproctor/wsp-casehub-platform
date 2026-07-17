# HANDOFF — casehub-platform

*Updated: #170 closed, PR #182 merged — removed from backlog.*

**Date:** 2026-07-17
**Project:** `/Users/mdproctor/claude/casehub/platform`
**Workspace:** `/Users/mdproctor/claude/public/casehub/platform`

---

## Last Session

Implemented delivery engagement tracking (#170) — channel-agnostic engagement events (OPENED, CLICKED, DISMISSED, REPLIED, CONVERTED) on DeliveryAttempt. Three recording paths converge on EngagementRecorder: SPI callback handler, direct REST, programmatic. In-app bridge via CDI observer. Deployment opt-in gate. Merged via PR #182.

## Immediate Next Step

Pick from What's Next — #176 engine expression migration or #177 MVEL Map/List context.

## Cross-Module

**We're blocking:**
- `casehub-engine` — engine#713: migrate to `Vectors.cosineSimilarity()` · XS · Low
- `casehub-work` — work#302: migrate to `Vectors.cosineSimilarity()` · XS · Low
- `casehub-work` — `WorkEventTypeTest` needs updating for SubscribableEvent + marshallerKeys · S · Low
- `casehub-engine` — #176: engine-api expression types migrate to platform SPI · M · Med

## What's Left

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
| #176 | Engine expression migration to platform SPI | M | Med | Engine adapts to platform's ExpressionEngine/Registry |
| #177 | MVEL Map and List context support | S | Low | |
| #178 | MVEL block expressions | S | Low | |

## References

| Type | Path |
|------|------|
| Spec | `docs/specs/2026-07-16-delivery-engagement-tracking-design.md` |
| Blog | `blog/2026-07-17-mdp01-engagement-tracking-missing-half.md` |
| PR | casehubio/platform#182 (merged) |
| Review | `~/adr/casehub-platform/delivery-engagement-tracking-20260716-180937/` (spec review) |
| Review | `~/adr/casehub-platform/delivery-engagement-tracking-final-20260717-141212/` (final review) |
