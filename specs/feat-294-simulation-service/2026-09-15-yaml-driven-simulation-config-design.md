# YAML-Driven Simulation Configuration — Design Spec

**Issue:** casehubio/platform#325
**Branch:** issue-294-simulation-service
**Date:** 2026-09-15
**Depends on:** Phase 1 (simulation-api, simulation-core, simulation-inmem, simulation-generator, agent-simulation-core)

## Overview

Three gaps in the simulation framework's usability: (1) the documented
`application.properties` keys don't work — `SimulationConfig` has no
implementation, (2) corpus seeding is Java-only, (3) common KeyExtractor
patterns require code. This spec fills all three with a single new module
pair: `simulation-config-core` (POJO) + `simulation-config` (Quarkus beans).

## Architecture

### Module structure

```
simulation-config-core/    jar — POJO, no CDI
  ├── SmallRyeSimulationConfig   implements SimulationConfig
  ├── YamlCorpusLoader           parses YAML fixture files
  └── DeclarativeExtractorFactory creates KeyExtractors from config strings

simulation-config/         jar — Quarkus beans
  └── SimulationConfigBeans      @Produces SimulationConfig + corpus populator
```

Follows the established core/Quarkus split (config-core/config,
endpoints-config-core/endpoints-config).

### Dependencies

**simulation-config-core:**
- `simulation-api` (compile) — SimulationConfig, SimulationCorpus, InvocationRecord, KeyExtractor
- `simulation-core` (compile) — SimulationRuntime (for extractor registration)
- Jackson databind (compile) — YAML parsing + ObjectMapper.convertValue for extractors
- Jackson dataformat-yaml (compile) — YAML corpus file parsing
- SmallRye Config API (compile) — ConfigProvider.getConfig() for property scanning

**simulation-config:**
- `simulation-config-core` (compile)
- Quarkus Arc (compile) — CDI @Produces, @Startup

## Deliverable 1: SmallRyeSimulationConfig

### Config key pattern

```
casehub.simulation.<spi-name>.<method-name>.strategy=<strategy-key>
casehub.simulation.<spi-name>.<method-name>.capture=true|false
casehub.simulation.<spi-name>.<method-name>.exhaustion-policy=WRAP|THROW
casehub.simulation.<spi-name>.<method-name>.key-extractor=<extractor-spec>
```

### Implementation approach — manual prefix scanning (D13)

At construction time, `SmallRyeSimulationConfig` scans all config property
names matching the `casehub.simulation.*` prefix. It parses each key into
a qualified name (`spi-name.method-name`) and a property name (`strategy`,
`capture`, `exhaustion-policy`, `key-extractor`). Results are stored in a
`Map<String, MethodSimulationConfig>` keyed by qualified name.

```java
public class SmallRyeSimulationConfig implements SimulationConfig {

    private final Map<String, MethodSimulationConfig> methods;

    public SmallRyeSimulationConfig(Config config) {
        this.methods = new HashMap<>();
        String prefix = "casehub.simulation.";
        for (String name : config.getPropertyNames()) {
            if (!name.startsWith(prefix)) continue;
            // Skip non-method keys (e.g. corpus.files)
            String suffix = name.substring(prefix.length());
            String[] parts = suffix.split("\\.");
            if (parts.length != 3) continue;  // spi.method.property
            String qualifiedName = parts[0] + "." + parts[1];
            String property = parts[2];
            config.getOptionalValue(name, String.class)
                .ifPresent(value -> methods
                    .computeIfAbsent(qualifiedName, k -> new MethodSimulationConfig())
                    .set(property, value));
        }
    }

    @Override
    public Optional<String> strategyFor(String qualifiedName) {
        return Optional.ofNullable(methods.get(qualifiedName))
            .flatMap(MethodSimulationConfig::strategy);
    }

    @Override
    public boolean captureEnabled(String qualifiedName) {
        return Optional.ofNullable(methods.get(qualifiedName))
            .map(MethodSimulationConfig::capture)
            .orElse(false);
    }

    @Override
    public Optional<ExhaustionPolicy> exhaustionPolicy(String qualifiedName) {
        return Optional.ofNullable(methods.get(qualifiedName))
            .flatMap(MethodSimulationConfig::exhaustionPolicy);
    }
}
```

### Reserved key namespaces

Keys with fewer than 3 dot-separated segments after the prefix are
reserved for framework-level config (e.g., `casehub.simulation.corpus.files`).
The parser skips them — they don't interfere with per-method config.

### MethodSimulationConfig

Internal value class holding parsed per-method settings:

```java
class MethodSimulationConfig {
    private String strategy;        // nullable
    private boolean capture;        // default false
    private ExhaustionPolicy exhaustionPolicy;  // nullable → WRAP
    private String keyExtractor;    // nullable — declarative spec

    Optional<String> strategy() { ... }
    boolean capture() { ... }
    Optional<ExhaustionPolicy> exhaustionPolicy() { ... }
    Optional<String> keyExtractor() { ... }

    void set(String property, String value) {
        switch (property) {
            case "strategy" -> this.strategy = value;
            case "capture" -> this.capture = Boolean.parseBoolean(value);
            case "exhaustion-policy" -> this.exhaustionPolicy =
                ExhaustionPolicy.valueOf(value.toUpperCase().replace("-", "_"));
            case "key-extractor" -> this.keyExtractor = value;
        }
    }
}
```

## Deliverable 2: YAML corpus fixture files

### File format

```yaml
# simulation-corpus.yaml — keyed by qualified name (spi.method)
case-memory-store.query:
  - key: cardiology
    tenancy-id: hospital-a
    input:
      domain: cardiology
      question: "latest labs"
    output: "Lab results for cardiology"

  - key: neurology
    tenancy-id: hospital-a
    input:
      domain: neurology
      question: "MRI scan"
    output: "MRI results"

agent-provider.invoke:
  - key: greeting
    tenancy-id: t1
    input:
      system-prompt: "You are a helpful assistant"
      user-prompt: "Hello"
    output:
      - type: TextDelta
        text: "Hello! How can I help?"
```

### Type handling (D14)

Input and output are deserialized as native YAML types — `String`,
`Map<String, Object>`, `List`, `Number`, `Boolean`. No type-aware
deserialization. `InvocationRecord<Object, Object>` is used for all
YAML-loaded entries.

**Limitation:** SPIs with rich domain return types (e.g., `List<Memory>`)
can't use YAML corpus directly. Use programmatic seeding or corpus
builders (#328) for typed responses.

This works at runtime because Java generics are erased — a
`SimulationCorpus<Object, Object>` is indistinguishable from
`SimulationCorpus<String, Result>` at the bytecode level.

### YamlCorpusLoader

```java
public class YamlCorpusLoader {

    private final ObjectMapper yamlMapper;

    public YamlCorpusLoader() {
        this.yamlMapper = new ObjectMapper(new YAMLFactory());
    }

    public Map<String, List<InvocationRecord<Object, Object>>> load(InputStream input) {
        // Parse YAML → Map<String, List<Map<String, Object>>>
        // Convert each entry to InvocationRecord:
        //   key → entry.get("key")  (nullable)
        //   tenancy-id → entry.get("tenancy-id")
        //   input → entry.get("input")
        //   output → entry.get("output")
        //   recordedAt → Instant.now()
    }

    public Map<String, List<InvocationRecord<Object, Object>>> loadFromPaths(
            List<String> paths) {
        // Supports classpath: prefix and filesystem paths
        // Merges entries across files (later files append, not replace)
    }
}
```

### Configuration

```properties
casehub.simulation.corpus.files=classpath:simulation/test-corpus.yaml,classpath:simulation/demo-corpus.yaml
```

Multiple files supported. Later files append to the same qualified name
(not replace). This allows composing corpora from multiple sources.

### Startup populator

In `SimulationConfigBeans` (Quarkus module):

```java
@ApplicationScoped
public class SimulationConfigBeans {

    @Produces @ApplicationScoped
    SimulationConfig simulationConfig() {
        return new SmallRyeSimulationConfig(ConfigProvider.getConfig());
    }

    void onStartup(@Observes StartupEvent event,
                   SimulationConfig config,
                   SimulationCorpus<Object, Object> corpus,
                   SimulationRuntime runtime) {
        // 1. Load corpus files
        var files = ConfigProvider.getConfig()
            .getOptionalValue("casehub.simulation.corpus.files", String.class)
            .map(s -> List.of(s.split(",")))
            .orElse(List.of());
        if (!files.isEmpty()) {
            var loader = new YamlCorpusLoader();
            var loaded = loader.loadFromPaths(files);
            loaded.forEach((qn, records) -> corpus.seed(qn, records));
        }

        // 2. Register declarative extractors
        DeclarativeExtractorFactory factory = new DeclarativeExtractorFactory();
        // SmallRyeSimulationConfig exposes extractor specs
        ((SmallRyeSimulationConfig) config).extractorSpecs().forEach((qn, spec) ->
            runtime.registerExtractor(qn, factory.create(spec)));
    }
}
```

## Deliverable 3: Declarative KeyExtractors

### Extractor spec syntax

| Spec | Behaviour | Example |
|------|-----------|---------|
| `identity` | `input.toString()` | `key-extractor=identity` |
| `field:<path>` | Extract single field from input | `key-extractor=field:domain` |
| `composite:<f1>,<f2>,...` | Concatenate fields with `:` separator | `key-extractor=composite:department,severity` |

### Field access via Jackson ObjectMapper (D16)

All declarative extractors convert the input to `Map<String, Object>` via
`ObjectMapper.convertValue(input, Map.class)` before field access. This
handles both:
- **Map inputs** (from YAML corpus) — convertValue is a no-op
- **Typed inputs** (from real SPI calls) — Jackson serializes the record/POJO to a Map

### DeclarativeExtractorFactory

```java
public class DeclarativeExtractorFactory {

    private final ObjectMapper objectMapper;

    public DeclarativeExtractorFactory() {
        this.objectMapper = new ObjectMapper();
        objectMapper.registerModule(new JavaTimeModule());
    }

    public KeyExtractor<Object> create(String spec) {
        if ("identity".equals(spec)) {
            return input -> String.valueOf(input);
        }
        if (spec.startsWith("field:")) {
            String fieldName = spec.substring("field:".length());
            return input -> extractField(input, fieldName);
        }
        if (spec.startsWith("composite:")) {
            String[] fields = spec.substring("composite:".length()).split(",");
            return input -> extractComposite(input, fields);
        }
        throw new SimulationConfigException(
            "Unknown key-extractor spec: " + spec +
            ". Valid: identity, field:<name>, composite:<f1>,<f2>");
    }

    private String extractField(Object input, String fieldName) {
        Map<String, Object> map = toMap(input);
        Object value = map.get(fieldName);
        if (value == null) {
            throw new SimulationKeyNotFoundException(fieldName,
                "Field '" + fieldName + "' not found in input");
        }
        return String.valueOf(value);
    }

    private String extractComposite(Object input, String[] fields) {
        Map<String, Object> map = toMap(input);
        return Arrays.stream(fields)
            .map(f -> f + "=" + map.getOrDefault(f, "null"))
            .collect(Collectors.joining(":"));
    }

    @SuppressWarnings("unchecked")
    private Map<String, Object> toMap(Object input) {
        if (input instanceof Map) {
            return (Map<String, Object>) input;
        }
        return objectMapper.convertValue(input,
            new TypeReference<Map<String, Object>>() {});
    }
}
```

### Complex extractors stay programmatic

The declarative syntax covers the common cases. Normalizing extractors
(strip UUIDs, lowercase, trim), conditional extractors, and extractors
that need access to external state remain programmatic via
`runtime.registerExtractor()`. Programmatic extractors registered at
startup override declarative ones for the same qualified name.

## CDI wiring

### Priority and displacement

`SimulationConfigBeans` produces `SimulationConfig` as `@ApplicationScoped`.
This displaces the need for manual `SimulationConfig` implementations.

The beans class also produces `SimulationRuntime` (wrapping
`SmallRyeSimulationConfig` + injected `SimulationCorpus`). This is the
single construction point for the runtime — consumers inject
`SimulationRuntime`, not `SimulationConfig`.

### Activation

The module activates by classpath presence — add `simulation-config` as
a compile dependency. When absent, consumers must implement
`SimulationConfig` manually (the current state).

### Boot sequence

1. CDI constructs `SimulationConfigBeans`
2. `@Produces` creates `SmallRyeSimulationConfig` (scans config properties)
3. `@Produces` creates `SimulationRuntime` (config + corpus)
4. `@Observes StartupEvent`:
   a. Load YAML corpus files → `corpus.seed()`
   b. Register declarative extractors → `runtime.registerExtractor()`
5. Application is ready — decorators can resolve strategies

## Testing strategy

### Unit tests (simulation-config-core)

- `SmallRyeSimulationConfigTest` — parse known properties, handle missing
  properties, handle malformed keys, ignore reserved keys (corpus.files)
- `YamlCorpusLoaderTest` — load single file, multiple files, merge
  behaviour, classpath and filesystem, malformed YAML
- `DeclarativeExtractorFactoryTest` — identity, field, composite, unknown
  spec, null field, nested field (future)

### Integration tests (simulation-config)

- `SimulationConfigIT` — full Quarkus boot with `application.properties`
  config, verify strategy resolution via `SimulationRuntime`
- `YamlCorpusPopulatorIT` — boot with corpus files, verify seeded data
  resolves via strategies
- `DeclarativeExtractorIT` — config-driven extractors resolve correctly
  in live Quarkus context

## What this does NOT do

- **Type-aware corpus deserialization** — YAML values are Object-typed.
  Typed corpora use the programmatic API or corpus builders (#328).
- **Runtime config changes** — config is read at boot. Restart to change.
- **Nested field paths** — `field:address.city` is not supported in v1.
  Use programmatic extractors for nested access.
- **YAML-driven strategy registration** — strategies are selected by
  config key (`strategy=sequential`), not defined in YAML.

## References

- D13, D14, D15, D16 in `decisions.md`
- GE-20260519-b9719e — SmallRye Config Map throws NoSuchElementException
- GE-20260609-4c6577 — ghost entries with @WithParentName map
- GE-20260612-ed9ff0 — @ConfigProperty on @ConfigMapping-owned prefix
- config-core/ + config/ — precedent module pattern
- endpoints-config-core/ + endpoints-config/ — precedent module pattern
- casehubio/platform#328 — corpus builders (future)
- casehubio/platform#330 — domain data generation (future)
