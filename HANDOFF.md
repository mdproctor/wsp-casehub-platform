# HANDOFF — casehub-platform

**Date:** 2026-06-29
**Project:** `/Users/mdproctor/claude/casehub/platform`
**Workspace:** `/Users/mdproctor/claude/public/casehub/platform`

---

## Last Session

Shipped #125. `ChatModelAgentProvider` now has a fail-fast semaphore (`max-concurrent-sessions`, default 10) gating both `invoke()` and `openSession()`. Sessions hold permits until `close()` via `getAndSet(CLOSED)`. Query failures stay IDLE — stateless HTTP APIs are retry-safe. Five-round adversarial design review drove 14 spec fixes before implementation.

## Immediate Next Step

No blockers. Pick from What's Next — #85 is the only remaining tracked issue (blocked).

## What's Next

| # | Description | Scale | Complexity | Notes |
|---|-------------|-------|------------|-------|
| #85 | ScimDIDResolver — synthetic DID from SCIM | M | Med | Blocked by ledger#107 |

## References

- Spec: `docs/superpowers/specs/2026-06-29-chatmodel-concurrency-limiter-design.md`
- Plan: `docs/superpowers/plans/2026-06-29-chatmodel-concurrency-limiter.md`
- Blog: `blog/2026-06-29-mdp01-the-semaphore-that-was-already-there.md`
