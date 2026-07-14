# HANDOFF — casehub-platform

**Date:** 2026-07-13
**Project:** `/Users/mdproctor/claude/casehub/platform`
**Workspace:** `/Users/mdproctor/claude/public/casehub/platform`

---

## Last Session

Added system subscriptions (#150) — SubscriptionScope discriminator (USER/SYSTEM) with admin authorization. SYSTEM scope subscriptions are tenant-wide, managed by subscription-admins group, visible to all tenant users. OR-disjunction store queries, CHECK constraint on scope column, REST admin gate with $me and empty-targets validation. Design-reviewed (14 issues, all verified) and final-reviewed (9 issues, all fixed). Landed as 99f9b68 on main.

## Immediate Next Step

Pick from What's Next — #170 delivery engagement tracking or #151 expression-based subscription filters. Consumer migration issues still open: engine#713, work#302.

## Cross-Repo Changes (from other sessions)

- **Branch:** `issue-77-promote-preference-types` — `e74a86d` — adds `DoublePreference` and `IntPreference` to `io.casehub.platform.api.preferences` (platform-api). Promoted from engine-api and desiredstate-api duplicates. Filed from desiredstate session for casehubio/casehub-desiredstate#77. Needs merge to main.

## Cross-Module

**We're blocking:**
- `casehub-engine` — engine#713: migrate to `Vectors.cosineSimilarity()` · XS · Low
- `casehub-work` — work#302: migrate to `Vectors.cosineSimilarity()` · XS · Low
- `casehub-work` — `WorkEventTypeTest` needs updating for SubscribableEvent + marshallerKeys · S · Low

## What's Left

**Epic #137 — DataSource SPI follow-up:**
- #141 MVEL3 real evaluator · S · Low (blocked on Maven Central publish)

**Epic #147 — Notification deferred:**
- #170 Open/engagement tracking · M · Med
- #151 Expression-based subscription filters · S · Med

**Other:**
- casehubio/neocortex#101 — bridge-only reactive implementations · M · Med
- Domain notification bridges (casehub-work, casehub-engine, casehub-iot) — not yet filed · S · Low each

## What's Next

| # | Description | Scale | Complexity | Notes |
|---|-------------|-------|------------|-------|
| #170 | Open/engagement tracking | M | Med | Email opens, push taps — deferred from #154 |
| #151 | Expression-based subscription filters | S | Med | JQ path works now; MVEL path blocked |
| #146 | Notification center frontend | L | Med | Remaining: blocks-ui#33, blocks-ui#34 |
| #141 | MVEL3 real evaluator | S | Low | Blocked on Maven Central publish |

## References

| Type | Path |
|------|------|
| Spec | `specs/2026-07-13-system-subscriptions-design.md` |
| Review | `~/adr/casehub-platform/system-subscriptions-20260713-203449/` |
| Garden | `GE-20260713-14473f` — LEB128 varint gotcha |
