# Design — Generated Typed Event Dispatch (Layer 3)

Issue: casehubio/platform#424
Epic: casehubio/platform#502 (YAML cross-repo parity)
Decisions: D32–D36 in `decisions.md`

## Purpose

An optional performance optimisation for YAML state machine execution. The
existing runtime-interpreted path (ScenarioCompiler → EventRouter → string
matching) remains the default. When a Maven plugin has generated typed
dispatch code from the same YAML at build time, the runtime can use the
generated path instead — compile-time pattern matching on sealed event
types rather than runtime string matching.

No new YAML format. No new end-user capability. The optimisation is
invisible to YAML authors. This establishes a pattern for future generated
optimisations of other YAML execution areas.

## Architecture

### Three-layer state machine (recap from #410 D8)

```
Layer 1: OrcStateMachine<S>     — state + transitions, CAS, handlers
Layer 2: EventRouter<S>         — string-based dispatch (runtime, interpreted)
Layer 3: Generated dispatch     — typed dispatch (compile-time, generated)
```

Layers 2 and 3 are **parallel alternatives**, both wrapping Layer 1
directly. The generated `switch` expression replaces what EventRouter does
— it maps events to transitions. Both call `transition()` on the same
OrcStateMachine, so blocking semantics, handlers, and CAS atomicity work
identically regardless of which path initiates the transition.

### YAML input — existing format, no changes

The generator reads the same YAML that ScenarioParser reads. The existing
`events:` key in the `on:` blocks defines event names and transitions.
The generator extracts the state machine structure (states, events,
transitions, guards) and ignores step definitions.

An optional top-level `events:` section provides typed field definitions
for event records. When present, the generator produces typed sealed
records. When absent, events are plain marker records with no fields.

```yaml
# Optional — enables typed event records
events:
  submit:
    fields:
      amount: number
      customer: string
  approve:
    fields:
      count: integer
      approver: string

# Existing format — unchanged
states:
  IDLE:
    - on:
        submit:
          to: PENDING
          when: "amount > 0"
    - validate.order: {}          # step — generator ignores
  PENDING:
    - on:
        approve:
          to: APPROVED
          when: "count >= 2"
        reject: REJECTED
  APPROVED: terminal
  REJECTED: terminal
```

### Generated output — full package

From the YAML above, the generator produces three artifacts:

**1. State enum**

```java
package io.casehub.generated.order;

public enum OrderState {
    IDLE, PENDING, APPROVED, REJECTED
}
```

State names derived from YAML keys, upper-cased. The initial state is
the first declared state.

**2. Sealed event hierarchy**

```java
package io.casehub.generated.order;

public sealed interface OrderEvent
    permits OrderEvent.Submit, OrderEvent.Approve, OrderEvent.Reject {

    record Submit(double amount, String customer) implements OrderEvent {}
    record Approve(int count, String approver) implements OrderEvent {}
    record Reject() implements OrderEvent {}
}
```

Events without an `events:` entry (like `reject`) become empty records.
Field type mapping: `number` → `double`, `integer` → `int`,
`string` → `String`, `boolean` → `boolean`.

**3. Typed dispatch class**

```java
package io.casehub.generated.order;

import io.casehub.yaml.core.orchestration.DefaultOrcStateMachine;
import io.casehub.yaml.core.orchestration.OrcStateMachine;
import static io.casehub.generated.order.OrderState.*;

public final class OrderDispatch {

    private final OrcStateMachine<OrderState> sm;

    private OrderDispatch(OrcStateMachine<OrderState> sm) {
        this.sm = sm;
    }

    public static OrderDispatch create() {
        var sm = DefaultOrcStateMachine.<OrderState>builder("order", IDLE)
            .transition(IDLE, PENDING)
            .transition(PENDING, APPROVED)
            .transition(PENDING, REJECTED)
            .terminal(APPROVED, REJECTED)
            .build();
        return new OrderDispatch(sm);
    }

    public static OrderDispatch wrapping(OrcStateMachine<OrderState> target) {
        return new OrderDispatch(target);
    }

    public OrderDispatch targeting(OrcStateMachine<OrderState> newTarget) {
        return new OrderDispatch(newTarget);
    }

    public boolean fire(OrderEvent event) {
        return switch (event) {
            case OrderEvent.Submit s
                when sm.currentState() == IDLE && s.amount() > 0
                -> sm.transition(IDLE, PENDING, s);
            case OrderEvent.Submit s
                -> false;
            case OrderEvent.Approve a
                when sm.currentState() == PENDING && a.count() >= 2
                -> sm.transition(PENDING, APPROVED, a);
            case OrderEvent.Approve a
                -> false;
            case OrderEvent.Reject r
                when sm.currentState() == PENDING
                -> sm.transition(PENDING, REJECTED, r);
            case OrderEvent.Reject r
                -> false;
        };
    }

    public OrderState currentState() { return sm.currentState(); }
    public OrcStateMachine<OrderState> delegate() { return sm; }
}
```

Key points:
- `create()` builds a fully configured OrcStateMachine with all transitions
- `wrapping()` accepts an externally provided state machine (e.g. blocking)
- `targeting()` retargets to a different state machine (same pattern as EventRouter)
- `fire()` uses exhaustive pattern matching — no `default` branch needed
  with sealed types. Each event type gets a guarded arm (with `when`) and
  an unguarded fallback returning `false`.
- Guards from YAML `when:` expressions are compiled to Java boolean
  expressions. Field references (`amount`, `count`) become accessor calls
  on the pattern variable.

### Guard compilation

YAML `when:` expressions are simple field-comparison expressions compiled
to Java:

| YAML | Java |
|------|------|
| `amount > 0` | `s.amount() > 0` |
| `count >= 2` | `a.count() >= 2` |
| `status == 'active'` | `s.status().equals("active")` |

The generator supports: field references, numeric comparisons (`>`, `>=`,
`<`, `<=`, `==`, `!=`), string equality, boolean literals, and `&&`/`||`
combinators. Complex guards that exceed this grammar are left as-is with
a `// TODO: manual guard` comment — the developer replaces them.

### Runtime discovery

The runtime needs a way to discover that generated dispatch exists for a
given scenario. The generator emits a service descriptor:

```
META-INF/yaml-dispatch/<scenario-name>.properties
```

```properties
dispatch-class=io.casehub.generated.order.OrderDispatch
state-enum=io.casehub.generated.order.OrderState
event-type=io.casehub.generated.order.OrderEvent
```

The runtime checks for this descriptor when compiling a scenario. If
found and on the classpath, it instantiates the generated dispatch. If
not found, it falls back to EventRouter. This discovery mechanism is
generic — future generators for other YAML areas follow the same pattern.

### Module structure

New module: `yaml-statemachine-generator`

- **Packaging:** `maven-plugin`
- **Goal:** `generate` bound to `generate-sources` phase
- **Dependencies:** yaml-core (for OrcStateMachine types), Jackson (YAML
  parsing), JavaPoet (source generation)
- **Configuration:** source directory for YAML files, output package prefix
- **No quarkus:build goal**

Follows the same pattern as `yaml-codegen` (Maven plugin, reads files,
generates source).

## Scope

### In scope
- Maven plugin that reads scenario YAML files
- Generates state enum, sealed event hierarchy, typed dispatch class
- Simple guard expression compilation
- META-INF descriptor for runtime discovery
- Tests verifying generated code matches interpreted behaviour

### Out of scope
- TypeScript generation (future — format supports it)
- Complex guard expressions beyond simple field comparisons
- Automatic runtime switching (runtime uses generated code only when
  explicitly configured — full auto-discovery is a follow-up)
- Changes to ScenarioParser or the existing YAML format

## References

- EventRouter.java — Layer 2 dispatch pattern (fire → transition)
- DefaultOrcStateMachine.java — Builder API for state machine construction
- ScenarioParser.java — existing YAML format
- ScenarioCompiler.java — runtime compilation path
- yaml-codegen/ — Maven plugin generator pattern
- #410 D8 — three-layer state machine architecture
- #502 — YAML unification epic
