# HANDOFF — casehub-platform

**Date:** 2026-07-13
**Project:** `/Users/mdproctor/claude/casehub/platform`
**Workspace:** `/Users/mdproctor/claude/public/casehub/platform`

---

## Last Session

Closed 4 S-scale issues in a single batch branch. Identity: fixed base58btc encoding (#131) and added secp256k1 did:key support (#133) — manual SPKI ASN.1, no JCA. Subscriptions: added SubscribableEvent compile-time contract (#153) replacing MethodHandle reflection, plus glob matching for event type patterns (#152). Landed as 0fd6273 on main.

## Immediate Next Step

Pick from What's Next — #146 notification center frontend or #170 delivery engagement tracking. Consumer migration issues filed: engine#713, work#302.

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
| Garden | `GE-20260713-14473f` — LEB128 varint gotcha |
