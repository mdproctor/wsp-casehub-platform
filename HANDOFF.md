# HANDOFF — issue-829-decorator-semantics

**Branch:** `issue-829-decorator-semantics`
**Covers:** #829 (WS-2: Specify and fix decorator semantics)
**Progress:** All 8 findings addressed. Code review clean. Blog written. Follow-up issues filed.

## What Happened

Specified contracts and fixed bugs for 7 decorators in `DecoratorChain`:

1. **P39-6 — when guard:** Added `Result.Skipped` variant to sealed interface. `when: false` now returns `Result.skipped()` instead of empty success. `isSuccess()` returns true (flow control continues), `isSkipped()` distinguishes.
2. **P38 — timeout:** Removed try-with-resources on executor. `shutdownNow()` on timeout, `shutdown()` on success. No longer blocks forever on uninterruptible steps.
3. **P39-4 — cancel:** `AtomicBoolean cancelFired` tracks whether the cancel watcher caused the interrupt. Only clears the interrupt flag when cancel was responsible.
4. **P39-2 — retry:** Changed `failCat != null &&` to `failCat == null ||` — uncategorised failures no longer bypass the `on` filter.
5. **P39-1 — loop:** Until loops that exhaust their iteration cap now return failure instead of silent success.
6. **P39-3 — forEach parallel:** Fail-fast via `AtomicReference<Result>` with future cancellation. Optional `concurrency` parameter via `Semaphore`.
7. **P39-5 — background:** Conformance tests documenting fire-and-forget contract.

## Commits

1. `121ee0a5` feat(#829): add Result.Skipped variant, fix when guard to return skipped
2. `c23c17d9` fix(#829): timeout returns immediately when step ignores interruption
3. `eba1cf4e` fix(#829): cancel decorator preserves external interrupts
4. `70f2da9e` fix(#829): retry stops on uncategorised failures when on filter is active
5. `d8819bce` fix(#829): loop returns failure when until condition never met
6. `a3d8868b` feat(#829): forEach parallel fail-fast and concurrency bound
7. `ae60ca76` test(#829): add background decorator conformance tests
8. `d685867c` fix(#829): Result.Skipped preserves flow control, adds isSkipped()
9. `1ccfb898` fix(#829): review fixes — executor shutdown on success, Skipped singleton

## Follow-up Issues Filed

- #841 — parallel structural step needs concurrency bound and fail-fast (S/Low)
- #842 — background decorator error observability (S/Med)
- #843 — configurable iteration cap for until loops (XS/Low)

## Next Action

Run `work end` to close the branch.
