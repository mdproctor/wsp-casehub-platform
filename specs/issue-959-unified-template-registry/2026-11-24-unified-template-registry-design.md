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
template-registry-api  (zero-dep Declaration Primitive — types, SPI, regex matching)
    ↑
template-registry      (L4 Extension — NLP matching, OpenNLP, structural patterns)
```

**`template-registry-api`** — Pure Java, zero external dependencies. Contains:
- Core types: `TemplateDefinition`, `TemplateNamespace`, `TemplateMatch`, `TemplateSchema`
- Registry SPI: `TemplateRegistry` (register/deregister/match/generate/schema)
- Regex compilation and matching (inlined from `RegexMessageMatcher`)
- `NlpTokenizer` SPI and `AnnotatedToken` (migrated from `message-extraction-api`)
- `@McpDomain` API interface for schema discovery and matching operations
- Depends on `yaml-core` for `VariableConstraint` (canonical definition)

**`template-registry`** — Depends on `template-registry-api` + Apache OpenNLP. Contains:
- `NlpTemplateCompiler` — structural pattern compilation from templates using NLP pipeline
- `StructuralMatcher` — lemma/POS-based matching (evolved from `StructuralPattern`)
- `OpenNlpTokenizer` (migrated from `message-extraction`)
- `LemmatisedKeywordFilter` — upgraded `TemplateKeywords` operating on lemmatised tokens
- `@ApplicationScoped` registry implementation with immutable-snapshot concurrency

### Existing Modules — Disposition

| Module / Type | Disposition |
|--------------|-------------|
| `TemplateExtractor` (yaml-core) | **Kept** — YAML variable resolution (forward interpolation) |
| `VariableConstraint` (yaml-core) | **Kept as canonical** — template-registry-api depends on it |
| `TemplateRegistry` (yaml-core) | **Retired for matching** — unified registry replaces. Builder/build pattern continues for TemplateExtractor use |
| `ProtocolEvaluator` (coordination-core) | **Retired** — migrates to unified registry |
| `NlpProtocolMatcher` (coordination-core) | **Retired** — zero implementations, role absorbed (D7) |
| `TemplateKeywords` (coordination-core) | **Evolved** — becomes `LemmatisedKeywordFilter` in template-registry |
| `TemplateMatchingFilter` (yaml-step-runtime) | **Retired** — migrates to unified registry |
| `TemplateMatchResult` (yaml-step-runtime) | **Retired** — replaced by `TemplateMatch` |
| `TemplateMatchEvent` (yaml-step-runtime) | **Retired** — fields absorbed into `TemplateMatch` |
| `RegexMessageMatcher` (message-extraction-api) | **Retired** — compilation logic inlined into template-registry-api |
| `TwoTierMessageMatcher` (message-extraction) | **Retired** — two-tier logic absorbed into registry |
| `StructuralPattern` (message-extraction) | **Evolved** — becomes `StructuralMatcher` in template-registry |
| `OpenNlpTokenizer` (message-extraction) | **Migrated** — to template-registry |
| `MessageSchema`, `MessageType` (message-extraction-api) | **Retired** — registry handles type definitions |
| `VariableConstraint` (message-extraction-api) | **Retired** — yaml-core copy is canonical |
| `message-extraction-api` module | **Retired** — types absorbed into template-registry-api |
| `message-extraction` module | **Retired** — NLP code absorbed into template-registry |

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

Immutable snapshots with atomic swap. The internal index (keyword sets, compiled templates, regex patterns) is immutable after build. Register/deregister operations build a new snapshot and atomically swap it via `volatile` field. Readers see a consistent snapshot — no locking on the read path.

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
    public static Builder builder(String name) { ... }
}
```

### TemplateNamespace

Groups templates by source (playbook, protocol, runtime). Prevents name collisions.

```java
public record TemplateNamespace(
    String name,
    Map<String, TemplateDefinition> templates
) {}
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
    ) implements TemplateMatch {}

    record NearMiss(
        String input,
        String suggestedTemplate,
        String suggestedFormat
    ) implements TemplateMatch {}

    record Unmatched(String input) implements TemplateMatch {}
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
    void register(TemplateNamespace namespace);
    void deregister(String namespaceName);

    TemplateMatch match(String input);
    TemplateMatch match(String namespaceName, String input);

    String generate(String namespaceName, String templateName,
                    Map<String, String> values);

    Optional<TemplateSchema> schema(String namespaceName,
                                     String templateName);
    List<TemplateSchema> schemas(String namespaceName);

    Set<String> namespaces();
}
```

- `match(input)` searches all namespaces
- `match(namespace, input)` scopes to a single namespace
- `generate()` produces a surface form via template slot-filling (D2, D6)
- `schema()` returns the published sentence schema (D8)

### NlpTokenizer (SPI) — migrated from message-extraction-api

```java
public interface NlpTokenizer {
    List<AnnotatedToken> tokenize(String text);
}

public record AnnotatedToken(
    String surface,
    String lemma,
    String pos,
    int start,
    int end
) {}
```

## Generation — Template Slot-Filling (D2, D6)

Templates are bidirectional. Generation re-expands the template by substituting `${var}` placeholders with values via `VariableResolver`. No morphological rules in the first iteration.

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

Each registered template type publishes a sentence schema. Schemas are queryable via the registry API and exposed via `@McpDomain` for REST/GraphQL/MCP access.

```java
@McpDomain("template-schemas")
public interface TemplateSchemaApi {

    @PlatformQuery
    List<TemplateSchema> listSchemas(@ContextParam String tenancyId);

    @PlatformQuery
    Optional<TemplateSchema> getSchema(
        @ContextParam String tenancyId,
        String namespace,
        String templateName
    );

    @PlatformQuery
    TemplateMatch matchTemplate(
        @ContextParam String tenancyId,
        String namespace,
        String input
    );
}
```

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

`TemplateDefinition`, `TemplateNamespace`, `TemplateMatch`, `TemplateSchema` are immutable records. The registry implementation uses immutable-snapshot concurrency (D9) — no locking on the read path. Registration operations (startup-time, protocol activation) build and swap snapshots atomically.

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
- POS-driven morphological generation (future — POS metadata preserved)
- ICU MessageFormat 2.0 for multilingual formatting (future)
- Positional discrimination trie (future — when template counts exceed ~100)
- Consumer migration (ProtocolEvaluator, TemplateMatchingFilter, PlaybookRunnerCore) — separate issues
- Multi-language support (NlpTokenizer SPI supports it; models required per language)

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
