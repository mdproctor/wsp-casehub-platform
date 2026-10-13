# HANDOFF — Slot 198

## Status

**Branch:** issue-564-from-decorator (platform only — yaml-core changes)
**Active issue:** platform#564 — Playbook streams: from: decorator
**State:** Scaffolded — branch, .plan, and task breakdown created. No implementation yet.

## Queue

1. casehubio/platform#564 — Playbook streams: from: decorator (M/Med) ← active

## Context

### What this issue adds

One new decorator (`from:`) for the playbook YAML language. It reads one item from an `OrcChannel` per step invocation, enabling stream processing patterns without a stream DSL.

**Syntax variants:**
```yaml
# Simple — read from named channel
from: channel-name

# Full — channel + alias + pre-filter
from: { channel: raw-readings, as: reading, filter: "${reading.value} > ${threshold}" }

# Fan-in — merge multiple channels
from: { channels: [fire-alerts, flood-alerts], as: alert }
```

Plus a minor extension: `publish:` accepts a list with per-channel conditions for fan-out.

### Prerequisites (both landed)

- #562 — at:, on-complete:, resource:/priority: decorators (CLOSED)
- #563 — loop continuous, cancel, background, forEach collect, conditional retry (CLOSED)

### Key files

| File | Purpose |
|------|---------|
| `yaml-core/.../orchestration/OrcChannel.java` | Channel primitive — the from: decorator reads from this |
| `yaml-step-runtime/.../eval/DecoratorChain.java` | Decorator ordering — from: goes at position 7 |
| `yaml-step-runtime/.../catalog/StepSchemaComposer.java` | Schema composition — needs from: added |
| Issue body (platform#564) | Full design spec with decorator chain position, syntax, patterns |

### DecoratorChain position

The from: decorator sits at position 7 in the chain:
```
5. loop        ← repetition (wraps from:)
6. on-error    ← error handling
7. from        ← NEW: read one item from channel
8. timeout     ← per-item timeout
9. at          ← threshold gate
```

### Task breakdown

**Batch 1: Core from: decorator**
- Task 1: `FromDecorator` — blocking read from OrcChannel, inject as `${from.*}`
- Task 2: Filter support — `from: { channel: x, filter: expr }` pre-filter
- Task 3: Alias support — `from: { channel: x, as: alias }` injects as `${alias.*}`

**Batch 2: Fan-in and fan-out**
- Task 4: Fan-in — `from: { channels: [a, b] }` reads from whichever has data first
- Task 5: `publish:` list extension — `[{channel: x, if: expr}]` conditional fan-out

**Batch 3: Integration**
- Task 6: DecoratorChain position — insert at slot 7
- Task 7: StepSchemaComposer update — add from: to JSON schema
- Task 8: ADR-0011 keyword registration

**Batch 4: Testing**
- Task 9: Unit tests — channel read, filter, alias, fan-in, backpressure
- Task 10: Integration test — pipeline pattern (source → filter → sink)

### Design notes from the issue

- `from:` reads one item per invocation via blocking `OrcChannel.receive()`
- Filter pre-filters inside the decorator — items failing filter are discarded and next item read
- Fan-in uses whichever channel has data first (select semantics)
- `publish: [{channel: x, if: expr}]` — list form with per-channel conditions
- Backpressure via bounded channel capacity (existing OrcChannel behaviour)
- No explicit yield keyword — virtual threads yield automatically
- Windowed aggregation is a plugin concern, not a language primitive

## Prior Work (landed this session)

- engine#1214 — SSE broadcasters SseEmitter bridge (platform generators + engine broadcasters)
- engine#1215 — Scope extractor, rest-core extraction, integration-test mocks
- workers#29 — Script + Camel Spring auto-configs
- workers#30 — spring-generator verify drift detection for 7 worker modules
- Commented on engine#1222 re: @PlatformStream generator fix overlap

## References

- Issue: casehubio/platform#564 (full design spec in issue body)
- OrcChannel: `yaml-core/src/main/java/io/casehub/yaml/core/orchestration/OrcChannel.java`
- DecoratorChain: `yaml-step-runtime/src/main/java/io/casehub/yaml/step/eval/DecoratorChain.java`
- StepSchemaComposer: `yaml-step-runtime/src/main/java/io/casehub/yaml/step/catalog/StepSchemaComposer.java`
