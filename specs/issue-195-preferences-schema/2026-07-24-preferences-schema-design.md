# Preference Schema Registry — Design Spec

**Issue:** casehubio/platform#195
**Date:** 2026-07-24
**Branch:** issue-195-preferences-schema

## Problem

The `preferences-editor/` module exposes CRUD endpoints for preference values, but
all values are raw strings. The blocks-ui `<preferences-editor>` component
(casehubio/blocks-ui#92) needs type metadata to render appropriate editors —
number inputs, toggles, dropdowns, duration pickers. The platform already holds
this information in `PreferenceKey<T>`'s type parameter and the `Preference` type
hierarchy, but nothing exposes it over REST.

## Design

### Architecture — Three Layers

Following the `EventTypeRegistry` / `EventTypeDescriptor` pattern:

| Layer | Module | Artifact |
|-------|--------|----------|
| SPI + descriptor | `platform-api/` | `PreferenceSchemaRegistry`, `PreferenceSchemaDescriptor`, `EnumOption`, `BooleanPreference`, `PreferenceConstraintKeys` |
| NoOp default | `platform/` | `NoOpPreferenceSchemaRegistry @DefaultBean` |
| Real impl + endpoint | `preferences-editor/` | `InMemoryPreferenceSchemaRegistry @ApplicationScoped`, `PreferenceSchemaResource` |

Domain modules (casehub-work, casehub-engine, etc.) inject `PreferenceSchemaRegistry`
and call `register()` at `@Startup`. If `preferences-editor/` is not deployed,
registrations go to the NoOp — no harm done. When `preferences-editor/` is on the
classpath, its `@ApplicationScoped` registry displaces the `@DefaultBean`.

**Why SPI-based registration over CDI discovery:** The issue recommends approach A
(enriching `PreferenceKey` with metadata methods, CDI discovery). This spec uses
approach B (separate registry with explicit registration) for three reasons:

1. **Single responsibility.** `PreferenceKey` is a clean record whose job is
   identifying a preference and carrying its type/parser. UI metadata (label,
   description, constraints, options) is a separate concern — bolting it onto
   `PreferenceKey` gives it two responsibilities and bloats every key declaration
   even when no schema endpoint is deployed.
2. **Pattern consistency.** The SPI approach mirrors the proven `EventTypeRegistry` /
   `EventTypeDescriptor` three-layer architecture. Same CDI displacement contract,
   same module boundaries, same NoOp fallback.
3. **Deployment independence.** Schema metadata is only useful when
   `preferences-editor/` is deployed. With approach B, domain modules register
   descriptors via the SPI — if the module isn't present, registrations go to the
   NoOp and the metadata is never materialised. With approach A, `PreferenceKey`
   carries metadata even when nothing consumes it.

The trade-off: approach A makes all keys discoverable automatically; approach B
requires explicit registration, meaning the schema endpoint ships empty until domain
modules opt in. This bootstrapping gap is by design (same as `EventTypeRegistry`)
and is tracked as casehubio/platform#197.

### platform-api/ — New Types

#### Preference — toSerializedValue()

The `Preference` marker interface gains a serialization method for producing
string representations suitable for REST responses and round-tripping through
`parse()`:

```java
public interface Preference {
    String toSerializedValue();
}
```

Each implementing record provides its conversion:

| Type | `toSerializedValue()` |
|------|----------------------|
| `IntPreference` | `String.valueOf(value)` → `"24"` |
| `DoublePreference` | `String.valueOf(value)` → `"0.5"` |
| `BooleanPreference` | `String.valueOf(value)` → `"true"` |
| `DurationPreference` | `duration.toString()` → `"PT30M"` (ISO 8601) |

This avoids relying on Java record `toString()` output (which produces
`IntPreference[value=24]`, not the raw value needed by the REST API).

#### BooleanPreference

```java
public record BooleanPreference(boolean value) implements SingleValuePreference {
    public static BooleanPreference of(boolean value) {
        return new BooleanPreference(value);
    }
    public static BooleanPreference parse(String raw) {
        Objects.requireNonNull(raw, "raw must not be null");
        return switch (raw.toLowerCase(Locale.ROOT)) {
            case "true" -> new BooleanPreference(true);
            case "false" -> new BooleanPreference(false);
            default -> throw new IllegalArgumentException(
                "Invalid boolean value: '" + raw + "' — expected 'true' or 'false'");
        };
    }
    @Override
    public String toSerializedValue() {
        return String.valueOf(value);
    }
}
```

Fills a natural gap in the type hierarchy alongside `IntPreference`, `DoublePreference`,
`DurationPreference`. The `parse()` method validates strictly — only `"true"` and
`"false"` (case-insensitive) are accepted. This matches the fail-loud contract of
`IntPreference.parse()` (throws `NumberFormatException`) and
`DoublePreference.parse()` (throws `NumberFormatException`). Using
`Boolean.parseBoolean()` would silently return `false` for any non-"true" input
including typos, which is a correctness hazard for a configuration value editor.

#### EnumOption

```java
public record EnumOption(String value, String label) {
    public EnumOption {
        Objects.requireNonNull(value, "value");
        Objects.requireNonNull(label, "label");
    }
}
```

#### PreferenceConstraintKeys

Defines the vocabulary of valid constraint keys per schema type, following the
`EndpointPropertyKeys` pattern for cross-module interop:

```java
public final class PreferenceConstraintKeys {
    /** Minimum value — applies to "integer", "number", "duration" types. */
    public static final String MIN = "min";

    /** Maximum value — applies to "integer", "number", "duration" types. */
    public static final String MAX = "max";

    /** Regex pattern — applies to "string" type. */
    public static final String PATTERN = "pattern";

    /** Minimum string length — applies to "string" type. */
    public static final String MIN_LENGTH = "minLength";

    /** Maximum string length — applies to "string" type. */
    public static final String MAX_LENGTH = "maxLength";

    private PreferenceConstraintKeys() {}
}
```

**Constraint value types by schema type:**

| Schema type | Valid constraint keys | Value type |
|-------------|---------------------|------------|
| `"integer"` | `min`, `max` | `Integer` |
| `"number"` | `min`, `max` | `Double` |
| `"string"` | `pattern`, `minLength`, `maxLength` | `String`, `Integer`, `Integer` |
| `"duration"` | `min`, `max` | `String` (ISO 8601 duration) |
| `"boolean"` | — | — |
| `"enum"` | — | — |

#### PreferenceSchemaDescriptor

Immutable record produced by a builder. The builder takes a `PreferenceKey` and infers
defaults from it.

```java
public record PreferenceSchemaDescriptor(
    String namespace,
    String name,
    String qualifiedName,
    String type,
    String label,
    String description,
    String defaultValue,
    boolean multiValue,
    Map<String, Object> constraints,
    List<EnumOption> options
) {
    public PreferenceSchemaDescriptor {
        Objects.requireNonNull(namespace, "namespace");
        Objects.requireNonNull(name, "name");
        Objects.requireNonNull(qualifiedName, "qualifiedName");
        Objects.requireNonNull(type, "type");
        Objects.requireNonNull(label, "label");
        // description is nullable — consistent with EventTypeDescriptor
        constraints = constraints == null ? Map.of() : Map.copyOf(constraints);
        options = options == null ? List.of() : List.copyOf(options);
    }

    public static Builder of(PreferenceKey<?> key) { ... }

    public static final class Builder {
        // pre-populated from key: namespace, name, qualifiedName, defaultValue,
        //   type (inferred), multiValue (inferred), label (defaults to name)
        public Builder type(String type) { ... }
        public Builder label(String label) { ... }
        public Builder description(String description) { ... }
        public Builder constraints(Map<String, Object> constraints) { ... }
        public Builder options(List<EnumOption> options) { ... }
        public PreferenceSchemaDescriptor build() { ... }
    }
}
```

**Nullability contracts:**

| Field | Nullable? | Default |
|-------|-----------|---------|
| `namespace` | No | from key |
| `name` | No | from key |
| `qualifiedName` | No | from key |
| `type` | No | inferred from key |
| `label` | No | defaults to `name` |
| `description` | Yes | `null` |
| `defaultValue` | No | from `key.defaultValue().toSerializedValue()` |
| `multiValue` | No | inferred from key |
| `constraints` | No | `Map.of()` (empty, never null) |
| `options` | No | `List.of()` (empty, never null) |

Collections are never null — empty for types that don't use them. This matches the
`EventTypeDescriptor` pattern (where `fields` is non-null with defensive copy) and
simplifies consumer code (no null checks on collections).

**Type inference from PreferenceKey's default value type:**

| `key.defaultValue()` type | Inferred schema type |
|---------------------------|----------------------|
| `IntPreference`           | `"integer"`          |
| `DoublePreference`        | `"number"`           |
| `BooleanPreference`       | `"boolean"`          |
| `DurationPreference`      | `"duration"`         |
| Everything else           | `"string"`           |

`IntPreference` maps to `"integer"` and `DoublePreference` maps to `"number"`,
following the JSON Schema convention. This distinction matters for UI rendering:
an integer input uses `step=1` (stepper), a number input allows decimal values.

**Cardinality inference:** The builder infers `multiValue` from
`key.defaultValue() instanceof MultiValuePreference`. `SingleValuePreference` keys
render as a single editor widget; `MultiValuePreference` keys render as a
sub-key-indexed table (e.g., SLA durations per priority level: `P1=PT1H`,
`P2=PT4H`, `P3=PT24H`).

The builder allows overriding the inferred type — required for enum keys:

```java
PreferenceSchemaDescriptor.of(DECLINE_TARGET_KEY)
    .type("enum")
    .label("Decline target")
    .options(List.of(
        new EnumOption("POOL", "Return to pool"),
        new EnumOption("DELEGATOR", "Return to delegator")))
    .build()
```

**Default value serialization:** `key.defaultValue().toSerializedValue()` — each
preference type implements `Preference.toSerializedValue()` to produce the raw
string representation suitable for the REST response (e.g., `"24"`, `"PT30M"`,
`"true"`).

**Label default:** if not set by the builder, defaults to the `name` component of the key.

#### PreferenceSchemaRegistry

```java
public interface PreferenceSchemaRegistry {
    void register(PreferenceSchemaDescriptor descriptor);
    Optional<PreferenceSchemaDescriptor> resolve(String qualifiedName);
    Set<PreferenceSchemaDescriptor> discover();
}
```

Mirrors `EventTypeRegistry`. Append-only at startup, no deregistration.

### platform/ — NoOp Default

```java
@DefaultBean
@ApplicationScoped
public class NoOpPreferenceSchemaRegistry implements PreferenceSchemaRegistry {
    // register: no-op
    // resolve: Optional.empty()
    // discover: Set.of()
}
```

Follows the established pattern (`NoOpPreferenceStore`, `NoOpCaseMemoryStore`, etc.).

### preferences-editor/ — Implementation + Endpoint

#### InMemoryPreferenceSchemaRegistry

`@ApplicationScoped`, displaces the `@DefaultBean`.
`ConcurrentHashMap<String, PreferenceSchemaDescriptor>` keyed by `qualifiedName`.
Duplicate registrations overwrite (last writer wins — supports startup ordering
flexibility). When the incoming descriptor differs from the existing one for the
same `qualifiedName`, a WARN-level log is emitted to flag potential configuration
bugs without failing startup.

#### PreferenceSchemaResource

Separate resource class from `PreferenceResource` — different concern (read-only
metadata vs value CRUD).

```
GET /preferences/schema                          → List<PreferenceSchemaDescriptor>
GET /preferences/schema?namespace=casehub.work    → filtered by namespace
```

`@RunOnVirtualThread` for consistency with the module. No tenant filtering — schema
is global metadata, not per-tenant data. Response is the descriptor list serialized
directly by Jackson — the record shape matches the issue's JSON spec.

## Testing

### platform-api/ unit tests

- `BooleanPreference`: parse valid ("true", "false", case-insensitive), parse invalid
  (throws `IllegalArgumentException` for "yes", "1", "treu", arbitrary strings), of, null rejection
- `Preference.toSerializedValue()`: each type produces the expected raw string
  (`IntPreference(24)` → `"24"`, `DurationPreference(Duration.ofMinutes(30))` → `"PT30M"`, etc.)
- `PreferenceSchemaDescriptor` builder:
  - Type inference from each preference type (IntPreference → integer, DoublePreference → number, BooleanPreference → boolean, DurationPreference → duration, unknown → string)
  - `multiValue` inference (SingleValuePreference → false, MultiValuePreference → true)
  - Label defaults to name when not set
  - Explicit type override
  - Enum options
  - Constraints map with `PreferenceConstraintKeys`
  - Null checks on required fields (namespace, name, qualifiedName, type)
  - Nullability: description nullable, constraints defaults to empty map, options defaults to empty list
  - Default value uses `toSerializedValue()` (not record toString)

### preferences-editor/ unit tests

- `InMemoryPreferenceSchemaRegistry`: register, resolve, discover, duplicate key
  overwrites, WARN log on differing-overwrite (verify log output)

### preferences-editor/ integration tests

- `@QuarkusTest` with a test `@Startup` bean that registers sample descriptors
- `GET /preferences/schema` returns all registered entries with correct JSON shape
  (including `multiValue` field, null `description`, empty `constraints`/`options`)
- `GET /preferences/schema?namespace=X` filters correctly
- `GET /preferences/schema?namespace=nonexistent` returns empty list

## Not In Scope

- **Server-side preference value validation using schema constraints** — tracked as casehubio/platform#196
- **Schema versioning** — tracked as casehubio/platform#198
- **Custom/composite types beyond string, number, boolean, enum, duration** — tracked as casehubio/platform#199
- **Registering real preference keys from domain modules** — tracked as casehubio/platform#197
