# HANDOFF — casehub-platform

**Last closed:** #829 (WS-2: Specify and fix decorator semantics)
**Landed:** `5a764cd` on main, published to origin
**Status:** Queue active, 25 items remaining

## What #829 delivered

Specified contracts and fixed bugs for 7 decorators in `DecoratorChain`:

- **Result.Skipped** — new sealed interface variant; `isSuccess()=true` (flow control continues), `isSkipped()=true` for distinction. Singleton constant.
- **timeout** — no longer blocks forever on uninterruptible steps; `shutdownNow()` on timeout, `shutdown()` on success
- **cancel** — `AtomicBoolean cancelFired` preserves external interrupts; only clears when cancel signal was responsible
- **retry** — `failCat == null ||` stops uncategorised failures from bypassing the `on` filter
- **loop** — until loops that exhaust iterations now return failure
- **forEach parallel** — fail-fast cancel + `concurrency` semaphore parameter
- **background** — conformance tests documenting fire-and-forget contract

Blog: "Seven Decorators, Seven Contracts"

## Follow-up issues filed

- #841 — parallel structural step needs concurrency bound and fail-fast (S/Low)
- #842 — background decorator error observability (S/Med)
- #843 — configurable iteration cap for until loops (XS/Low)

## Next in queue

#725 — fix: CLI --dry-run should discover simulation.yaml from directory hierarchy
