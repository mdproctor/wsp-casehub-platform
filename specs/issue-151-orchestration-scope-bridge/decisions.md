# Decisions — OrchestrationScope Bridge

## D1: Scope topology

**Choice:** Bidirectional — graph-level root scope with per-node child scopes
**Alternatives:**
- Node-scoped only — simpler but no shared primitives across nodes
- Graph-scoped only — shared primitives but no node-private isolation
**Rationale:** The pool use case requires both. Node-private primitives (capacity semaphore, per-session state machines) must be isolated. Shared primitives (memory budget counter across pools) must be accessible from multiple nodes. ScenarioScope.childScope() already implements exactly this topology with deadline propagation.
**Trade-offs:** Slightly more lifecycle wiring in ReconciliationLoop/TransitionExecutor. Acceptable — the complexity is in the bridge, not the API surface.
**Sources:** ScenarioScope.java (yaml-core), ReconciliationLoop.java (desiredstate-runtime), pool agent use case
**Exploration:** quick
**Status:** captured

## D2: Dependency boundary

**Choice:** SPI in desiredstate-api — OrchestrationScope interface with no yaml-core dependency
**Alternatives:**
- Direct yaml-core dep in desiredstate-api — simpler wiring but couples the API module to an implementation
- Bridge in desiredstate-runtime only via CDI injection — keeps API unchanged but provisioners can't declare scope needs through the API contract
**Rationale:** desiredstate-api defines contracts, not implementations. OrchestrationScope mirrors ScenarioScope signatures as an API contract. The bridge adapter in desiredstate-runtime wraps ScenarioScope as OrchestrationScope — provisioners code against the API interface. Follows existing platform patterns: AgentProvider (API) vs RoutingAgentProvider (runtime), NodeProvisioner (API) vs DefaultNodeProvisionerRouter (runtime).
**Trade-offs:** Two parallel interfaces with identical signatures. The delegation adapter is boilerplate. Cost is trivial and mechanical — the alternative (coupling API to implementation) would be a persistent architectural debt.
**Sources:** AgentRuntime SPI pattern (platform-api), NodeProvisionerRouter pattern (desiredstate-api/runtime)
**Exploration:** quick
**Status:** captured

## D3: OrchestrationScope surface area

**Choice:** Full mirror of ScenarioScope — all methods
**Alternatives:**
- Curated subset — only proven-needed primitives, evolve later
- Layered — base interface + extension, provisioners declare which they need
**Rationale:** Future node types are unpredictable — message queues may need OrcChannel, clusters may need spawn(), IoT provisioners may need OrcLatch. Cost of unused methods on an interface is zero. Cost of interface evolution is real — breaking API change or awkward layered extension. ScenarioScope's surface is stable and well-designed.
**Trade-offs:** OrchestrationScope is a larger interface than strictly needed today. Acceptable — the API is a mirror, not a novel design, and the delegation adapter is mechanical.
**Sources:** ScenarioScope.java (yaml-core) — full method inventory
**Exploration:** quick
**Status:** captured
