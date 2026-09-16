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
| **CaseMemoryStore** | Via CbrCaseMemoryStore — ClinicalCbrService, ClinicalMemoryService, ConsentWithdrawalService | `mock(CbrCaseMemoryStore.class)` in 3 tests | Path A (memory-simulation-core) |

No @RegisterRestClient interfaces. NotificationStore usage is domain-specific
(SponsorNotificationStore), not the platform SPI.

**Simulation profile:** Agent-first. AgentProvider is the highest-value
target — 7 mock sites across tests. CaseMemoryStore second.

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
| **CaseMemoryStore** | Via CbrCaseMemoryStore — AmlCbrSchemaRegistrar, AmlErasureService | `InMemoryCbrCaseMemoryStore` in tests (already uses in-memory, not mocks) | Path A (memory-simulation-core) |
| **ModelRegistry** | DomainModelRegistry in MCP test only | Direct instantiation | Path A (platform-simulation-core) |

Does NOT use ExpressionEngine directly (corrects the issue's assumption).
No @RegisterRestClient interfaces.

**Simulation profile:** Memory-first. Already using in-memory implementations
rather than mocks — smallest adoption gap. ModelRegistry is a minor target.

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

1. Add simulation dependencies (simulation-core, simulation-config,
   simulation-generator as provided scope)
2. Add the appropriate simulation module for your SPIs
   (agent-simulation-core, memory-simulation-core, platform-simulation-core,
   rest-client-simulation-generator)
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

### CI integration

Document the Quarkus profile pattern:

```properties
# %test profile — simulation enabled
%test.casehub.simulation.agent-provider.invoke.strategy=sequential
%test.casehub.simulation.case-memory-store.query.strategy=key-lookup

# No simulation config in %staging or %prod → passthrough
```

No Maven profile changes needed. Simulation modules are compile-scope
dependencies — present at all times but inert without config.

---

## Fixture Structure

```
docs/examples/simulation/
├── clinical/
│   ├── agent-provider-corpus.yaml
│   └── case-memory-store-corpus.yaml
├── devtown/
│   ├── github-api-corpus.yaml
│   └── case-memory-store-corpus.yaml
├── aml/
│   ├── case-memory-store-corpus.yaml
│   └── model-registry-corpus.yaml
└── fsitrading/
    ├── agent-provider-corpus.yaml
    ├── case-memory-store-corpus.yaml
    └── model-registry-corpus.yaml
```

Each YAML file follows the existing corpus fixture format from
simulation-config-core's `YamlCorpusLoader`. Top-level keys are qualified
SPI names, each mapping to a list of entries. No `recorded-at` field —
the loader injects `Instant.now()` at parse time. All field names are
kebab-case.

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
