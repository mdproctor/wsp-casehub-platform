# Domain Data Generation — Design Spec

**Issue:** casehubio/platform#330
**Branch:** issue-294-simulation-service
**Date:** 2026-09-18

---

## Problem

Corpus population is the adoption bottleneck. The simulation framework
has 4 data generation paths (capture, YAML fixtures, corpus builders,
LLM generation) but lacks schema-driven random generation — the path
that requires zero domain knowledge and zero manual effort. A developer
writing their first simulation test needs `generate(MyRecord.class, 50)`
without understanding corpus builders or writing LLM prompts.

## Scope

**In scope:**
- `SchemaDataGenerator` in schema-generator — JSON Schema → random instances
- Jakarta Validation constraint support (min/max, pattern, string length)
- `$ref` / `$defs` resolution for nested types
- Both `List<JsonNode>` and `List<T>` typed APIs
- Thin CorpusSeed integration in simulation-testing

**Out of scope:**
- Semantic/domain-plausible generation (that's LlmCorpusPopulator)
- `oneOf`/`anyOf` polymorphic generation (future extension)
- Custom generator registration (future extension)

## Design

### 1. SchemaDataGenerator (schema-generator module)

A new class alongside `PlatformSchemaGenerator`. Takes a JSON Schema
(Draft 2020-12, as produced by `PlatformSchemaGenerator.generate()`)
and produces random instances that satisfy the schema's structural
and constraint requirements.

```java
public class SchemaDataGenerator {

    private final Random random;

    public SchemaDataGenerator() {
        this(new Random());
    }

    public SchemaDataGenerator(Random random) {
        this.random = random;
    }

    public List<JsonNode> generate(JsonNode schema, int count) { ... }

    public <T> List<T> generate(JsonNode schema, int count,
                                Class<T> targetType,
                                ObjectMapper mapper) { ... }
}
```

Constructor takes an optional `Random` for reproducible test output
(seeded random). The typed overload deserializes via
`ObjectMapper.treeToValue()`.

### 2. Supported schema features

| Schema keyword | Behavior |
|---------------|----------|
| `type: string` | Random alphanumeric string (8-20 chars default) |
| `type: integer` | Random int within min/max or Integer.MIN/MAX |
| `type: number` | Random double within min/max or -1000.0/1000.0 |
| `type: boolean` | Random true/false |
| `type: array` | Random length within minItems/maxItems (default 1-3), recursive element generation |
| `type: object` | Generate all `required` properties + random subset of optional properties |
| `enum` | Random selection from declared values |
| `minLength` / `maxLength` | String length bounded |
| `pattern` | Best-effort regex-guided generation (alphanumeric fill for simple patterns; falls back to constrained-length string for complex regex) |
| `minimum` / `maximum` | Numeric bounds respected |
| `minItems` / `maxItems` | Array size bounds respected |
| `$ref` / `$defs` | Resolved internally with depth guard (max 20) |
| `format: date-time` | Random ISO-8601 timestamp within reasonable range |
| `format: uuid` | Random UUID |
| `const` | Returns the constant value |

### 3. $ref resolution

The generator extracts `$defs` from the root schema and resolves
`$ref` pointers during traversal. A depth counter prevents infinite
recursion on self-referential schemas — at max depth (20), nullable
fields return null and required fields throw
`SchemaGenerationException`.

### 4. CorpusSeed integration (simulation-testing)

A static convenience method on a new `RandomCorpusPopulator` class:

```java
public final class RandomCorpusPopulator {

    public static <I, O> void populate(CorpusSeed<I, O> seed,
                                        Class<I> inputType,
                                        Class<O> outputType,
                                        int count,
                                        ObjectMapper mapper) {
        var schemaGen = new PlatformSchemaGenerator();
        var dataGen = new SchemaDataGenerator();
        var inputSchema = schemaGen.generate(inputType);
        var outputSchema = schemaGen.generate(outputType);
        var inputs = dataGen.generate(inputSchema, count, inputType, mapper);
        var outputs = dataGen.generate(outputSchema, count, outputType, mapper);
        for (int i = 0; i < count; i++) {
            seed.add(inputs.get(i), outputs.get(i));
        }
    }
}
```

This pairs with `LlmCorpusPopulator` — same module, same pattern,
different data realism level.

### 5. DataRealism mapping

| Generator | DataRealism | Use case |
|-----------|-------------|----------|
| `SchemaDataGenerator` (no constraints) | `PLACEHOLDER` | Load testing (shape matters, content doesn't) |
| `SchemaDataGenerator` (with constraints) | `STRUCTURALLY_VALID` | Integration testing |
| `LlmCorpusPopulator` | `DOMAIN_PLAUSIBLE` | Demo, realistic scenarios |
| Capture mode | `RECORDED_REAL` | CI replay, regression |

## Deliverables

1. **SchemaDataGenerator** — in schema-generator
2. **SchemaGenerationException** — in schema-generator (for depth overflow, unsupported schema)
3. **SchemaDataGenerator unit tests** — per-type, constraint, $ref, edge cases
4. **RandomCorpusPopulator** — in simulation-testing (thin CorpusSeed integration)
5. **RandomCorpusPopulator test** — verifies typed generation + seeding
6. **Simulation guide update** — schema-driven random generation section
7. **CLAUDE.md update** — schema-generator module description

## Testing

- **Per-type generation:** string, integer, number, boolean, array,
  object — each with and without constraints.
- **Constraint satisfaction:** minLength/maxLength, min/max, enum
  selection, pattern (simple regex), minItems/maxItems.
- **$ref resolution:** nested objects, shared definitions, depth guard.
- **Typed deserialization:** generate → treeToValue → verify fields.
- **Reproducibility:** seeded Random produces identical output.
- **Edge cases:** empty schema, null type, missing required field.

## Trade-offs

- **No semantic awareness** (D75) — generated data is structurally
  valid but semantically random. A `patientName` will be a valid-length
  string, not a real name. For domain-plausible data, use
  LlmCorpusPopulator.

- **Best-effort regex** (D75) — `pattern` support handles simple
  patterns (character classes, length quantifiers) but falls back to
  constrained-length alphanumeric for complex regex. Full regex-to-string
  generation (Xeger, dk.brics.automaton) is a heavyweight dependency for
  marginal benefit.

- **No `oneOf`/`anyOf`** — polymorphic schema generation is deferred.
  The SealedHierarchyModule produces `oneOf` schemas for sealed
  interfaces. Random selection from `oneOf` branches is a natural
  extension but adds complexity to the initial implementation.

## References

- PlatformSchemaGenerator.java — schema generation, JakartaValidationModule
- SchemaPostProcessor.java — $schema insertion
- LlmCorpusPopulator.java — parallel pattern in simulation-testing
- CorpusSeed.java — accumulation API for seeding
- DataRealism.java — 5-level enum
- D75 — scope: constraint support, remaining deliverable
- D76 — module split: core in schema-generator, integration in simulation-testing
- D77 — $ref resolution built in
- D78 — dual API: raw JsonNode + typed convenience
- Issue #330 — domain data generation
