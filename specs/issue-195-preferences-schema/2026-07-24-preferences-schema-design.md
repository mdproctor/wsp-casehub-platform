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
| SPI + descriptor | `platform-api/` | `PreferenceSchemaRegistry`, `PreferenceSchemaDescriptor`, `EnumOption`, `BooleanPreference` |
| NoOp default | `platform/` | `NoOpPreferenceSchemaRegistry @DefaultBean` |
| Real impl + endpoint | `preferences-editor/` | `InMemoryPreferenceSchemaRegistry @ApplicationScoped`, `PreferenceSchemaResource` |

Domain modules (casehub-work, casehub-engine, etc.) inject `PreferenceSchemaRegistry`
and call `register()` at `@Startup`. If `preferences-editor/` is not deployed,
registrations go to the NoOp — no harm done. When `preferences-editor/` is on the
classpath, its `@ApplicationScoped` registry displaces the `@DefaultBean`.

### platform-api/ — New Types

#### BooleanPreference

```java
public record BooleanPreference(boolean value) implements SingleValuePreference {
    public static BooleanPreference of(boolean value) {
        return new BooleanPreference(value);
    }
    public static BooleanPreference parse(String raw) {
        Objects.requireNonNull(raw, "raw must not be null");
        return new BooleanPreference(Boolean.parseBoolean(raw));
    }
}
```

Fills a natural gap in the type hierarchy alongside `IntPreference`, `DoublePreference`,
`DurationPreference`.

#### EnumOption

```java
public record EnumOption(String value, String label) {
    public EnumOption {
        Objects.requireNonNull(value, "value");
        Objects.requireNonNull(label, "label");
    }
}
```

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
    Map<String, Object> constraints,
    List<EnumOption> options
) {
    // compact constructor: null checks on required fields, defensive copies

    public static Builder of(PreferenceKey<?> key) { ... }

    public static final class Builder {
        // pre-populated from key: namespace, name, qualifiedName, defaultValue, type (inferred)
        public Builder type(String type) { ... }
        public Builder label(String label) { ... }
        public Builder description(String description) { ... }
        public Builder constraints(Map<String, Object> constraints) { ... }
        public Builder options(List<EnumOption> options) { ... }
        public PreferenceSchemaDescriptor build() { ... }
    }
}
```

**Type inference from PreferenceKey's default value type:**

| `key.defaultValue()` type | Inferred schema type |
|---------------------------|----------------------|
| `IntPreference`           | `"number"`           |
| `DoublePreference`        | `"number"`           |
| `BooleanPreference`       | `"boolean"`          |
| `DurationPreference`      | `"duration"`         |
| Everything else           | `"string"`           |

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

**Default value serialization:** `String.valueOf(key.defaultValue())` — relies on the
preference record's `toString()`. For records this produces the component values, which
is sufficient for string/number/boolean. Duration keys should use the `Duration` ISO
string. This may need a `toStringValue()` method on `Preference` if `toString()` output
is not clean enough — evaluate during implementation.

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
Duplicate registrations overwrite silently (last writer wins — supports startup
ordering flexibility).

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

- `BooleanPreference`: parse, of, null rejection
- `PreferenceSchemaDescriptor` builder:
  - Type inference from each preference type (IntPreference → number, DoublePreference → number, BooleanPreference → boolean, DurationPreference → duration, unknown → string)
  - Label defaults to name when not set
  - Explicit type override
  - Enum options
  - Constraints map
  - Null checks on required fields (namespace, name, qualifiedName, type)

### preferences-editor/ unit tests

- `InMemoryPreferenceSchemaRegistry`: register, resolve, discover, duplicate key overwrites

### preferences-editor/ integration tests

- `@QuarkusTest` with a test `@Startup` bean that registers sample descriptors
- `GET /preferences/schema` returns all registered entries with correct JSON shape
- `GET /preferences/schema?namespace=X` filters correctly
- `GET /preferences/schema?namespace=nonexistent` returns empty list

## Not In Scope

- Server-side preference value validation using schema constraints
- Schema versioning
- Custom/composite types beyond string, number, boolean, enum, duration
- Registering real preference keys from domain modules (they will use this SPI but that work belongs to each domain repo)
