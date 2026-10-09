# Concurrency Patterns: CaseHub vs SWF 1.0

Side-by-side comparison of every concurrency pattern. SWF 1.0 examples
verified against the CNCF sdk-java test fixtures (`~/dev/swf-sdk-java`).

---

## Pattern 1: Parallel Execution (Fork/Join All)

Run N tasks concurrently, wait for all to complete.

**SWF 1.0:**
```yaml
do:
  - runBoth:
      fork:
        compete: false
        branches:
          - enrichCustomer:
              do:
                - enrich:
                    call: http
                    with:
                      method: get
                      endpoint: /api/customer/${.customerId}
          - checkCredit:
              do:
                - check:
                    call: http
                    with:
                      method: get
                      endpoint: /api/credit/${.customerId}
```

**CaseHub:**
```yaml
- parallel:
    - action: enrich-customer
    - action: check-credit
```

**Lines:** SWF 15, CaseHub 3. The SWF version requires `fork:`,
`compete: false`, `branches:`, named branch entries, nested `do:`
inside each branch, and named tasks inside each `do:`. CaseHub lists
the steps.

---

## Pattern 2: Race (First Wins)

Run N tasks concurrently, take the first result, cancel the rest.

**SWF 1.0:**
```yaml
do:
  - raceVenues:
      fork:
        compete: true
        branches:
          - queryVenueA:
              call: http
              with:
                method: get
                endpoint: /api/venue-a/price
          - queryVenueB:
              call: http
              with:
                method: get
                endpoint: /api/venue-b/price
```

**CaseHub:**
```yaml
- select:
    - action: query-venue-a
      signal: venue-response
    - action: query-venue-b
      signal: venue-response
```

**Lines:** SWF 13, CaseHub 5. Both express the race concept. SWF
uses `compete: true` on `fork:`. CaseHub uses `select:` (race
step type). Comparable verbosity for simple cases.

---

## Pattern 3: Parallel with Per-Branch Error Handling

Run N tasks, each with its own retry policy.

**SWF 1.0:**
```yaml
do:
  - processAll:
      fork:
        compete: false
        branches:
          - enrichBranch:
              do:
                - enrichWithRetry:
                    try:
                      - enrich:
                          call: http
                          with:
                            method: get
                            endpoint: /api/enrich
                    catch:
                      errors:
                        with:
                          type: https://serverlessworkflow.io/errors/communication
                      retry:
                        delay: PT1S
                        limit:
                          attempt:
                            count: 3
          - scoreBranch:
              do:
                - scoreWithRetry:
                    try:
                      - score:
                          call: http
                          with:
                            method: get
                            endpoint: /api/score
                    catch:
                      errors:
                        with:
                          type: https://serverlessworkflow.io/errors/communication
                      retry:
                        delay: PT2S
                        backoff:
                          exponential: {}
                        limit:
                          attempt:
                            count: 5
```

**CaseHub:**
```yaml
- parallel:
    - action: enrich
      retry: { max: 3, delay: 1s, on: [TIMEOUT] }
    - action: score
      retry: { max: 5, delay: 2s, backoff: exponential, on: [TIMEOUT] }
```

**Lines:** SWF 38, CaseHub 4. This is where the composition model
divergence hits hardest. SWF nests `try:` inside `do:` inside each
`branch:` inside `fork:`. Each retry policy adds ~10 lines of
structural nesting. CaseHub puts `retry:` as a decorator on each step
— one line per policy.

---

## Pattern 4: Background Task (Spawn and Continue)

Start a long-running task, continue immediately with other work.

**SWF 1.0:**
```yaml
# SWF has no spawn concept. The closest emulation:
do:
  - runConcurrently:
      fork:
        compete: false
        branches:
          - backgroundBranch:
              do:
                - monitor:
                    for:
                      each: tick
                      in: '.ticks'
                      while: '.running'
                    do:
                      - poll:
                          call: http
                          with:
                            method: get
                            endpoint: /api/sensor
                      - delay:
                          wait:
                            seconds: 30
          - mainBranch:
              do:
                - step1:
                    call: process-step-1
                - step2:
                    call: process-step-2
                - step3:
                    call: process-step-3
```

**CaseHub:**
```yaml
# Background monitoring — doesn't block
- action: poll-sensor
  loop: continuous
  delay: 30s
  background: true

# Main work — runs immediately
- action: process-step-1
- action: process-step-2
- action: process-step-3
```

**Lines:** SWF 24, CaseHub 8. More importantly, SWF requires
restructuring the entire workflow into a `fork:` with two branches —
the main flow and the background task. Adding a background task to an
existing SWF workflow means wrapping everything in a fork. CaseHub
adds `background: true` — no restructuring.

And SWF's version isn't truly "background" — `fork: compete: false`
waits for ALL branches. The main branch would have to complete AND the
background loop would have to stop. In CaseHub, `background: true`
returns immediately and the spawned task is scope-bounded.

---

## Pattern 5: Priority-Aware Resource Contention

Two tasks compete for the same resource, higher priority wins.

**SWF 1.0:**
```yaml
# NOT EXPRESSIBLE in SWF 1.0.
# SWF has no concept of:
#   - Named resources with concurrency limits
#   - Priority-based acquisition ordering
#   - Yielding between concurrent tasks
#
# The closest emulation requires an external
# resource manager service called via HTTP:
do:
  - runProduction:
      fork:
        compete: false
        branches:
          - probeBranch:
              do:
                - acquireMinerals:
                    call: http
                    with:
                      method: post
                      endpoint: /api/resources/minerals/acquire
                      body:
                        priority: background
                - trainProbe:
                    call: train-probe
                - releaseMinerals:
                    call: http
                    with:
                      method: post
                      endpoint: /api/resources/minerals/release
          - pylonBranch:
              do:
                - acquireMinerals:
                    call: http
                    with:
                      method: post
                      endpoint: /api/resources/minerals/acquire
                      body:
                        priority: high
                - buildPylon:
                    call: build-pylon
                - releaseMinerals:
                    call: http
                    with:
                      method: post
                      endpoint: /api/resources/minerals/release
```

**CaseHub:**
```yaml
resources:
  minerals: { concurrency: 1 }

steps:
  - train: PROBE
    resource: minerals
    priority: background

  - build: PYLON
    resource: minerals
    priority: high
```

**Lines:** SWF 30+ (with external service), CaseHub 8. And the SWF
version doesn't actually implement priority — the external resource
service would need a priority queue, which doesn't exist as a standard
service. CaseHub's `PriorityOrcSemaphore` handles this natively. This
pattern is fundamentally not expressible in SWF 1.0 without external
infrastructure.

---

## Pattern 6: Continuous Loop with Cancellation

Repeat a task indefinitely, stop when an external signal fires.

**SWF 1.0:**
```yaml
do:
  - monitor:
      for:
        each: iteration
        in: '.iterations'
        while: '.cancel_flag != true'
      do:
        - readSensor:
            call: http
            with:
              method: get
              endpoint: /api/sensor
        - pause:
            wait:
              seconds: 30
      # But: how is .cancel_flag set?
      # Requires an external event to modify workflow data.
      # The loop checks the flag per iteration (polling).
      # No event-driven interruption within an iteration.
```

**CaseHub:**
```yaml
- action: read-sensor
  loop: continuous
  cancel: shutdown-signal
  delay: 30s
  background: true
```

**Lines:** SWF 14, CaseHub 5. But the important difference:
SWF polls a data flag per iteration — if the loop body takes 30
seconds, the cancel is delayed up to 30 seconds. CaseHub's `cancel:`
is event-driven — the signal interrupts the current iteration
immediately via thread interruption (then clears the interrupt status).

SWF also requires `.iterations` to be a pre-defined list to iterate
over with `for: each:` — there's no "loop forever" in SWF 1.0. The
`while:` condition prevents advancing to the next item, but `in:`
must be a finite collection. CaseHub's `loop: continuous` is a true
infinite loop.

---

## Pattern 7: Threshold-Gated Execution

Wait until a metric crosses a threshold, then execute.

**SWF 1.0:**
```yaml
# NOT EXPRESSIBLE in SWF 1.0.
# SWF has no concept of watching a live value.
# The closest emulation: poll an external service.
do:
  - waitForSupply:
      for:
        each: poll
        in: '.polls'
        while: '.supply < 14'
      do:
        - checkSupply:
            call: http
            with:
              method: get
              endpoint: /api/game/supply
            output:
              as: '.supply'
        - pause:
            wait:
              milliseconds: 100
  - buildPylon:
      call: build-pylon
```

**CaseHub:**
```yaml
- build: PYLON
  at: >=14 supply
```

**Lines:** SWF 16, CaseHub 2. SWF polls an external service in a
loop with 100ms delay. CaseHub registers a callback on the counter —
zero-latency, zero-waste, fires immediately when the threshold is
crossed. The SWF version also requires the supply value to be
externalized as an HTTP endpoint; CaseHub's supply counter is an
in-process primitive updated by other steps.

---

## Pattern 8: Cancellable Group (Structural Cancellation)

Start a group of concurrent tasks, cancel all when a condition is met.

**SWF 1.0:**
```yaml
# Partially expressible via fork + compete:
do:
  - productionPhase:
      fork:
        compete: true
        branches:
          - probeProduction:
              do:
                - trainLoop:
                    for:
                      each: i
                      in: '.iterations'
                      while: '.worker_count < 22'
                    do:
                      - train:
                          call: train-probe
          - pylonProduction:
              do:
                - buildLoop:
                    for:
                      each: i
                      in: '.iterations'
                      while: '.worker_count < 22'
                    do:
                      - build:
                          call: build-pylon
          - canceller:
              do:
                - watchWorkers:
                    for:
                      each: poll
                      in: '.polls'
                      while: '.worker_count < 22'
                    do:
                      - check:
                          call: http
                          with:
                            method: get
                            endpoint: /api/game/workers
                          output:
                            as: '.worker_count'
# compete: true means first branch to complete cancels others.
# The canceller branch "wins" when worker_count >= 22.
# But: each production branch ALSO checks the condition — redundant.
# And: the cancellation is branch-completion-based, not signal-based.
```

**CaseHub:**
```yaml
- block:
    cancel: max-workers
    steps:
      - train: PROBE
        loop: continuous
        resource: nexus
        background: true
      - build: PYLON
        loop: continuous
        at: supply-blocked
        background: true

- action: set-flag
  at: >=22 workers
  signal: max-workers
```

**Lines:** SWF 34, CaseHub 12. SWF emulates group cancellation by
racing a "canceller" branch against the production branches using
`compete: true`. Every branch must independently check the cancellation
condition. CaseHub fires one signal that cascades to the entire block
scope — clean, immediate, no redundant condition checks.

---

## Summary

| Pattern | SWF 1.0 Lines | CaseHub Lines | Ratio | SWF 1.0 Expressible? |
|---------|--------------|---------------|-------|---------------------|
| Parallel (fork/join) | 15 | 3 | 5:1 | Yes |
| Race (first wins) | 13 | 5 | 2.6:1 | Yes |
| Parallel + per-branch retry | 38 | 4 | 9.5:1 | Yes (verbose) |
| Background (spawn) | 24 | 8 | 3:1 | Emulated (not true spawn) |
| Priority contention | 30+ | 8 | 4:1 | Not expressible |
| Continuous + cancel | 14 | 5 | 2.8:1 | Partial (polling, not event) |
| Threshold gate | 16 | 2 | 8:1 | Not expressible (polling emulation) |
| Cancellable group | 34 | 12 | 2.8:1 | Emulated (compete, redundant checks) |

**Average verbosity ratio: ~4.7:1.** CaseHub is roughly 5x more
concise for concurrency patterns.

**Expressibility:** Of 8 patterns, SWF 1.0 fully supports 3, partially
emulates 3, and cannot express 2 (priority contention, threshold gates).
CaseHub expresses all 8 natively.
