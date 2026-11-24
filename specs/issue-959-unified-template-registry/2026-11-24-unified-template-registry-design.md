# Unified Template Registry — Design Spec

**Issue:** #959
**Date:** 2026-11-24
**Epic:** #943 (Message Extraction Pipeline)

## Purpose

Replace the fragmented template matching infrastructure with a unified template registry that holds both regex and NLP templates, provides grammar-tolerant matching for protocol enforcement, and publishes sentence schemas for governed LLM communication.

The existing architecture has two parallel, unconnected template matching stacks — a protocol stack (yaml-core → coordination-core → yaml-step-runtime) and an extraction stack (message-extraction-api → message-extraction). Each playbook creates its own isolated `ProtocolEvaluator` with duplicate template registries. Templates compile twice, keyword caches duplicate, the `NlpProtocolMatcher` SPI has zero implementations, and there is no cross-playbook composition.

The unified registry solves the **lifecycle problem**: a single shared registry replaces per-playbook isolated evaluators. It provides two-tier matching (regex first, NLP structural fallback), bidirectional template handling (matching/extraction and generation), and schema publication for governed communications.

## Architecture

### Module Structure

```
yaml-core (zero-dep, existing — VariableConstraint canonical, TemplateExtractor for YAML)
    ↑
template-registry-api  (Declaration Primitive — types, SPI, regex matching; depends on yaml-core)
    ↑
template-registry      (L4 Extension — NLP matching, OpenNLP, structural patterns)
```

**`template-registry-api`** — Declaration Primitive. Depends on `yaml-core` for `VariableConstraint` (canonical definition). No external dependencies (no OpenNLP, no Quarkus). Contains:
- Core types: `TemplateDefinition`, `TemplateNamespace`, `TemplateMatch`, `TemplateSchema`
- Registry SPI: `UnifiedTemplateRegistry` (register/deregister/match/generate/schema)
- Regex compilation and matching (inlined from `RegexMessageMatcher`)
- `NlpTokenizer` SPI and `AnnotatedToken` (migrated from `message-extraction-api`)

**`template-registry`** — L4 Extension. Depends on `template-registry-api` + `mcp-api` + Apache OpenNLP. Contains:
- `NlpTemplateCompiler` — structural pattern compilation from templates using NLP pipeline
- `StructuralMatcher` — lemma/POS-based matching (evolved from `StructuralPattern`)
- `OpenNlpTokenizer` (migrated from `message-extraction`)
- `LemmatisedKeywordFilter` — upgraded `TemplateKeywords` operating on lemmatised tokens
- `@ApplicationScoped` registry implementation with immutable-snapshot concurrency
- `TemplateSchemaEndpoint` — `@McpDomain("template-schemas")` class for schema discovery and matching operations (follows established pattern: `@McpDomain` classes in core/impl modules, not API modules)

**`@DefaultBean` NoOp** — A no-op `UnifiedTemplateRegistry` implementation in `platform-core`, following the established SPI displacement pattern (ARC42STORIES §4). `platform-core` depends on `template-registry-api` for this. The NoOp returns `Unmatched` for all matches, empty schemas, and throws on generate(). The `@ApplicationScoped` implementation in `template-registry` displaces it automatically when on the classpath.

### Existing Modules — Disposition

| Module / Type | Disposition |
|--------------|-------------|
| `TemplateExtractor` (yaml-core) | **Kept** — YAML variable resolution (forward interpolation) |
| `VariableConstraint` (yaml-core) | **Kept as canonical** — template-registry-api depends on it |
| `TemplateRegistry` (yaml-core) | **Retired for matching** — unified registry replaces. Builder/build pattern continues for TemplateExtractor use |
| `ProtocolEvaluator` (coordination-core) | **Superseded** — replaced by unified registry; removed when consumer migration lands |
| `NlpProtocolMatcher` (coordination-core) | **Retired** — zero implementations, role absorbed (D7); safe to remove immediately |
| `TemplateKeywords` (coordination-core) | **Evolved** — becomes `LemmatisedKeywordFilter` in template-registry |
| `TemplateMatchingFilter` (yaml-step-runtime) | **Superseded** — replaced by unified registry; removed when consumer migration lands |
| `TemplateMatchResult` (yaml-step-runtime) | **Superseded** — replaced by `TemplateMatch`; removed with TemplateMatchingFilter |
| `TemplateMatchEvent` (yaml-step-runtime) | **Superseded** — fields absorbed into `TemplateMatch`; removed with TemplateMatchingFilter |
| `RegexMessageMatcher` (message-extraction-api) | **Superseded** — compilation logic inlined into template-registry-api |
| `TwoTierMessageMatcher` (message-extraction) | **Superseded** — two-tier logic absorbed into registry |
| `StructuralPattern` (message-extraction) | **Evolved** — becomes `StructuralMatcher` in template-registry |
| `OpenNlpTokenizer` (message-extraction) | **Migrated** — to template-registry |
| `MessageMatcher` (message-extraction-api) | **Superseded** — replaced by `UnifiedTemplateRegistry.match()` |
| `MessageMatch` (message-extraction-api) | **Superseded** — replaced by `TemplateMatch` |
| `MessageSchema`, `MessageType` (message-extraction-api) | **Superseded** — registry handles type definitions |
| `VariableConstraint` (message-extraction-api) | **Retired** — yaml-core copy is canonical; safe to remove immediately |
| `message-extraction-api` module | **Superseded** — types absorbed into template-registry-api; removed when consumer migration lands |
| `message-extraction` module | **Superseded** — NLP code absorbed into template-registry; removed when consumer migration lands |

### Two-Tier Matching (D3)

Templates always compile to regex patterns at registration time (zero-dep, in template-registry-api). NLP structural patterns compile lazily on first NLP fallback attempt, only when the template-registry implementation module is on the classpath.

```
Input prose
  │
  ├─ Tier 1: Regex match via compiled patterns
  │   ├─ Pattern match? → Constraint validation
  │   │   ├─ Constraints pass → TemplateMatch(type, fields, score=1.0)
  │   │   └─ Constraints fail → try next template
  │   └─ No regex match → fall through
  │
  └─ Tier 2: NLP structural match (if impl module on classpath)
      ├─ Lemmatised keyword filtering (prune candidates)
      ├─ Tokenize → POS tag → Lemmatize (via NlpTokenizer SPI)
      ├─ Structural pattern match against candidates
      └─ Match? → TemplateMatch(type, fields, score=coverage)
  │
  └─ No match → TemplateMatch.unmatched(input)
```

### Candidate Selection — Lemmatised Keyword Filtering (D1)

Upgrades the existing `TemplateKeywords` approach to operate on lemmatised tokens. At registration time, each template's literal segments are tokenised, lemmatised, and stored as a keyword set. At match time, the input is lemmatised and keyword affinity is computed against each template's keyword set.

This is the existing `TemplateKeywords.affinity()` pattern — `(matched keywords / total keywords)` — but operating on lemmas instead of raw words. "Approved" and "approve" both reduce to lemma "approve", so morphological variants no longer cause affinity misses.

Positional discrimination (lemma trie) is a future optimisation reserved for when template counts exceed ~100 per registry. The keyword filtering approach is sufficient for near-term scale (10–50 templates per protocol).

### Concurrency Model (D9)

Immutable snapshots with atomic swap. The internal index (keyword sets, compiled templates, regex patterns) is immutable after build. Register/deregister operations build a new snapshot and atomically swap it via `AtomicReference` with CAS retry (compare-and-swap ensures concurrent registrations don't silently overwrite each other). Readers see a consistent snapshot — no locking on the read path.

This extends `ProtocolEvaluator`'s existing pattern (`ConcurrentMap<String, TemplateRegistry>`) to a single consolidated index.

## Core Types

### TemplateDefinition

A named template within a namespace, with one or more patterns and variable constraints.

```java
public record TemplateDefinition(
    String name,
    List<String> patterns,
    Map<String, VariableConstraint> variables
) {
    public TemplateDefinition {
        Objects.requireNonNull(name, "name");
        Objects.requireNonNull(patterns, "patterns");
        if (patterns.isEmpty()) {
            throw new IllegalArgumentException(
                "Template must have at least one pattern");
        }
        patterns = List.copyOf(patterns);
        variables = variables != null
            ? Collections.unmodifiableMap(new LinkedHashMap<>(variables))
            : Map.of();
    }

    public static Builder builder(String name) { ... }
}
```

### TemplateNamespace

Groups templates by source (playbook, protocol, runtime). Prevents name collisions.

```java
public record TemplateNamespace(
    String name,
    Map<String, TemplateDefinition> templates
) {
    public TemplateNamespace {
        Objects.requireNonNull(name, "name");
        Objects.requireNonNull(templates, "templates");
        if (templates.isEmpty()) {
            throw new IllegalArgumentException(
                "Namespace must have at least one template");
        }
        for (var entry : templates.entrySet()) {
            if (!entry.getKey().equals(entry.getValue().name())) {
                throw new IllegalArgumentException(
                    "Map key '" + entry.getKey()
                    + "' must equal definition name '"
                    + entry.getValue().name() + "'");
            }
        }
        templates = Collections.unmodifiableMap(
            new LinkedHashMap<>(templates));
    }
}
```

### TemplateMatch

Sealed interface — the result of matching input against registered templates.

```java
public sealed interface TemplateMatch {
    record Matched(
        String namespace,
        String templateName,
        int patternIndex,
        Map<String, String> fields,
        double score
    ) implements TemplateMatch {
        public Matched {
            Objects.requireNonNull(namespace, "namespace");
            Objects.requireNonNull(templateName, "templateName");
            Objects.requireNonNull(fields, "fields");
            if (score <= 0.0 || score > 1.0) {
                throw new IllegalArgumentException(
                    "Score must be in (0, 1.0]: " + score);
            }
            fields = Collections.unmodifiableMap(
                new LinkedHashMap<>(fields));
        }
    }

    record NearMiss(
        String namespace,
        String input,
        String suggestedTemplate,
        String suggestedFormat
    ) implements TemplateMatch {
        public NearMiss {
            Objects.requireNonNull(namespace, "namespace");
            Objects.requireNonNull(input, "input");
            Objects.requireNonNull(suggestedTemplate,
                "suggestedTemplate");
            Objects.requireNonNull(suggestedFormat,
                "suggestedFormat");
        }
    }

    record Unmatched(String input) implements TemplateMatch {
        public Unmatched {
            Objects.requireNonNull(input, "input");
        }
    }
}
```

- Regex tier: score is always 1.0 (exact match)
- NLP tier: score is coverage ratio in (0, 1.0]
- `NearMiss` preserves the rephrase-suggestion capability from `TemplateMatchingFilter`

### TemplateSchema

The published sentence schema for a template type. The schema IS the template definition — made discoverable for LLM prompt construction and governance validation (D8).

```java
public record TemplateSchema(
    String namespace,
    String templateName,
    List<String> patterns,
    Map<String, VariableConstraint> variables,
    List<StructuralSummary> structuralSummaries
) {
    public record StructuralSummary(
        String pattern,
        List<ElementSummary> elements
    ) {}

    public record ElementSummary(
        String kind,    // LITERAL, VARIABLE, CLAUSE
        String surface,
        String lemma,
        String pos,
        String variableName
    ) {}
}
```

`structuralSummaries` is populated only when the NLP module is on the classpath. When absent, the schema contains patterns and variables only.

### UnifiedTemplateRegistry (SPI)

```java
public interface UnifiedTemplateRegistry {
    /**
     * @throws IllegalArgumentException if namespace name is already registered
     */
    void register(TemplateNamespace namespace);
    void deregister(String namespaceName);

    TemplateMatch match(String input);

    /**
     * @throws IllegalArgumentException if namespaceName is not registered
     */
    TemplateMatch match(String namespaceName, String input);

    /**
     * @throws IllegalArgumentException if namespace or template not found,
     *         or if a required variable value is missing
     */
    String generate(String namespaceName, String templateName,
                    Map<String, String> values);

    Optional<TemplateSchema> schema(String namespaceName,
                                     String templateName);
    List<TemplateSchema> schemas(String namespaceName);

    Set<String> namespaces();
}
```

- `register()` throws `IllegalArgumentException` if the namespace name is already registered. Callers must `deregister()` before re-registering. Fail-fast on duplicate prevents silent overwrites, consistent with `ProtocolEvaluator.register()`.
- `match(input)` searches all namespaces using registration order:
  - **Regex tier:** iterates namespaces in registration order, templates within each namespace in definition order. Returns the first regex match (score=1.0). Consistent with `TemplateRegistry.match()` and `RegexMessageMatcher.match()`.
  - **NLP tier (fallback):** searches all namespaces, returns the highest-scoring NLP match above threshold. Consistent with `TwoTierMessageMatcher`'s best-score selection.
  - If the regex tier produces a match, the NLP tier is not attempted.
- `match(namespace, input)` scopes to a single namespace (no cross-namespace ambiguity). Throws `IllegalArgumentException` if the namespace is not registered — matching against a non-existent namespace is a configuration bug, not a "no match" scenario. Consistent with `generate()` and `ProtocolEvaluator.evaluate()`.
- `generate()` produces a surface form via template slot-filling (D2, D6). Always uses pattern index 0 (the canonical form). Pattern 0 is the primary, human-readable surface form; additional patterns are matching alternatives. Error semantics:
  - Unknown namespace → `IllegalArgumentException` (consistent with `ProtocolEvaluator.evaluate()`)
  - Unknown template name within namespace → `IllegalArgumentException`
  - Missing required variable value → `IllegalArgumentException`. Unresolved `${var}` placeholders in generated output are silent corruption for governed communications; throwing at generation time is fail-fast.
- `schema()` returns the published sentence schema (D8)

### NlpTokenizer (SPI) — migrated from message-extraction-api

```java
@FunctionalInterface
public interface NlpTokenizer {
    List<AnnotatedToken> tokenize(String text);
}

public record AnnotatedToken(
    String surface,
    String lemma,
    String pos,
    int start,
    int end
) {
    public AnnotatedToken {
        Objects.requireNonNull(surface, "surface");
        Objects.requireNonNull(lemma, "lemma");
        Objects.requireNonNull(pos, "pos");
    }
}
```

## Generation — Template Slot-Filling (D2, D6)

Templates are bidirectional. Generation re-expands the template via segment-aware template expansion:

1. **Parse segments** — the template is parsed into mandatory and optional segments using the same bracket-aware logic as `TemplateExtractor.parseSegments()` (tracking `inOptional` state, handling `\[`/`\]` escapes, building a segment list).
2. **Substitute variables** — within each segment, `VAR_PATTERN` (`\$\{([^}]+)}`) finds each `${var}` placeholder and replaces it with the corresponding value from the provided map.
3. **Resolve optional segments** — optional segments (`[...]`) are included when all their variables have values, omitted when any variable is missing.
4. **Validate completeness** — if a mandatory segment contains a `${var}` with no value in the map, `generate()` throws `IllegalArgumentException`. Unresolved placeholders in generated output are silent corruption for governed communications.

No morphological rules in the first iteration.

Note: `VariableResolver` (yaml-core) is not used for generation — it requires prefixed variable references (`${prefix.name}`) and throws `UnresolvedVariableException` on bare references. Template variables use bare names (`${decision}`, `${subject}`).

```java
// Extract
TemplateMatch result = registry.match("protocol:review", input);
// result = Matched(namespace="protocol:review", templateName="vote",
//     fields={decision: "approve", subject: "architecture"}, score=1.0)

// Generate
String surface = registry.generate("protocol:review", "vote",
    Map.of("decision", "approve", "subject", "architecture"));
// surface = "I approve this architecture"
```

The template IS the grammatically correct surface form. Variables slot into positions where any value produces correct grammar. POS metadata from parsing is preserved in the compilation output for future morphological enhancement.

## Schema Publication (D8)

Each registered template type publishes a sentence schema. Schemas are queryable via the registry SPI and exposed via `@McpDomain` for REST/GraphQL/MCP access.

`TemplateSchemaEndpoint` lives in `template-registry` (the impl module), not `template-registry-api`, following the established pattern where `@McpDomain` classes reside in core/impl modules (cf. `ConnectionEndpointCore` in `authn-core`, `AgentHttpService` in `agent-http-core`).

```java
@McpDomain("template-schemas")
public class TemplateSchemaEndpoint {

    private final UnifiedTemplateRegistry registry;

    @PlatformQuery
    List<TemplateSchema> listSchemas(
        @ContextParam("tenancyId") String tenancyId);

    @PlatformQuery
    Optional<TemplateSchema> getSchema(
        @ContextParam("tenancyId") String tenancyId,
        String namespace,
        String templateName);

    @PlatformQuery
    TemplateMatch matchTemplate(
        @ContextParam("tenancyId") String tenancyId,
        String namespace,
        String input);
}
```

`tenancyId` is passed for framework identity context propagation (all `@McpDomain` endpoints receive it via `CurrentPrincipal`). It does not filter template schemas — templates are platform-global, not tenant-scoped.

Schema publication is co-located with template registration — when templates are registered, their schemas are automatically available. The schema includes patterns, variables, and (when NLP is on the classpath) POS-annotated structural summaries.

## Migration Path

### ProtocolEvaluator migration

```java
// Before: each TemplateMatchingFilter creates its own ProtocolEvaluator
var evaluator = new ProtocolEvaluator(nlpMatcher);
evaluator.register(protocol);
var result = evaluator.evaluate(key, input);

// After: shared registry, templates registered by namespace
registry.register(new TemplateNamespace("protocol:" + protocol.name(),
    toDefinitions(protocol.templates())));
var result = registry.match("protocol:" + protocol.name(), input);
```

### TemplateMatchingFilter migration

`TemplateMatchingFilter.fromYaml()` is replaced by YAML parsing into `TemplateNamespace` + registry registration. Constraint validation, near-miss detection, and rephrase suggestions are handled by the registry internally.

### PlaybookRunnerCore integration

`PlaybookRunnerCore` currently calls `TemplateMatchingFilter.fromYaml()` when it detects a `templates:` section. This migrates to registering templates with the shared registry under a playbook-scoped namespace.

## Thread Safety

`TemplateDefinition`, `TemplateNamespace`, `TemplateMatch`, `TemplateSchema` are immutable records. The registry implementation uses immutable-snapshot concurrency (D9) — no locking on the read path. Registration operations (startup-time, protocol activation) build new snapshots and swap via `AtomicReference.compareAndSet()` with retry on contention.

## Scope

### In scope
- `template-registry-api` module with types, SPI, regex matching
- `template-registry` module with NLP matching, OpenNLP tokenizer, keyword filter
- Bidirectional: match/extract and generate (slot-filling)
- Schema publication via `@McpDomain` API
- Namespaced template registration
- Lemmatised keyword filtering for candidate selection
- Immutable-snapshot concurrency
- Integration test suite as acceptance criterion (D5)

### Out of scope
- Consumer migration (ProtocolEvaluator, TemplateMatchingFilter, PlaybookRunnerCore) — #961
- POS-driven morphological generation (future — POS metadata preserved) — #962
- ICU MessageFormat 2.0 for multilingual formatting (future) — #963
- Positional discrimination trie (future — when template counts exceed ~100) — #964
- Multi-language support (NlpTokenizer SPI supports it; models required per language) — #965

## References

- `yaml-core/src/main/java/io/casehub/yaml/core/resolver/TemplateExtractor.java` — existing regex template extraction
- `yaml-core/src/main/java/io/casehub/yaml/core/resolver/TemplateRegistry.java` — existing ordered template matching (retired for matching)
- `yaml-core/src/main/java/io/casehub/yaml/core/resolver/VariableConstraint.java` — canonical constraint type
- `coordination-core/src/main/java/io/casehub/platform/coordination/protocol/ProtocolEvaluator.java` — current protocol evaluation (retired)
- `coordination-core/src/main/java/io/casehub/platform/coordination/protocol/NlpProtocolMatcher.java` — NLP SPI (retired, zero implementations)
- `coordination-core/src/main/java/io/casehub/platform/coordination/protocol/TemplateKeywords.java` — keyword extraction (evolved to lemmatised)
- `yaml-step-runtime/src/main/java/io/casehub/yaml/step/runner/TemplateMatchingFilter.java` — playbook template filter (retired)
- `message-extraction-api/src/main/java/io/casehub/extraction/RegexMessageMatcher.java` — regex matching (retired, logic inlined)
- `message-extraction/src/main/java/io/casehub/extraction/nlp/TwoTierMessageMatcher.java` — two-tier matching (retired, logic absorbed)
- `message-extraction/src/main/java/io/casehub/extraction/nlp/StructuralPattern.java` — NLP structural matching (evolved to StructuralMatcher)
- `message-extraction/src/main/java/io/casehub/extraction/nlp/OpenNlpTokenizer.java` — OpenNLP tokenizer (migrated)
- `datasource-alpha/` — Rete alpha network pattern (reference architecture, not reused directly)
- Issue #922 spec — message extraction design (predecessor)
- Issue #943 — parent epic
- Decisions: `specs/issue-959-unified-template-registry/decisions.md` (D1–D10)
