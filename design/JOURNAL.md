# Design Journal — issue-73-endpoints

### 2026-06-12 · §9.3 · C17

Named endpoint registry is the fourth foundation platform primitive (alongside preferences, identity, and memory). The SPI lives in `platform-api` directly — not a separate `endpoints/` module — because `platform/` must carry the `NoOpEndpointRegistry @DefaultBean`, making the SPI universally transitive anyway. The only justified exception in this codebase for a separate SPI module is `agent-api/`, which carries Mutiny; `EndpointRegistry` is pure Java with no such constraint.

`resolve()` implements a two-step tenant-then-platform-global priority lookup: tenant-specific endpoints shadow platform defaults for the same path, enabling per-tenant override of shared service endpoints. `discover()` is intentionally exhaustive — callers choose among results. `EndpointPropertyKeys` (URL, TOPIC) establishes the cross-module interoperability contract for the properties map, following the `MemoryAttributeKeys` precedent. `credentialRef` is in the descriptor now (nullable) to avoid a breaking record-field change when the secrets layer arrives.

---

### 2026-06-12 · §9.4·L1

New package `io.casehub.platform.api.endpoints` added to `platform-api`: `EndpointRegistry` SPI, `EndpointDescriptor`, `EndpointQuery`, `EndpointProtocol`, `EndpointType`, `EndpointCapability`, `EndpointPropertyKeys`. `TenancyConstants.PLATFORM_TENANT_ID` now carries a documented dual use: cross-tenant super-admin principals AND platform-global endpoint visibility — both express the same semantic (owned by the platform, not any tenant). Field ordering in both records follows the "required fields first" convention established by `MemoryInput` and `MemoryQuery`.

---

### 2026-06-12 · §9.4·L2

`NoOpEndpointRegistry @DefaultBean @ApplicationScoped` added to `platform/`. Pattern is silent no-op for all four SPI methods — consistent with `NoOpCaseMemoryStore` and `NoOpAgentProvider`. Active when `casehub-platform-endpoints-memory` (or a future JPA backend) is absent from the classpath. Two CDI displacement tests added to `MockBeansTest`.

---

### 2026-06-12 · §9.4·L9

New layer L9: Endpoint Registry Adapters. First module: `casehub-platform-endpoints-memory` — `InMemoryEndpointRegistry @Alternative @Priority(100)`. Sits at Tier 4 of the CDI priority ladder (PP-20260522-0cfa30): above JPA (Tier 2) and NoSQL (Tier 3), following `@Priority(100)` convention for in-memory implementations documented this session. L6 (Memory Adapters) remains exclusively for `CaseMemoryStore`/`GraphCaseMemoryStore` implementations. `EndpointRegistry` adapters are a different SPI and must not be conflated into L6.

