# HANDOFF — Slot 30: Retire Reactive Tiers (#384)

**Issue:** casehubio/parent#384
**Slot:** `/Users/mdproctor/claude/casehub/worktrees/30/`
**Branch:** `issue-384-retire-reactive` (all repos)
**Cookbook:** `engine/docs/guides/virtual-thread-migration.md`

## What's Done

| Repo | Status | Notes |
|------|--------|-------|
| **platform** | Merged | casehubio/platform#194 |
| **ras** | Merged | casehubio/casehub-ras#54 |
| **connectors** | Clean | Zero reactive code |
| **claudony** | Clean | Zero reactive code |
| **openclaw** | Clean | Zero reactive code |
| **blocks** | Clean | Zero reactive code |
| **ledger** | Committed | 40 files, 2329 lines deleted |
| **eidos** | Committed | 50 files, 2245 lines deleted. Also fixed SettingsScope.root() (platform #193 API change) |
| **qhorus** | Committed | 103 files, 9574 lines deleted. Dashboard service rewritten to blocking. Pre-existing connector-backend SRCFG00050 test failure (unrelated) |
| **ops** | PR open | casehubio/casehub-ops#63 — different issue (#10,#21), not #384 |
| **desiredstate** | PR open | casehubio/casehub-desiredstate#88 — CI failing: SettingsScope.root() API change |
| **iot** | PR open | casehubio/iot#70 — CI failing: Worker.Builder.function() type mismatch |

## What's Left — Neocortex

**Architecture difference:** Neocortex is reactive-primary. Unlike every other repo where blocking owns the logic and reactive wraps it, neocortex's reactive implementations ARE the real code (Qdrant gRPC, Mem0 REST, Graphiti REST). Blocking classes are thin `.await().indefinitely()` wrappers.

**The cookbook doesn't apply.** Cannot "delete reactive, keep blocking." Must convert reactive → blocking in-place.

### Conversion plan (3 categories)

**Category 1 — Straight deletion (~36 files):**
Reactive SPI interfaces (10), bridges (6), InMemory reactive wrappers (2), parity tests (~18). Same mechanical pattern as other repos.

**Category 2 — Backend conversion (3 backends, ~1hr each):**
- **Qdrant:** `ReactiveQdrantCbrCaseMemoryStore` → `QdrantCbrCaseMemoryStore`. Convert `QdrantFutures.toUni(future)` → `future.get()`. Delete thin blocking wrapper.
- **Mem0:** `ReactiveMem0CaseMemoryStore` → `Mem0CaseMemoryStore`. Create blocking `Mem0Client` interface (drop `Uni<>` from return types). Delete thin blocking wrapper.
- **Graphiti:** Same pattern as Mem0 — `ReactiveGraphitiClient` → blocking `GraphitiClient`.

**Category 3 — Decorator chain (4 decorators):**
ReactiveTemporalDecay, ReactiveOutcomeWeighting, ReactiveScopeDecay, ReactiveTrendEnrichment. Check if blocking decorators exist — if yes, just delete reactive. If not, convert.

### Execution order
1. Category 1 first (mechanical deletion)
2. Category 2 backend-by-backend (Qdrant → Mem0 → Graphiti)
3. Category 3 last
4. POM cleanup (11 mutiny deps already identified)
5. Build and verify

**Garden entry:** GE-20260724-115ce0 documents the gotcha.

## Open PRs Needing Attention

- **desiredstate #88** and **iot #70** — CI failing from upstream API changes (SettingsScope, WorkerFunction), not from #384 work. Need rebase onto latest main.
- **Engine #381** — delivered locally, PR still open. Once merged, CI for all downstream repos will pass.

## Artifacts

- **Blog:** `2026-07-24-mdp01-twelve-out-of-thirteen.md` (workspace)
- **Garden:** GE-20260724-115ce0 (neocortex reactive-primary gotcha), GE-20260724-c35265 (IntelliJ safe_delete line shift)
- **Protocol:** `sse-endpoint-no-virtual-thread` (prior session, unchanged)
