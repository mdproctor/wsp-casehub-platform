# Inline Corpus in Unified YAML — Design Spec

**Issue:** casehubio/platform#361
**Branch:** issue-352-simulation-dx
**Date:** 2026-09-19

---

## Problem

Simulation configuration is split across two mechanisms:
1. **MicroProfile Config properties** for per-method settings (`casehub.simulation.spi.method.strategy=key`)
2. **Standalone corpus YAML files** for test fixture data, referenced via `casehub.simulation.corpus.files`

Small scenarios that need 2-3 corpus entries must create a separate fixture
file, declare the file path in `application.properties`, and declare the
strategy in a separate property. This ceremony is disproportionate for the
common case.

## Scope

**In scope:**
- `YamlSimulationConfig` — new unified YAML parser in simulation-config-core
- Unified `simulation.yaml` file format with per-method strategy + inline corpus
- Full parity: strategy, capture, exhaustion-policy, key-extractor, scorer, threshold
- Profile support (nested in same file)
- External corpus file references per qualified name (`corpus-files:`)
- Convention-based discovery (`simulation.yaml` on classpath root)
- JSON Schema for IDE validation
- Retirement of `SmallRyeSimulationConfig` and `YamlCorpusLoader`
- Migration of existing tests, examples, and documentation

**Out of scope:**
- Typed corpus deserialization (remains Object-typed, as per D14 in the original YAML config spec)
- Runtime config reloading (read at boot only)
- Composition with `Simulation.forTest()` (D16 — standalone, no YAML merging)
- Pages scenario YAML integration (separate repo, casehub-pages)

## Design

### 1. YAML schema

```yaml
# simulation.yaml
default-tenancy-id: test-tenant    # optional — fallback for corpus entries without tenancy-id

methods:
  case-memory-store.query:
    strategy: key                  # required when corpus entries exist
    key-extractor: "field:domain"  # optional — declarative extractor spec
    capture: false                 # optional — default false
    exhaustion-policy: WRAP        # optional — WRAP or THROW
    scorer: "field:domain,question"  # optional — nearest-match scorer spec
    threshold: 0.8                 # optional — nearest-match threshold
    corpus:                        # optional — inline entries
      - key: cardiology
        tenancy-id: hospital-a     # optional — falls back to default-tenancy-id
        input:
          domain: cardiology
          question: "latest labs"
        output: "Lab results for cardiology"
      - key: neurology
        input:
          domain: neurology
        output: "MRI results"
    corpus-files:                  # optional — external file refs
      - classpath:simulation/extra-corpus.yaml

  agent-provider.invoke:
    strategy: sequential
    corpus:
      - input:
          system-prompt: "You are helpful"
          user-prompt: "Hello"
        output:
          - type: TextDelta
            text: "Hello! How can I help?"

profiles:
  demo:
    methods:
      case-memory-store.query:
        strategy: sequential       # overrides base strategy
        corpus-files:
          - classpath:simulation/demo-corpus.yaml
    corpus-files:                  # profile-level corpus files (all methods)
      - classpath:simulation/demo-extra.yaml

  ci-replay:
    methods:
      agent-provider.invoke:
        strategy: recorded-replay
```

**Top-level keys:**
- `default-tenancy-id` — optional, applies to all corpus entries missing `tenancy-id`
- `methods` — per-qualified-name method config (strategy + settings + corpus)
- `profiles` — named override sets, each containing `methods` and optional `corpus-files`

**Per-method keys:**
- `strategy` — strategy name (key-lookup, sequential, random, recorded-replay, nearest-match, or aliases)
- `key-extractor` — declarative spec (identity, field:\<path\>, composite:\<f1\>,\<f2\>)
- `capture` — boolean, default false
- `exhaustion-policy` — WRAP or THROW
- `scorer` — nearest-match scorer spec
- `threshold` — nearest-match threshold (0.0–1.0)
- `corpus` — list of inline entries (each: key, tenancy-id, input, output)
- `corpus-files` — list of paths to external corpus YAML files

**Corpus entry fields:**
- `key` — optional, used for key-lookup matching
- `tenancy-id` — optional, falls back to top-level `default-tenancy-id`
- `input` — any YAML value (string, map, list, number, boolean)
- `output` — any YAML value

External corpus files retain the current format (qualified-name → list of entries)
for backward compatibility with the `corpus-files` reference mechanism.

### 2. YamlSimulationConfig

New class in `simulation-config-core` (`io.casehub.platform.simulation.config`).

**Responsibilities:**
- Parse `simulation.yaml` via Jackson (ObjectMapper + YAMLFactory)
- Implement `SimulationConfig` (strategyFor, captureEnabled, exhaustionPolicy, threshold)
- Implement `ProfileSource` (resolve named profiles)
- Expose `extractorSpecs()`, `scorerSpecs()`, `defaultTenancyId()`, `profileNames()`
- Load and merge corpus: inline entries + external corpus-files per method
- Profile layering: profile methods override base methods (same as SmallRyeSimulationConfig)

**Constructor:**

```java
public class YamlSimulationConfig implements SimulationConfig, ProfileSource {

    private final String defaultTenancyId;
    private final Map<String, MethodConfig> methods;
    private final Map<String, ProfileConfig> profiles;

    public YamlSimulationConfig(InputStream yamlInput) {
        // Jackson parse → populate fields
    }

    // SimulationConfig methods — delegate to methods map with profile overlay
    // ProfileSource.resolve() — compose profile config + corpus
    // Corpus accessors — return merged inline + external entries
}
```

**Internal types:**

```java
// Per-method parsed config (replaces MethodSimulationConfig)
record MethodConfig(
    String strategy,
    boolean capture,
    ExhaustionPolicy exhaustionPolicy,
    String keyExtractor,
    String scorer,
    Double threshold,
    List<CorpusEntry> corpus,
    List<String> corpusFiles
) {}

record CorpusEntry(
    String key,
    String tenancyId,
    Object input,
    Object output
) {}

record ProfileConfig(
    Map<String, MethodConfig> methods,
    List<String> corpusFiles
) {}
```

**Corpus loading:**

`loadCorpus(String qualifiedName)` returns `List<InvocationRecord<Object, Object>>`:
1. Convert inline `corpus` entries to InvocationRecords (tenancyId fallback to defaultTenancyId)
2. If `corpus-files` present, load each file (classpath: or filesystem), parse as the
   existing corpus format (qualified-name → entries), extract entries for this qualified name
3. Append file entries after inline entries (inline first, files second)

The corpus file loading logic is absorbed from `YamlCorpusLoader` — same
InputStream parsing, same classpath/filesystem resolution, same merge semantics.

### 3. Discovery

Convention-based classpath discovery in `SimulationConfigBeans`:

1. Check MicroProfile Config for `casehub.simulation.config` override
2. If absent, try `simulation.yaml` then `simulation.yml` on classpath root
3. If found, parse via `YamlSimulationConfig`
4. If not found, no-op (simulation is not configured)

Environment-level knobs remain as MicroProfile Config properties:
- `casehub.simulation.active-profile` — selects active profile (supports `%test.` Quarkus qualifier)
- `casehub.simulation.config` — overrides convention path
- `casehub.simulation.default-tenancy-id` — can override YAML-level default (MicroProfile wins)

### 4. SimulationConfigBeans migration

```java
@ApplicationScoped
public class SimulationConfigBeans {

    @Produces @ApplicationScoped
    SimulationConfig simulationConfig() {
        // 1. Discover simulation.yaml (convention or config override)
        // 2. Parse via YamlSimulationConfig
        // 3. Read active-profile from MicroProfile Config
        // 4. Return YamlSimulationConfig (implements SimulationConfig + ProfileSource)
    }

    void onStartup(@Observes StartupEvent event,
                   SimulationConfig config,
                   SimulationCorpus<Object, Object> corpus,
                   SimulationRuntime runtime) {
        var yamlConfig = (YamlSimulationConfig) config;

        // 1. Seed corpus from YAML (inline + corpus-files)
        yamlConfig.loadAllCorpus().forEach(corpus::seed);

        // 2. Register declarative extractors
        DeclarativeExtractorFactory factory = new DeclarativeExtractorFactory();
        yamlConfig.extractorSpecs().forEach((qn, spec) ->
            runtime.registerExtractor(qn, factory.create(spec)));

        // 3. Register declarative scorers
        DeclarativeScorerFactory scorerFactory = new DeclarativeScorerFactory();
        yamlConfig.scorerSpecs().forEach((qn, spec) ->
            runtime.registerScorer(qn, scorerFactory.create(spec)));
    }
}
```

### 5. JSON Schema

Publish `simulation.schema.json` as a classpath resource in simulation-config-core.
Schema covers:
- Top-level structure (default-tenancy-id, methods, profiles)
- Per-method config (all 6 settings + corpus + corpus-files)
- Corpus entry structure (key, tenancy-id, input, output)
- Profile structure (methods + corpus-files)
- Strategy enum values (key-lookup, sequential, random, recorded-replay, nearest-match + aliases)
- Exhaustion policy enum (WRAP, THROW)

A test validates that the schema accepts the test fixture `simulation.yaml`
and rejects malformed variants.

### 6. Retirement

**Delete:**
- `SmallRyeSimulationConfig.java` — replaced by `YamlSimulationConfig`
- `YamlCorpusLoader.java` — corpus loading absorbed into `YamlSimulationConfig`
- `MethodSimulationConfig.java` — replaced by `MethodConfig` record
- `SmallRyeSimulationConfigTest.java` — replaced by `YamlSimulationConfigTest`
- `YamlCorpusLoaderTest.java` — replaced by corpus loading tests in `YamlSimulationConfigTest`

**Migrate:**
- Test corpus YAML files (`test-corpus.yaml`, `extra-corpus.yaml`, `no-tenant-corpus.yaml`)
  become either inline entries in test `simulation.yaml` files or remain as external
  files referenced via `corpus-files:`
- `SimulationConfigBeans.java` — update to use `YamlSimulationConfig`
- `docs/guides/consumer-guide.md` — update simulation config section
- `docs/guides/contributor-guide.md` — update simulation internals section
- `docs/examples/simulation/` — update example YAML files to unified format

### 7. Module placement

All changes are in `simulation-config-core` (POJO parser, records, schema)
and `simulation-config` (CDI wiring in `SimulationConfigBeans`). No new
modules. No dependency changes — Jackson YAML is already a dependency.

## Testing plan

### Unit tests (simulation-config-core)

- `YamlSimulationConfigTest`:
  - Parse minimal config (one method, strategy only)
  - Parse full config (all 6 per-method settings)
  - Inline corpus entries → InvocationRecords
  - Inline corpus with defaultTenancyId fallback
  - Inline corpus with per-entry tenancyId override
  - External corpus-files loading and merge with inline
  - Profile methods override base methods
  - Profile corpus-files load correctly
  - `strategyFor()` with active profile layering
  - `captureEnabled()`, `exhaustionPolicy()`, `threshold()` delegation
  - `extractorSpecs()` and `scorerSpecs()` extraction
  - `resolve()` returns composed SimulationProfile
  - Missing file → clear error message
  - Malformed YAML → clear error message
  - Empty methods block → no-op
  - No simulation.yaml → no-op (null-safe construction)

### Integration tests (simulation-config)

- `YamlSimulationConfigIT`:
  - Quarkus boot with `simulation.yaml` on classpath
  - Strategy resolution via injected `SimulationRuntime`
  - Corpus seeded and resolvable
  - Active profile selection via `%test.casehub.simulation.active-profile`
  - Convention discovery (no explicit config property)
  - Config override via `casehub.simulation.config` property

### Schema tests

- `SimulationSchemaTest`:
  - Schema validates test `simulation.yaml`
  - Schema rejects unknown top-level keys
  - Schema rejects invalid strategy values
  - Schema rejects corpus entry without input/output

## References

- D7-D16 in decisions.md
- SmallRyeSimulationConfig.java — current flat-property parser (retiring)
- YamlCorpusLoader.java — current corpus loader (retiring)
- MethodSimulationConfig.java — current per-method config (retiring)
- SimulationConfigBeans.java — CDI wiring (migrating)
- 2026-09-15-yaml-driven-simulation-config-design.md — original YAML config spec
- 2026-09-18-strategy-profiles-design.md — profile/ProfileSource design
- endpoints-config/ — additive pattern precedent
- casehubio/platform#361 — issue
- casehubio/platform#352 — parent epic
