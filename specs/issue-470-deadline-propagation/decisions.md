# Decisions — #470 Deadline Propagation

## D1: Deadline propagation mechanism

**Choice:** StepContext — explicit threading of deadline info through the execution chain
**Alternatives:**
- InheritableThreadLocal — zero interface changes but implicit state; developers can't see deadline in method signatures and may forget to check it
- Scope threading — thread ScenarioScope itself through execution; complicated by result store isolation (child scope gets its own store, breaking cross-step result visibility)
- Scope-level pushDeadline — mutable deadline on shared scope; concurrency issues with parallel steps
**Rationale:** Explicit state propagation makes deadline awareness visible in the type system. A developer adding a new decorator sees `StepContext ctx` and knows deadline info is available. The compiler enforces threading. The refactoring is mechanical (~25 signatures across 2 files) and the clarity benefit is permanent.
**Trade-offs:** More verbose lambdas (ctx instead of resolver). Every decorator touches the StepContext even if most just pass it through.
**Sources:** DecoratorChain.java, StructuralStepEvaluator.java, Go context.Context model, gRPC deadline propagation
**Exploration:** deep-analysis
**Status:** captured

## D2: Nested timeout semantics

**Choice:** min(parent remaining, child timeout) — automatic via DeadlineContext.withTimeout() using Math.min
**Alternatives:**
- Independent child timeouts — child keeps its full timeout regardless of parent remaining. Violates real-world deadline semantics.
**Rationale:** A child cannot outlive its parent. This is how Go context, gRPC, and structured concurrency all work. Falls out naturally from `Math.min(parentDeadlineNanos, now + childTimeoutNanos)`.
**Trade-offs:** None — this is the only correct behavior.
**Sources:** Go context.WithTimeout, gRPC deadline propagation, DefaultScenarioScope.withDeadline
**Exploration:** quick
**Status:** captured

## D3: Blocking primitive deadline awareness

**Choice:** Cooperative — timed variants on OrcSignal.await and OrcSemaphore.tryAcquire, checked via ctx.deadline().remainingTime()
**Alternatives:**
- Interrupt-only — rely on Future.cancel(true) to interrupt blocked primitives. Works but produces "interrupted" errors instead of "deadline exceeded". Less responsive.
**Rationale:** Developers expect `wait:` and `semaphore:` inside a `timeout:` block to respect the deadline cooperatively. Clear "deadline exceeded" errors are more debuggable than opaque "interrupted" errors.
**Trade-offs:** Requires additive yaml-core changes (timed default methods on OrcSignal and OrcSemaphore interfaces). Zero-dep constraint preserved — uses j.u.c underneath.
**Sources:** OrcSignal interface, OrcSemaphore interface, DefaultOrcSignal (CountDownLatch), DefaultOrcSemaphore (j.u.c.Semaphore)
**Exploration:** quick
**Status:** captured
