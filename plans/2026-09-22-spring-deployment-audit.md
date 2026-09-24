# Audit Plan — Spring Deployment Readiness

Pre-archive audit for epic #501. Seven dimensions plus open-ended discovery.

## Phase 1 — Static Analysis (parallelisable)

### 1. Completeness

For every SPI in `platform-api/src/main/java/io/casehub/platform/api/`:
- Does a `-core` module exist with a framework-neutral POJO?
- Does the Quarkus module delegate to core?
- Does a `-spring` auto-configuration exist?
- Does the Spring auto-config register via `AutoConfiguration.imports`?
- Does it have `additional-spring-configuration-metadata.json` if it has config properties?

Deliverable: matrix table (SPI × core/quarkus/spring) with gaps highlighted.

### 2. Gaps

- Modules that exist in Quarkus with no Spring counterpart at all
- Config properties that exist in Quarkus `application.properties` but have no Spring metadata
- REST endpoints generated for Quarkus but missing from `rest-spring-generator` output
- GraphQL endpoints generated for Quarkus but missing from `graphql-spring-generator` output
- MCP tools generated for Quarkus but missing from `mcp-spring-generator` output

### 3. Hand-Written Inventory

Identify every Spring module that was hand-written (not generated):
- `oidc-spring` — hand-written (Spring Security integration)
- `scim-spring` — hand-written (RestClient adapter)
- `credentials-spring` — hand-written (environment resolution)
- `agent-gate-spring` — hand-written (BeanPostProcessor pattern)
- `callback-spring` — hand-written (JDK Proxy pattern)
- Others?

For each: why can't it be generated? Is the reason structural (different paradigm) or temporal (generator doesn't support the pattern yet)?

### 4. Drift Risk Assessment

Rank modules by likelihood of silent drift:
- Which modules have the most config properties? (more config = more drift surface)
- Which modules have complex wiring that's easy to get wrong?
- Which SPIs are most actively evolving? (new methods = new gaps)
- Which consumer repos are most likely to add new Quarkus modules without Spring counterparts?

Deliverable: risk-ranked list with mitigation recommendations.

## Phase 2 — Judgment Calls (sequential)

### 5. Drift Detection — Build-Time Enforcement

Design a fast-fail mechanism:
- Maven Enforcer rule or APT that detects Quarkus `@Produces` without a corresponding Spring `@Bean`?
- `drift-detection/` already exists for codegen packages — can it be extended for Spring parity?
- CI check that compares module counts: `*-spring` modules should match a defined set
- Generator verify mojos already detect drift in generated code — what about new modules that don't exist yet?

Deliverable: concrete proposal with implementation approach.

### 6. Complexity Reduction

- Can any `-spring` modules be merged? (e.g., all agent-*-spring into one `agent-spring`?)
- Can the generator reduce per-module boilerplate? (e.g., single `@AutoConfiguration` class per group?)
- Is `spring-boot-starter` the right granularity, or should there be multiple starters (core, agent, notification)?
- Are there shared patterns across hand-written modules that could become a generator feature?

### 7. Code Quality

- Test coverage: which Spring modules lack tests?
- Error handling: do auto-configs fail gracefully when dependencies are missing?
- `@ConditionalOnMissingBean` correctness: are there cases where two auto-configs could produce the same bean type?
- Config defaults: are all required properties either defaulted or guarded by `@ConditionalOnProperty`?
- Spring integration test: does it cover enough? What's excluded and why?

### 8. Open-Ended

- Are there Spring Boot conventions we're not following? (e.g., health indicators, info contributors, metrics)
- Would Spring Boot DevTools integration improve the developer experience?
- Are there opportunities for Spring AOT / GraalVM native compilation?
- Consumer DX: is the getting-started path in the consumer guide actually sufficient for a new Spring adopter?
