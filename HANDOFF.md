# HANDOFF — casehub-platform

**Date:** 2026-07-12
**Project:** `/Users/mdproctor/claude/casehub/platform`
**Workspace:** `/Users/mdproctor/claude/public/casehub/platform`

---

## Last Session

Closed 8 issues in a single batch branch (#171, #139, #172, #164, #165, #167, #168, #169). Created 3 new modules (datasource-alpha, datasource-jpa, delivery-channel-inmem), added MarshallerRegistry SPI and DataSource descriptor update mechanism, relocated UUIDv7, added digest buffer retention and BUFFER_FOR_DIGEST validation. Two design reviews ($17.46 spec review + $6.27 final review) caught 40 issues total — all resolved. Landed as b0e873f on main.

## Immediate Next Step

Pick from What's Next — #146 notification center frontend or #170 delivery engagement tracking. Domain notification bridges (casehub-work, casehub-engine) still need filing as cross-repo issues.

## Cross-Module

**We're blocking:**
- `casehub-work` — `WorkEventTypeTest` needs updating for new notification/subscription event types + marshallerKeys parameter on DataSourceDescriptor · S · Low

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
| Spec | `docs/specs/2026-07-12-spi-batch-cleanup-design.md` |
| Review | `~/adr/casehub-platform/spi-batch-cleanup-20260712-170638/` (spec) |
| Review | `~/adr/casehub-platform/spi-batch-cleanup-final-20260712-220652/` (final) |
| Garden | `GE-20260712-44faae` — ide_move_file bulk moves leave stale intra-package imports |
