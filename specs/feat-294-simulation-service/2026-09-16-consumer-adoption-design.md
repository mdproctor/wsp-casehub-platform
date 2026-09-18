# Consumer Adoption — Simulation Patterns for Application Repos

**Issue:** casehubio/platform#323
**Scale:** M | **Complexity:** Low
**Date:** 2026-09-16

---

## Summary

Extend the simulation guide with a Consumer Adoption section and create
minimal YAML corpus fixture templates for four application repos. No new
Java code in platform — this is documentation and example fixtures only.
Consumer-side adoption work is tracked via GitHub issues on the consumer
repos.

## Scope

**In scope:**
- Consumer Adoption section in `docs/guides/simulation-guide.md`
  - Per-app subsections with SPI priority tables and strategy recommendations
  - Generic @InjectMock → simulation migration patterns (3 before/after examples)
  - Quarkus profile-based CI integration guidance
- Minimal YAML corpus fixture templates at `docs/examples/simulation/<app>/`
  - 2-3 entries per SPI per app, domain-plausible field values
- GitHub issue for comprehensive corpora (deferred to post-maturity)

**Out of scope:**
- Modifications to consumer repos (clinical, devtown, aml, fsitrading)
- Comprehensive corpus sets (deferred — #328 corpus builders, #330 domain data generation)
- Verification/assertion examples (deferred — #332 verification API)

---

## Per-App SPI Audit

Actual SPI usage verified by source audit of each consumer repo:

### clinical

| SPI | Usage | Current test pattern | Simulation path |
|-----|-------|---------------------|-----------------|
| **AgentProvider** | Heavy — ClinicalAgentSupport, 5 test classes | 4× `@InjectMock AgentProvider`, 3× `mock(AgentProvider.class)` | Path B (agent-simulation-core) |
| **CbrCaseMemoryStore** | ClinicalCbrService, ClinicalMemoryService, ConsentWithdrawalService | `mock(CbrCaseMemoryStore.class)` in 3 tests | **Not covered** — see note below |

No @RegisterRestClient interfaces. NotificationStore usage is domain-specific
(SponsorNotificationStore), not the platform SPI.

**CbrCaseMemoryStore gap:** Clinical and aml use `CbrCaseMemoryStore`
(extends CbrCaseStore, CbrCaseRetriever, CbrCaseLifecycle, CbrCaseAdmin),
which is a completely separate interface from `CaseMemoryStore`. The
`memory-simulation-core` module generates a decorator for `CaseMemoryStore`
only — it does not intercept `CbrCaseMemoryStore` injection points.
Simulating CbrCaseMemoryStore requires either a new listing in a
neocortex simulation module or the listing-file approach in the consumer
repo. This is consumer-side work — the adoption guide notes the gap and
recommends programmatic corpus seeding for CBR methods (which have rich
domain types like `CbrCase`, `CbrRetrievalRequest`).

**Simulation profile:** Agent-first. AgentProvider is the highest-value
target — 7 mock sites across tests. CbrCaseMemoryStore second (requires
consumer-side enablement).

### devtown

| SPI | Usage | Current test pattern | Simulation path |
|-----|-------|---------------------|-----------------|
| **@RegisterRestClient (GitHub)** | 5 APIs: GitHubChecksApi, GitHubMergeApi, GitHubPullRequestApi, GitHubGitApi, GitHubRepoApi (all configKey="github-api") | — | Path A (rest-client-simulation-generator) |
| **CaseMemoryStore** | Via engine module — ResolutionIngestionService, ReasoningReconciliationService | `mock(CaseMemoryStore.class)` in engine tests | Path A (memory-simulation-core) |

Does NOT use AgentProvider directly (corrects the issue's assumption).

**Simulation profile:** REST-client-first. Five GitHub API clients are the
highest-value target — external API calls dominate integration testing.
CaseMemoryStore second.

### aml

| SPI | Usage | Current test pattern | Simulation path |
|-----|-------|---------------------|-----------------|
| **CbrCaseMemoryStore** | AmlCbrSchemaRegistrar, AmlErasureService | `InMemoryCbrCaseMemoryStore` in tests (already uses in-memory, not mocks) | **Not covered** — same CbrCaseMemoryStore gap as clinical |
| **ModelRegistry** | DomainModelRegistry in MCP test only | Direct instantiation | Path A (platform-simulation-core) |

Does NOT use ExpressionEngine directly (corrects the issue's assumption).
No @RegisterRestClient interfaces.

**Simulation profile:** Memory-first. Already using in-memory implementations
rather than mocks — smallest adoption gap. CbrCaseMemoryStore has the same
gap as clinical. ModelRegistry is a minor target.

### fsitrading

| SPI | Usage | Current test pattern | Simulation path |
|-----|-------|---------------------|-----------------|
| **AgentProvider** | Via blocks modules — SpeechWebSocket, agentic patterns | `@Mock AgentProvider`, TestAgentProvider stub | Path B (agent-simulation-core) |
| **CaseMemoryStore** | Via neocortex/engine modules | — | Path A (memory-simulation-core) |
| **ModelRegistry** | FsiModelRegistryTest | Direct InMemoryModelRegistry instantiation | Path A (platform-simulation-core) |

"Banking/payment SPIs" mentioned in the issue are domain-specific interfaces
within fsitrading, not platform SPIs. They would need @SimulationEligible
added in the fsitrading repo.

**Simulation profile:** Agent + domain SPI. AgentProvider via blocks is the
highest platform-SPI value target. Domain-specific banking SPIs need
@SimulationEligible annotation (consumer-side work).

**Consumer-side @SimulationEligible guidance:** For domain-specific SPIs
(fsitrading's banking/payment interfaces, clinical's domain notification
store), consumers have two enablement paths:

1. **Annotation path** — add `simulation-api` as a compile dependency to
   the domain API module, annotate the SPI with `@SimulationEligible`.
   The simulation-generator APT generates the decorator. Introduces a
   platform simulation dependency into the consumer's API module.
2. **Listing-file path** — add `META-INF/simulation-eligible.txt` in the
   module that should host the generated decorator. No annotation
   dependency on the SPI. Requires the SPI's JAR on
   `annotationProcessorPaths`. This is the same mechanism
   `memory-simulation-core` uses for `CaseMemoryStore`.

The adoption guide documents both paths. The listing-file path is
recommended when the SPI is in a separate API module that shouldn't
depend on simulation-api.

---

## Guide Structure

The Consumer Adoption section is appended to `simulation-guide.md` after
the existing "Scenario Integration" section. Structure:

```
## Consumer adoption

### Adoption checklist

### clinical
  - SPI priority table
  - Recommended strategies
  - Example config snippet
  - Fixture pointer

### devtown
  - (same structure)

### aml
  - (same structure)

### fsitrading
  - (same structure)

### Migrating from @InjectMock
  - Pattern 1: mock return value → key-lookup
  - Pattern 2: mock sequential returns → sequential
  - Pattern 3: mock with verify → capture + journal

### CI integration with Quarkus profiles
```

### Adoption checklist

A numbered checklist that every consumer follows:

1. Add simulation dependencies:
   - `casehub-platform-simulation-api` (compile)
   - `casehub-platform-simulation-core` (compile)
   - `casehub-platform-simulation-config` (compile)
   - `casehub-platform-simulation-generator` (provided — APT)
2. Add the appropriate simulation module for your SPIs:
   - `agent-simulation-core` (compile) — for AgentProvider
   - `memory-simulation-core` (compile) — for CaseMemoryStore
   - `platform-simulation-core` (compile) — for platform-api SPIs
   - `rest-client-simulation-generator` (provided — APT) — for @RegisterRestClient
3. Create YAML corpus fixtures (copy from `docs/examples/simulation/<app>/`)
4. Add `%test` profile simulation config to `application.properties`
5. Migrate @InjectMock tests to simulation-based tests

### Per-app subsections

Each app subsection includes:

- **Priority table** — which SPIs to simulate, in what order, with
  recommended strategy
- **Config snippet** — `application.properties` entries for `%test` profile
- **Fixture pointer** — path to example fixtures in platform repo
- **Notes** — app-specific guidance (e.g. clinical's agent-heavy pattern,
  devtown's REST client pattern)

### Migration patterns

Three generic before/after examples:

**Pattern 1: Mock return value → key-lookup**
```java
// Before: @InjectMock
@InjectMock AgentProvider agentProvider;
@BeforeEach void setup() {
    when(agentProvider.invoke(any())).thenReturn(mockResponse);
}

// After: simulation config
// application.properties:
// %test.casehub.simulation.agent-provider.invoke.strategy=key-lookup
// Corpus: seed with known prompt → response pairs
```

**Pattern 2: Mock sequential returns → sequential**
```java
// Before: thenReturn chaining
when(store.query(any())).thenReturn(result1, result2, result3);

// After: sequential strategy with seeded corpus
// %test.casehub.simulation.case-memory-store.query.strategy=sequential
```

**Pattern 3: Mock with verify → capture + journal**
```java
// Before: verify interactions
verify(agentProvider, times(2)).invoke(any());

// After: overlay journal
var overlay = runtime.pushOverlay(config, corpus);
// ... run test ...
assertThat(overlay.journal().countFor("agent-provider.invoke")).isEqualTo(2);
```

This is the low-level journal API. Issue #332 (verification API) will add
a convenience DSL (`wasCalled()`, `wasCalledWith()`, `verifyInOrder()`)
over this same journal. The journal-based pattern shown here remains valid
— #332 adds sugar, not a replacement.

### CI integration

Document the Quarkus profile pattern:

```properties
# %test profile — simulation enabled
%test.casehub.simulation.agent-provider.invoke.strategy=sequential
%test.casehub.simulation.case-memory-store.query.strategy=key-lookup

# No simulation config in %staging or %prod → passthrough
```

No Maven profile changes needed. Simulation modules are compile-scope
dependencies — present at all times but inert without config (no strategy
configured = passthrough).

**Production overhead note:** Generated `@Decorator` classes are active
CDI beans in production. Each intercepted call enters the decorator,
performs a `ConcurrentHashMap.get()` that returns `Optional.empty()`, and
delegates. The per-call overhead is nanoseconds — negligible for most SPIs.
For high-frequency SPIs in latency-sensitive paths, consumers can use
Maven profile gating to exclude simulation modules from production builds
if the overhead is a concern.

---

## Fixture Structure

```
docs/examples/simulation/
├── clinical/
│   └── agent-provider-corpus.yaml
├── devtown/
│   ├── github-api-corpus.yaml
│   └── case-memory-store-corpus.yaml
├── aml/
│   └── model-registry-corpus.yaml
└── fsitrading/
    ├── agent-provider-corpus.yaml
    └── model-registry-corpus.yaml
```

Clinical and aml's CbrCaseMemoryStore is not covered by existing simulation
modules — no YAML fixture provided. Devtown and fsitrading use
CaseMemoryStore directly (via engine) so fixtures are included.

Each YAML file follows the existing corpus fixture format from
simulation-config-core's `YamlCorpusLoader`. Top-level keys are qualified
SPI names, each mapping to a list of entries. No `recorded-at` field —
the loader injects `Instant.now()` at parse time. Top-level entry fields
(`tenancy-id`, `key`, `input`, `output`) are kebab-case. Nested fields
within `input` and `output` must match the SPI's actual field names
(typically camelCase for Java records).

```yaml
# agent-provider-corpus.yaml
agent-provider.invoke:
  - tenancy-id: default
    key: triage-prompt
    input:
      systemPrompt: "You are a clinical triage agent..."
      userPrompt: "Patient presents with chest pain"
    output:
      - type: TextDelta
        text: "Based on the symptoms, I recommend..."
  - tenancy-id: default
    key: routing-prompt
    input:
      systemPrompt: "Route this case to the appropriate specialist..."
      userPrompt: "AML screening flagged entity"
    output:
      - type: TextDelta
        text: "Routing to compliance review..."
```

2-3 entries per file. Domain-plausible values — real enough to demonstrate
the fixture shape, not enough for real testing.

**Type limitation (per D14):** YAML fixtures store input/output as
untyped Objects (Maps/Lists/Strings). This works for key-lookup and
sequential strategies where the output is consumed as raw data. For SPIs
with rich domain return types (e.g. `CaseMemoryStore.query()` returns
`List<Memory>`), YAML fixtures may not deserialize correctly into the
expected types. Use programmatic corpus seeding for these cases.

The `case-memory-store-corpus.yaml` fixtures in devtown and fsitrading
demonstrate the YAML shape for simple query scenarios. Clinical and aml
use CbrCaseMemoryStore (not covered by memory-simulation-core) and would
need programmatic seeding regardless.

---

## Follow-on Issue

File a GitHub issue on casehubio/platform for comprehensive corpus
development after the framework matures:

**Title:** feat: comprehensive simulation corpora for consumer apps
**Body:** Starter corpora with 10-15 entries per SPI per app, covering
happy path, error cases, and edge cases. Depends on #328 (corpus builders)
and #330 (domain data generation) being complete. Per-app: clinical
(AgentProvider scenarios, CaseMemoryStore patient data), devtown (GitHub
API response recordings), aml (CaseMemoryStore investigation data),
fsitrading (AgentProvider + domain SPIs).

---

## References

- Issue #323 — consumer adoption scope
- `docs/guides/simulation-guide.md` — existing simulation guide (all sections)
- D49-D54 — design decisions for this issue
- D11 — boot-time configuration (CI profile pattern depends on this)
- Issue #328 — domain-specific corpus builders (deferred comprehensive corpora)
- Issue #330 — domain data generation (deferred)
- Issue #332 — verification API (deferred assertion patterns)
- Consumer repos: casehubio/clinical, casehubio/devtown, casehubio/aml, casehubio/fsitrading
