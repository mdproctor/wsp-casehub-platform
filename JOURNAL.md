# Design Journal — epic-502-yaml-parity

## 2026-10-01 — TS parity batch + platform StepWalker alignment

### CorrelationScope rewrite (pages#480)

Rewrote the TS CorrelationScope from push-based (`deliver()`) to channel-driven
(listener loop on OrcChannel), matching Java's design. Key decisions:

- **Key extraction over pattern matching** — Java uses `Function<V, K>` for O(1) Map
  lookup. The old TS used MatchPattern iteration (O(n)). Key-based is correct for
  correlation — you're matching on a request ID, not a pattern.
- **Timeout at registration** — Java sets timeout in `expectResponse()`, not `await()`.
  This catches scenarios where processing between expect and await takes too long.
- **Promise swallowing** — internal promises need `.catch(() -> {})` to prevent
  unhandled rejection errors when the scope closes before `awaitResponse` is called.
  Java's CompletableFuture doesn't have this constraint.

### ScenarioScope speedMultiplier (pages#481)

Added `speedMultiplier()` to the ScenarioScope interface and DefaultScenarioScope.
Propagates to childScope and withDeadline. Simplified correlationScopeForScope to
use the proper interface method instead of duck-typing.

Also added `registerPrimitive(name, instance)` to DefaultScenarioScope — Java has
this for externally-constructed primitives. TS was missing it.

### Walker path context (pages#482) and match case alignment (pages#483)

Added path context (`root → Step 0 → then → Step 1`) to all Walker error messages.
The name uniqueness and ref validation were already implemented — only path strings
were missing.

Fixed match case default handling: removed `'default'` and `'_'` as magic pattern
values in parsePattern. Default case is now only via the `'default'` key (steps
directly), matching Java exactly. Added validation that each case must have
`pattern`/`when` or `default` (not both, not neither).

### Already-resolved issues

484, 485, 486, 487, 488, 489 were all already implemented. The parity gap was
smaller than the issue list suggested — previous sessions had already done the work.

### Platform: StepWalker `do` key (platform#496)

Changed Java StepWalker from `"steps"` to `"do"` for match case and select branch
child action lists. Fail-fast error when old `"steps"` key is used. Aligns with TS
convention where `steps` is a removed key.
