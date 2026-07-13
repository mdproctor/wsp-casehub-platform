# HANDOFF — casehub-platform

**Date:** 2026-07-13
**Project:** `/Users/mdproctor/claude/casehub/platform`
**Workspace:** `/Users/mdproctor/claude/public/casehub/platform`

---

## Last Session

Delivered `Vectors` utility in `platform-api` (#134) — cosine similarity, dot product, magnitude for `float[]` arrays. Explicit `(double)` promotion for precision on high-dimensional embedding vectors. Design spec adversarially reviewed (5 rounds, $12.38). 18 tests. Landed as 1e77c33 on main.

## Immediate Next Step

Pick from What's Next — #146 notification center frontend or #170 delivery engagement tracking. Consumer migration issues filed: engine#713, work#302.

## Cross-Module

**We're blocking:**
- `casehub-work` — `WorkEventTypeTest` needs updating for new notification/subscription event types + marshallerKeys parameter on DataSourceDescriptor · S · Low
- `casehub-engine` — engine#713: migrate `SemanticAgentRoutingStrategy` to `Vectors.cosineSimilarity()` · XS · Low
- `casehub-work` — work#302: migrate `EmbeddingSkillMatcher` to `Vectors.cosineSimilarity()` · XS · Low

## What's Left

**Epic #137 — DataSource SPI follow-up:**
- #141 MVEL3 real evaluator · S · Low (blocked on Maven Central publish)

**Epic #147 — Notification deferred:**
- #170 Open/engagement tracking · M · Med

**Other:**
- casehubio/neocortex#101 — bridge-only reactive implementations · M · Med
- Domain notification bridges (casehub-work, casehub-engine, casehub-iot) — not yet filed · S · Low each

## What's Next

| # | Description | Scale | Complexity | Notes |
|---|-------------|-------|------------|-------|
| #146 | Notification center frontend | L | Med | Remaining: blocks-ui#33, blocks-ui#34 |
| #170 | Open/engagement tracking | M | Med | Email opens, push taps — deferred from #154 |
| #141 | MVEL3 real evaluator | S | Low | Blocked on Maven Central publish |

## References

| Type | Path |
|------|------|
| Spec | `docs/specs/2026-07-13-embedding-similarity-utility-design.md` |
| Review | `~/adr/casehub-platform/embedding-similarity-utility-*` (spec review) |
