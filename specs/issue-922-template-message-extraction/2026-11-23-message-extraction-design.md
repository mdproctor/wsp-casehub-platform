# Message Extraction — Design Spec

**Issue:** #922
**Date:** 2026-11-23

## Purpose

A standalone engine that turns structured prose into typed data. LLM agents communicate using prescribed sentence templates — the engine extracts structured fields from those sentences mechanically, without an LLM in the extraction loop. The extracted data drives logging, task creation, and governance decisions.

The templates serve dual purpose: instructions to the LLM ("say it this way") and extraction rules for the platform ("parse it this way"). This is an alternative to JSON for LLM-to-LLM communication — structured, human-readable, and mechanically extractable.

## Architecture

### Module Structure

```
message-extraction-api     (zero-dep: SPI types, regex matcher)
        ↑
message-extraction          (NLP structural matcher, OpenNLP default tokenizer)
```

**`message-extraction-api`** — Pure Java, zero external dependencies. Contains:
- Core types: `MessageSchema`, `MessageType`, `VariableConstraint`, `MessageMatch`
- SPI: `NlpTokenizer`, `AnnotatedToken`
- Interface: `MessageMatcher`
- Implementation: `RegexMessageMatcher` (compiled regex patterns, first-match-wins)

**`message-extraction`** — Depends on `message-extraction-api` + Apache OpenNLP. Contains:
- `TwoTierMessageMatcher` (wraps regex + NLP: tries regex first, falls back to NLP)
- `OpenNlpTokenizer` implements `NlpTokenizer` (tokenization, POS tagging, lemmatization)
- NLP structural pattern compilation (runs NLP pipeline on template literal segments at matcher construction time to determine POS tags)
- Bundled OpenNLP English models as classpath resources (lazy-loaded on first NLP match attempt)

NLP structural pattern compilation happens inside `TwoTierMessageMatcher`, not in `MessageSchema`. The schema holds templates as strings; the matcher compiles them to structural patterns using its `NlpTokenizer`. This keeps `MessageSchema` in the zero-dep `-api` module.

### Two-Tier Matching (D2)

**Tier 1 — Regex (in `-api`, zero-dep):** Templates compile to regex patterns identical to the existing `TemplateExtractor` approach. Handles exact and near-exact matches in microseconds. This is the common case — well-prompted LLMs follow templates closely.

**Tier 2 — NLP structural (in `-impl`):** Templates compile to structural patterns anchored by POS tags and lemmas. Handles grammatical variation (approve/approved/approves, item/items, a/an). Falls back when regex doesn't match. Returns a coverage score in (0, 1.0].

The regex tier subsumes keyword pre-filtering — it is strictly more precise and equally fast.

### Matching Pipeline

```
Input prose
  │
  ├─ Tier 1: Regex match against all templates
  │   ├─ Pattern match? → Post-match constraint validation
  │   │   ├─ Constraints pass → Matched(type, fields, score=1.0)
  │   │   └─ Constraints fail → try next template
  │   └─ No regex match → fall through
  │
  └─ Tier 2: NLP structural match (if regex missed)
      ├─ Tokenize → POS tag → Lemmatize (via NlpTokenizer SPI)
      ├─ Match against structural patterns (constraints enforced during match)
      └─ Match? → Matched(type, fields, score=coverage)
  │
  └─ No match → Unmatched(input)
```

### Constraint Enforcement

Enum constraints are enforced uniformly across both tiers via post-match validation. The regex tier extracts variable values using `.+?` capture groups (same as `TemplateExtractor`), then validates extracted values against `VariableConstraint`. If validation fails, the template does not match and the next template is tried. This keeps regex compilation simple while ensuring consistent constraint behaviour across tiers.

## Core Types

### MessageSchema

A collection of message types with their templates and variable constraints. The canonical Java model — constructed via Java DSL builder, loaded from YAML storage, or both.

```java
var schema = MessageSchema.builder()
    .message("vote")
        .template("I ${decision} this ${subject}[ because ${rationale}]")
        .variable("decision", VariableConstraint.enumOf("approve", "reject", "abstain"))
        .variable("subject", VariableConstraint.string())
        .variable("rationale", VariableConstraint.string().optional())
        .done()
    .message("escalate")
        .template("Escalating to ${target}[ due to ${reason}]")
        .variable("target", VariableConstraint.string())
        .variable("reason", VariableConstraint.string().optional())
        .done()
    .build();
```

### MessageMatch (D7)

Sealed interface — the extraction result. Immutable and thread-safe.

```java
public sealed interface MessageMatch {
    record Matched(String type, int templateIndex, Map<String, String> fields, double score) implements MessageMatch {}
    record Unmatched(String input) implements MessageMatch {}
}
```

`templateIndex` identifies which template within a multi-template message type matched (0-based). This preserves template identity — consumers can distinguish "I approve this design" (full form, index 0) from "approve" (terse form, index 1).

- Regex tier: score is always 1.0 (exact match)
- NLP tier: score is coverage ratio in (0, 1.0] — the fraction of structural elements matched
- Consumers can threshold on score to reject low-confidence matches

### MessageMatcher

The extraction interface — implemented by `RegexMessageMatcher` (in `-api`) and `TwoTierMessageMatcher` (in `-impl`).

```java
public interface MessageMatcher {
    MessageMatch match(String input);
}
```

### NlpTokenizer (SPI)

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

### VariableConstraint

```java
public sealed interface VariableConstraint {
    record StringConstraint(boolean required) implements VariableConstraint {}
    record EnumConstraint(Set<String> values, boolean required) implements VariableConstraint {}

    static VariableConstraint string() { ... }
    static VariableConstraint enumOf(String... values) { ... }
    VariableConstraint optional();
}
```

## Thread Safety

`MessageSchema`, `RegexMessageMatcher`, and `TwoTierMessageMatcher` are immutable after construction and inherently thread-safe. Compiled patterns are stored in `final` fields; matching creates no mutable state. Same guarantees as `TemplateExtractor` and `TemplateRegistry`.

## NLP Structural Matching

A template like `"I ${decision} this ${subject} because ${rationale}"` compiles to:

```
[PRONOUN:I] [VERB:decision{approve,reject,abstain}] [DET] [NOUN:subject] [CONJ:because] [CLAUSE:rationale]
```

The displayed template text is a rendered approximation. The structural pattern is what actually matches at runtime. Matching operates on lemmatised tokens with POS tags — so "I approved this design" matches because `approved` lemmatises to `approve` and POS-tags as VERB.

### Structural Pattern Elements

| Element | Matches | Example |
|---------|---------|---------|
| Literal | Exact token (case-insensitive) | `[PRONOUN:I]` |
| POS-anchored variable | Token with matching POS tag | `[VERB:decision]` |
| Constrained variable | Token matching POS + enum values (by lemma) | `[VERB:decision{approve,reject,abstain}]` |
| Clause variable | Remaining tokens to end or next literal anchor | `[CLAUSE:rationale]` |
| DET/CONJ/PREP | Structural markers — match by POS, not content | `[DET]`, `[CONJ:because]` |

### Variable Extraction in NLP Tier

- **Enum variables** (`[VERB:decision{approve,reject,abstain}]`): extracted value is the **lemma** (e.g., "approved" → "approve"). The lemma matches against the enum values.
- **String variables** (`[NOUN:subject]`): extracted value is the **surface token(s)**. Single-token capture — NP chunking is out of scope for this iteration.
- **Clause variables** (`[CLAUSE:rationale]`): captured as all surface tokens from the current position to the next literal anchor or end of input. Joined with spaces.

### Score Calculation

Coverage score = (matched elements / total template elements). A template with 6 elements where 5 match produces score 0.83. When multiple templates partially match, highest score wins above a minimum threshold.

Threshold is set on `TwoTierMessageMatcher` construction (default: 0.5). Matches below the threshold are treated as `Unmatched`.

## YAML Storage Format (Convention)

Message schemas persist as YAML — the standard CaseHub data format. The YAML format is documented here as a convention; deserialization is a consumer concern (not in the engine modules).

```yaml
messages:
  vote:
    templates:
      - "I ${decision} this ${subject}[ because ${rationale}]"
      - "${decision}[ — ${rationale}]"
    variables:
      decision: { type: enum, values: [approve, reject, abstain] }
      subject: { type: string }
      rationale: { type: string, required: false }

  escalate:
    templates:
      - "Escalating to ${target}[ due to ${reason}]"
    variables:
      target: { type: string }
      reason: { type: string, required: false }
```

Consumers deserialize YAML and build `MessageSchema` via the Java DSL builder.

## Migration (D8)

`ProtocolEvaluator` in `coordination-core` currently uses `TemplateRegistry` (from `yaml-core`) for response matching. It migrates to depend on `message-extraction-api` (zero-dep, no footprint change) and use `RegexMessageMatcher`. This is mechanical — same capability, standardised interface.

`TemplateExtractor` in `yaml-core` continues unchanged for YAML variable resolution (forward direction).

## Scope

### In scope (this iteration)
- `message-extraction-api` module with core types and regex matcher
- `message-extraction` module with NLP structural matcher and OpenNLP tokenizer
- Java DSL builder for `MessageSchema`
- YAML storage format documented as convention (deserialization is consumer-side)
- English language only (D9)
- Build-time schema definition (D4)

### Out of scope (future)
- LLM-generated NLP processors (roadmap — requires runtime service)
- Runtime service for dynamic schema registration
- Multi-language support (NlpTokenizer SPI supports it; models required per language)
- Playbook integration (consumer concern)
- ProtocolEvaluator migration (mechanical — ProtocolEvaluator and ProtocolDefinitionParser both migrate together)
- `TemplateExtractor` deprecation for extraction use (long-term direction: extraction use migrates to `RegexMessageMatcher`; `TemplateExtractor` continues for forward interpolation)

## References

- `yaml-core/src/main/java/io/casehub/yaml/core/resolver/TemplateExtractor.java` — existing regex-based template extraction
- `yaml-core/src/main/java/io/casehub/yaml/core/resolver/TemplateRegistry.java` — existing ordered template matching
- `coordination-core/src/main/java/io/casehub/platform/coordination/protocol/ProtocolEvaluator.java` — current protocol response matching
- `coordination-core/src/main/java/io/casehub/platform/coordination/protocol/ProtocolMatchResult.java` — sealed match result pattern
- Apache OpenNLP — tokenization, POS tagging, lemmatization
- ICU MessageFormat 2.0 — grammar agreement for generation (no reverse parsing)
- GATE/JAPE — annotation pattern matching (too heavyweight to embed)
- Issue #922 — original feature proposal
