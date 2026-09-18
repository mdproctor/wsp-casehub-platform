# Consumer Adoption — Simulation Patterns Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** #323 — consumer adoption: simulation patterns for clinical, devtown, aml, fsitrading
**Issue group:** #312 (branch covers)

**Goal:** Extend the simulation guide with per-app adoption sections,
migration patterns, CI guidance, and create minimal YAML corpus fixture
templates for four consumer apps.

**Architecture:** Documentation and YAML fixture files only — no new
Java code. The simulation guide gains a Consumer Adoption section
appended after line 1187 (end of Scenario Integration). Example fixtures
go in `docs/examples/simulation/<app>/`. A follow-on GitHub issue is
filed for comprehensive corpora.

**Tech Stack:** Markdown, YAML

## Global Constraints

- No modifications to consumer repos (clinical, devtown, aml, fsitrading)
- YAML corpus fixtures must follow YamlCorpusLoader format: top-level
  keys are qualified SPI names, entries have `tenancy-id`, `key`,
  `input`, `output` (kebab-case top-level; camelCase nested to match SPI
  field names)
- No `recorded-at` in YAML — loader injects `Instant.now()`
- CbrCaseMemoryStore is NOT covered by memory-simulation-core — no YAML
  fixtures for clinical/aml CaseMemoryStore usage

---

## Batch 1: Guide section + fixtures

### Task 1: Consumer Adoption section in simulation-guide.md

**Files:**
- Modify: `docs/guides/simulation-guide.md` (append after line 1187)

**Interfaces:**
- Consumes: existing simulation guide structure (sections end at line 1187)
- Produces: Consumer Adoption section with adoption checklist, four
  per-app subsections, migration patterns, CI integration guidance

- [ ] **Step 1: Append adoption checklist**

Append to `docs/guides/simulation-guide.md` after line 1187:

```markdown
---

## Consumer adoption

Every consumer app follows the same adoption path. The checklist below
is the universal sequence; the per-app sections that follow give
specific SPI priorities and config for each application.

### Adoption checklist

1. **Add simulation dependencies** to `pom.xml`:
   ```xml
   <dependency>
       <groupId>io.casehub</groupId>
       <artifactId>casehub-platform-simulation-api</artifactId>
   </dependency>
   <dependency>
       <groupId>io.casehub</groupId>
       <artifactId>casehub-platform-simulation-core</artifactId>
   </dependency>
   <dependency>
       <groupId>io.casehub</groupId>
       <artifactId>casehub-platform-simulation-config</artifactId>
   </dependency>
   <dependency>
       <groupId>io.casehub</groupId>
       <artifactId>casehub-platform-simulation-generator</artifactId>
       <scope>provided</scope>
   </dependency>
   ```

2. **Add the simulation module for your SPIs:**

   | SPI target | Module | Scope |
   |-----------|--------|-------|
   | AgentProvider | `casehub-platform-agent-simulation-core` | compile |
   | CaseMemoryStore | `casehub-platform-memory-simulation-core` | compile |
   | Platform-api SPIs (ACL, notifications, etc.) | `casehub-platform-platform-simulation-core` | compile |
   | @RegisterRestClient interfaces | `casehub-platform-rest-client-simulation-generator` | provided |

3. **Create YAML corpus fixtures** — copy from
   `docs/examples/simulation/<your-app>/` and adapt field values.

4. **Add `%test` profile simulation config** to `application.properties`:
   ```properties
   %test.casehub.simulation.<spi>.<method>.strategy=<strategy>
   ```

5. **Migrate @InjectMock tests** to simulation-based tests — see
   "Migrating from @InjectMock" below.

**Production overhead:** Generated `@Decorator` classes are active CDI
beans at all times. Each intercepted call performs a
`ConcurrentHashMap.get()` returning `Optional.empty()` when no strategy
is configured — nanosecond overhead. For high-frequency SPIs in
latency-sensitive production paths, use Maven profile gating to exclude
simulation modules from production builds.
```

- [ ] **Step 2: Append clinical subsection**

```markdown

### clinical

AgentProvider is the highest-value simulation target — 7 mock sites
across test classes. CbrCaseMemoryStore is second but requires
consumer-side enablement (see note below).

| SPI | Strategy | Qualified name | Module |
|-----|----------|----------------|--------|
| **AgentProvider** | key-lookup or sequential | `agent-provider.invoke` | agent-simulation-core |
| **CbrCaseMemoryStore** | — | — | **Not covered** (see below) |

**CbrCaseMemoryStore gap:** Clinical uses `CbrCaseMemoryStore`, not
`CaseMemoryStore`. These are separate interface hierarchies —
`memory-simulation-core` does not intercept CbrCaseMemoryStore injection
points. To simulate CbrCaseMemoryStore, add a
`META-INF/simulation-eligible.txt` in a clinical simulation module:

```
io.casehub.neocortex.memory.cbr.CbrCaseMemoryStore=cbr-case-memory-store
```

This is consumer-side work — the listing-file path avoids adding
`simulation-api` as a dependency to neocortex-memory-api.

**Example config:**

```properties
%test.casehub.simulation.agent-provider.invoke.strategy=key-lookup
```

**Example fixtures:** `docs/examples/simulation/clinical/`
```

- [ ] **Step 3: Append devtown subsection**

```markdown

### devtown

Five GitHub `@RegisterRestClient` APIs are the highest-value target —
external API calls dominate integration testing. CaseMemoryStore (via
engine module) is second.

| SPI | Strategy | Qualified name | Module |
|-----|----------|----------------|--------|
| **GitHubChecksApi** | key-lookup | `github-api.createCheckRun` etc. | rest-client-simulation-generator |
| **GitHubMergeApi** | key-lookup | `github-api.merge` etc. | rest-client-simulation-generator |
| **GitHubPullRequestApi** | key-lookup | `github-api.getPullRequest` etc. | rest-client-simulation-generator |
| **GitHubGitApi** | key-lookup | `github-api.getRef` etc. | rest-client-simulation-generator |
| **GitHubRepoApi** | key-lookup | `github-api.getRepository` etc. | rest-client-simulation-generator |
| **CaseMemoryStore** | key-lookup | `case-memory-store.query` | memory-simulation-core |

All five GitHub APIs share `configKey="github-api"`, so their qualified
names use the `github-api` prefix. The `rest-client` key extractor
produces keys like `GET /repos/owner/repo/pulls/1`.

**Example config:**

```properties
%test.casehub.simulation.github-api.getPullRequest.strategy=key-lookup
%test.casehub.simulation.github-api.getPullRequest.key-extractor=rest-client
%test.casehub.simulation.case-memory-store.query.strategy=key-lookup
```

**Example fixtures:** `docs/examples/simulation/devtown/`
```

- [ ] **Step 4: Append aml subsection**

```markdown

### aml

AML already uses `InMemoryCbrCaseMemoryStore` in tests — smallest
adoption gap of the four apps. CbrCaseMemoryStore has the same coverage
gap as clinical. ModelRegistry is a minor target.

| SPI | Strategy | Qualified name | Module |
|-----|----------|----------------|--------|
| **CbrCaseMemoryStore** | — | — | **Not covered** (same gap as clinical) |
| **ModelRegistry** | key-lookup | `model-registry.resolveById` | platform-simulation-core |

**Example config:**

```properties
%test.casehub.simulation.model-registry.resolveById.strategy=key-lookup
```

**Example fixtures:** `docs/examples/simulation/aml/`
```

- [ ] **Step 5: Append fsitrading subsection**

```markdown

### fsitrading

AgentProvider (via blocks modules) is the highest platform-SPI target.
Domain-specific banking/payment SPIs need consumer-side
`@SimulationEligible` enablement.

| SPI | Strategy | Qualified name | Module |
|-----|----------|----------------|--------|
| **AgentProvider** | key-lookup or sequential | `agent-provider.invoke` | agent-simulation-core |
| **CaseMemoryStore** | key-lookup | `case-memory-store.query` | memory-simulation-core |
| **ModelRegistry** | key-lookup | `model-registry.resolveById` | platform-simulation-core |
| **Banking/payment SPIs** | — | — | **Consumer-side** (see below) |

**Domain SPI enablement:** Fsitrading's banking and payment interfaces
are domain-specific, not platform SPIs. Two enablement paths:

1. **Annotation path** — add `simulation-api` as a compile dependency,
   annotate the SPI with `@SimulationEligible(name = "payment-gateway")`.
2. **Listing-file path** (recommended) — add
   `META-INF/simulation-eligible.txt` in the module hosting the
   generated decorator. No annotation dependency on the SPI module.

**Example config:**

```properties
%test.casehub.simulation.agent-provider.invoke.strategy=sequential
%test.casehub.simulation.case-memory-store.query.strategy=key-lookup
%test.casehub.simulation.model-registry.resolveById.strategy=key-lookup
```

**Example fixtures:** `docs/examples/simulation/fsitrading/`
```

- [ ] **Step 6: Append migration patterns section**

```markdown

### Migrating from @InjectMock

Three patterns cover the most common mock-to-simulation migrations:

**Pattern 1: Mock return value → key-lookup**

```java
// BEFORE: @InjectMock with stubbed return
@InjectMock AgentProvider agentProvider;

@BeforeEach
void setup() {
    when(agentProvider.invoke(any()))
        .thenReturn(Multi.createFrom().item(
            new AgentEvent.TextDelta("mocked response")));
}

// AFTER: simulation config + corpus
// 1. Remove @InjectMock — let CDI inject the real (or NoOp) bean
// 2. Add to application.properties:
//    %test.casehub.simulation.agent-provider.invoke.strategy=key-lookup
// 3. Seed corpus (YAML or programmatic):
//    agent-provider.invoke:
//      - tenancy-id: default
//        key: any-prompt
//        input: { systemPrompt: "...", userPrompt: "..." }
//        output: [{ type: TextDelta, text: "mocked response" }]
```

**Pattern 2: Mock sequential returns → sequential strategy**

```java
// BEFORE: thenReturn chaining
when(store.query(any()))
    .thenReturn(List.of(memory1))
    .thenReturn(List.of(memory2))
    .thenReturn(List.of(memory3));

// AFTER: sequential strategy with seeded corpus
// %test.casehub.simulation.case-memory-store.query.strategy=sequential
// Seed 3 entries in corpus order — sequential returns them in order.
// WRAP policy (default) cycles; THROW policy fails after exhaustion.
```

**Pattern 3: Mock with verify → capture + journal**

```java
// BEFORE: verify interactions
verify(agentProvider, times(2)).invoke(any());
verify(agentProvider).invoke(argThat(req ->
    req.userPrompt().contains("triage")));

// AFTER: overlay journal (for scenario-scoped verification)
var overlay = runtime.pushOverlay(config, corpus);
try {
    // ... run test ...
    var entries = overlay.journal()
        .entriesFor("agent-provider.invoke");
    assertThat(entries).hasSize(2);
    assertThat(entries.get(0).input().toString())
        .contains("triage");
} finally {
    runtime.popOverlay(overlay);
}
// The journal records every intercepted call with input, output,
// timestamp, and whether it was simulated or passthrough.
// Issue #332 will add a convenience DSL (wasCalled(), wasCalledWith(),
// verifyInOrder()) over this same journal.
```
```

- [ ] **Step 7: Append CI integration section**

```markdown

### CI integration with Quarkus profiles

Simulation activates only when `casehub.simulation.*` config is present.
Use Quarkus profiles to enable simulation in CI and disable it in
staging/production:

```properties
# application.properties — %test profile enables simulation

# CI: simulate AgentProvider
%test.casehub.simulation.agent-provider.invoke.strategy=key-lookup

# CI: simulate CaseMemoryStore
%test.casehub.simulation.case-memory-store.query.strategy=key-lookup

# Staging/prod: no simulation config → passthrough
# (no %staging or %prod prefixed simulation keys needed)
```

No Maven profile changes needed. No CI pipeline changes needed.
Simulation modules are compile-scope dependencies, but the generated
decorators are inert without strategy config — a `ConcurrentHashMap.get()`
returning empty on every call.

**YAML corpus files** for CI are loaded via:

```properties
%test.casehub.simulation.corpus.files=simulation/agent-corpus.yaml,simulation/memory-corpus.yaml
```

Place fixture files in `src/test/resources/simulation/` in the consumer
module.

**Type limitation:** YAML fixtures store input/output as untyped Objects
(Maps/Lists/Strings). This works for key-lookup and sequential strategies
where output is consumed as raw data. For SPIs with rich domain return
types (e.g. `CaseMemoryStore.query()` returns `List<Memory>`), use
programmatic corpus seeding in a `@Startup` bean or test setup method.
```

- [ ] **Step 8: Verify guide renders correctly**

Run: read the complete appended section back and verify:
- No broken markdown (unclosed code fences, misaligned tables)
- All qualified names match the platform's actual SPI names
- All module names match actual artifact IDs
- Section hierarchy is consistent (h2 for Consumer adoption, h3 for subsections)

- [ ] **Step 9: Commit**

```bash
git add docs/guides/simulation-guide.md
git commit -m "docs(#323): consumer adoption section in simulation guide

Per-app subsections for clinical, devtown, aml, fsitrading.
Migration patterns (@InjectMock → simulation). CI integration
with Quarkus profiles. Documents CbrCaseMemoryStore gap.

Refs #323"
```

### Task 2: YAML corpus fixture templates

**Files:**
- Create: `docs/examples/simulation/clinical/agent-provider-corpus.yaml`
- Create: `docs/examples/simulation/devtown/github-api-corpus.yaml`
- Create: `docs/examples/simulation/devtown/case-memory-store-corpus.yaml`
- Create: `docs/examples/simulation/aml/model-registry-corpus.yaml`
- Create: `docs/examples/simulation/fsitrading/agent-provider-corpus.yaml`
- Create: `docs/examples/simulation/fsitrading/model-registry-corpus.yaml`

**Interfaces:**
- Consumes: YamlCorpusLoader format (qualified-name → entry list)
- Produces: 6 YAML fixture files with domain-plausible example data

- [ ] **Step 1: Create clinical agent-provider fixture**

Create `docs/examples/simulation/clinical/agent-provider-corpus.yaml`:

```yaml
agent-provider.invoke:
  - tenancy-id: hospital-a
    key: triage-assessment
    input:
      systemPrompt: "You are a clinical triage agent. Assess the patient presentation and recommend a priority level."
      userPrompt: "Patient presents with acute chest pain, elevated troponin, and ST-segment changes on ECG."
    output:
      - type: TextDelta
        text: "Priority 1 — Immediate cardiology consult. Findings suggest acute coronary syndrome: elevated troponin with ST-segment changes. Recommend urgent catheterization assessment."
  - tenancy-id: hospital-a
    key: discharge-summary
    input:
      systemPrompt: "Generate a discharge summary for the completed case."
      userPrompt: "Patient admitted for pneumonia, treated with IV antibiotics for 5 days, now afebrile with improving CXR."
    output:
      - type: TextDelta
        text: "Discharge diagnosis: Community-acquired pneumonia, resolved. Treatment: IV ceftriaxone 5 days, transitioned to oral amoxicillin. Follow-up: GP in 7 days, repeat CXR in 6 weeks."
```

- [ ] **Step 2: Create devtown github-api fixture**

Create `docs/examples/simulation/devtown/github-api-corpus.yaml`:

```yaml
github-api.getPullRequest:
  - tenancy-id: default
    key: "GET /repos/acme/webapp/pulls/42"
    input:
      spiName: github-api
      methodName: getPullRequest
      httpMethod: GET
      pathTemplate: "/repos/{owner}/{repo}/pulls/{pull_number}"
      params:
        owner: acme
        repo: webapp
        pull_number: 42
    output:
      number: 42
      title: "feat: add user dashboard"
      state: open
      head:
        ref: feat/dashboard
        sha: abc123def456
      base:
        ref: main

github-api.getRef:
  - tenancy-id: default
    key: "GET /repos/acme/webapp/git/refs/heads/main"
    input:
      spiName: github-api
      methodName: getRef
      httpMethod: GET
      pathTemplate: "/repos/{owner}/{repo}/git/refs/{ref}"
      params:
        owner: acme
        repo: webapp
        ref: heads/main
    output:
      ref: refs/heads/main
      object:
        sha: def456abc789
        type: commit
```

- [ ] **Step 3: Create devtown case-memory-store fixture**

Create `docs/examples/simulation/devtown/case-memory-store-corpus.yaml`:

```yaml
case-memory-store.query:
  - tenancy-id: default
    key: dev-context
    input:
      domain: development
      question: "recent changes to auth module"
    output:
      - id: mem-001
        content: "Refactored OAuth2 token refresh logic to handle expired tokens gracefully"
        domain: development
  - tenancy-id: default
    key: review-context
    input:
      domain: code-review
      question: "PR review guidelines"
    output:
      - id: mem-002
        content: "All PRs require at least one approval, CI must be green, no force-pushes to main"
        domain: code-review
```

- [ ] **Step 4: Create aml model-registry fixture**

Create `docs/examples/simulation/aml/model-registry-corpus.yaml`:

```yaml
model-registry.resolveById:
  - tenancy-id: default
    key: screening-model
    input: "aml-screening-v2"
    output:
      id: aml-screening-v2
      backendKey: openai
      vendor: OpenAI
      family: gpt-4o
      displayName: "AML Screening Model"
      tier: FLAGSHIP
      contextWindow: 128000
      maxOutput: 16384
  - tenancy-id: default
    key: classification-model
    input: "aml-classification-v1"
    output:
      id: aml-classification-v1
      backendKey: claude
      vendor: Anthropic
      family: claude-sonnet
      displayName: "AML Classification Model"
      tier: STANDARD
      contextWindow: 200000
      maxOutput: 8192
```

- [ ] **Step 5: Create fsitrading agent-provider fixture**

Create `docs/examples/simulation/fsitrading/agent-provider-corpus.yaml`:

```yaml
agent-provider.invoke:
  - tenancy-id: trading-desk
    key: risk-assessment
    input:
      systemPrompt: "You are a trading risk assessment agent. Evaluate the proposed trade against risk limits."
      userPrompt: "Buy 10000 shares AAPL at market. Current position: 5000 shares. Sector limit: 20000 shares."
    output:
      - type: TextDelta
        text: "Trade approved. Post-trade position 15000 shares within sector limit of 20000. Value-at-risk impact: moderate. No concentration breach."
  - tenancy-id: trading-desk
    key: compliance-check
    input:
      systemPrompt: "Check this transaction against AML and compliance rules."
      userPrompt: "Wire transfer $45,000 to new beneficiary in jurisdiction with enhanced due diligence requirements."
    output:
      - type: TextDelta
        text: "Enhanced due diligence required. Jurisdiction flagged for heightened AML risk. Recommend: verify beneficiary identity, source of funds documentation, and senior management approval before processing."
```

- [ ] **Step 6: Create fsitrading model-registry fixture**

Create `docs/examples/simulation/fsitrading/model-registry-corpus.yaml`:

```yaml
model-registry.resolveById:
  - tenancy-id: trading-desk
    key: trading-agent-model
    input: "trading-risk-v1"
    output:
      id: trading-risk-v1
      backendKey: claude
      vendor: Anthropic
      family: claude-sonnet
      displayName: "Trading Risk Model"
      tier: FLAGSHIP
      contextWindow: 200000
      maxOutput: 8192
  - tenancy-id: trading-desk
    key: compliance-model
    input: "compliance-checker-v1"
    output:
      id: compliance-checker-v1
      backendKey: openai
      vendor: OpenAI
      family: gpt-4o
      displayName: "Compliance Checker"
      tier: STANDARD
      contextWindow: 128000
      maxOutput: 16384
```

- [ ] **Step 7: Commit fixtures**

```bash
git add docs/examples/simulation/
git commit -m "docs(#323): example YAML corpus fixtures for consumer apps

Minimal templates (2-3 entries per SPI) for clinical (AgentProvider),
devtown (GitHub API, CaseMemoryStore), aml (ModelRegistry),
fsitrading (AgentProvider, ModelRegistry). Domain-plausible values.

Refs #323"
```

## Batch 2: Follow-on issue + CLAUDE.md

### Task 3: File follow-on GitHub issue and close #323

**Files:**
- Modify: `CLAUDE.md` (if fixture path needs documenting)

**Interfaces:**
- Consumes: completed guide section and fixtures from Batch 1
- Produces: GitHub issue for comprehensive corpora, closed #323

- [ ] **Step 1: File comprehensive corpora issue**

```bash
gh issue create --repo casehubio/platform \
  --title "feat: comprehensive simulation corpora for consumer apps" \
  --body "$(cat <<'EOF'
## Summary

Comprehensive corpus fixtures with 10-15 entries per SPI per app,
covering happy path, error cases, and edge cases. Extends the minimal
templates from #323.

## Depends on

- #328 — domain-specific corpus builders
- #330 — domain data generation (LLM-driven)

## Per-app scope

- **clinical:** AgentProvider scenarios (triage, routing, discharge, diagnosis agents), CbrCaseMemoryStore patient data (requires simulation-eligible listing first)
- **devtown:** GitHub API response recordings (PRs, checks, merges, refs, repos — all five clients), CaseMemoryStore development context
- **aml:** CbrCaseMemoryStore investigation data (requires simulation-eligible listing first), ModelRegistry model selection
- **fsitrading:** AgentProvider trading scenarios, domain-specific banking/payment SPI corpora (requires @SimulationEligible on domain SPIs first), ModelRegistry

## Deliverables

- 10-15 entries per SPI per app in YAML fixtures
- Error and edge case entries (timeouts, not-found, rate limits)
- Corpus builder integration where available (#328)

Parent: #294

Scale: M | Complexity: Low
EOF
)" --label enhancement
```

- [ ] **Step 2: Update CLAUDE.md if needed**

Check if `docs/examples/` needs to be mentioned in CLAUDE.md. If the
simulation guide's references to `docs/examples/simulation/` are
sufficient (they should be), no CLAUDE.md change is needed.

- [ ] **Step 3: Commit any CLAUDE.md changes**

Only if Step 2 made changes:

```bash
git add CLAUDE.md
git commit -m "docs(#323): note example fixtures in CLAUDE.md Refs #323"
```

## References

- [2026-09-16-consumer-adoption-design.md] — design spec this plan implements
- [docs/guides/simulation-guide.md:1-1187] — existing simulation guide (insertion point)
- [simulation-config-core/src/test/resources/simulation/test-corpus.yaml] — YamlCorpusLoader format reference
- [D49-D54] — design decisions
- [GitHub #323] — focal issue
- [GitHub #328] — domain-specific corpus builders (deferred)
- [GitHub #330] — domain data generation (deferred)
- [GitHub #332] — verification API (deferred)
