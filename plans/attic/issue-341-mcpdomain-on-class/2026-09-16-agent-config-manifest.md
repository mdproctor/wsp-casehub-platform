# Agent Config Manifest Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** #335 — Standardised AgentProvider configuration manifest
**Issue group:** #335

**Goal:** Declarative YAML manifest that drives the existing LLM infrastructure at startup — configure once, AgentProvider works everywhere.

**Architecture:** ManifestLoader discovers config files from a directory hierarchy + remote URIs, ManifestProcessor drives existing SPIs (LlmCredentialStore, MutableModelRegistry, RoutingAgentProvider) from the merged result. Two new modules: `agent-config-core` (framework-neutral loader + processor) and `agent-config` (Quarkus @Startup wiring).

**Tech Stack:** Java 21, Jackson YAML, Quarkus CDI, platform-api SPIs

## Global Constraints

- `platform-api/` must remain zero-dependency — new fields added to ModelQuery are pure Java
- `agent-config-core` must be framework-neutral — no CDI, no Quarkus imports
- `agent-config-core` depends on `platform-api` only (for ModelQuery, LlmCredentialStore, CredentialResolver, MutableModelRegistry)
- `agent-config-core` must NOT depend on `llm-config` — vendor field requirements and local model reconciliation are injected by the Quarkus wiring layer
- Credential references in manifests are never raw values — only `env:`, `file:`, `ref:` prefixes
- All manifest sections are optional — a manifest with only `models:` is valid

---

## Batch 1: Foundation — ModelQuery extension + CredentialRef + Manifest types

After this batch: ModelQuery supports range constraints and preferVendor. The manifest data model and credential reference parsing exist with full test coverage. No runtime behavior yet.

### Task 1: Extend ModelQuery with range constraints and preferVendor

**Files:**
- Modify: `platform-api/src/main/java/io/casehub/platform/api/model/ModelQuery.java`
- Modify: `platform/src/main/java/io/casehub/platform/model/InMemoryModelRegistry.java`
- Test: `platform-api/src/test/java/io/casehub/platform/api/model/ModelQueryTest.java`
- Test: `platform/src/test/java/io/casehub/platform/model/InMemoryModelRegistryTest.java`

**Interfaces:**
- Produces: `ModelQuery(vendor, family, tier, requiredCapabilities, locality, maxCostTier, authMethod, minContextWindow, minMaxOutput, preferVendor)` — 3 new nullable fields. Builder extended with `minContextWindow(Integer)`, `minMaxOutput(Integer)`, `preferVendor(String)`.

- [ ] **Step 1: Write failing test for minContextWindow filter**

```java
@Test
void queryFiltersMinContextWindow() {
    var registry = new InMemoryModelRegistry();
    registry.replaceSource("test", 1, List.of(
        model("small", 32000, 4096),
        model("large", 200000, 32768)
    ));
    var query = ModelQuery.builder().minContextWindow(128000).build();
    var results = registry.query(query);
    assertEquals(1, results.size());
    assertEquals("large", results.get(0).id());
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mvn test -pl platform-api,platform -Dtest="ModelQueryTest#queryFiltersMinContextWindow,InMemoryModelRegistryTest#queryFiltersMinContextWindow" --batch-mode`
Expected: compilation failure — `minContextWindow` field doesn't exist

- [ ] **Step 3: Add three new fields to ModelQuery**

Add `Integer minContextWindow`, `Integer minMaxOutput`, `String preferVendor` to the record. Extend the Builder with corresponding methods. Update `all()` factory to pass null for new fields. Ensure compact constructor keeps `requiredCapabilities` defensive copy and new fields pass through as-is (nullable).

```java
public record ModelQuery(
    String vendor,
    String family,
    ModelTier tier,
    Set<String> requiredCapabilities,
    ModelLocality locality,
    CostTier maxCostTier,
    String authMethod,
    Integer minContextWindow,
    Integer minMaxOutput,
    String preferVendor
) {
    public ModelQuery {
        requiredCapabilities = requiredCapabilities != null
            ? Set.copyOf(requiredCapabilities) : Set.of();
    }

    public static ModelQuery all() {
        return new ModelQuery(null, null, null, Set.of(), null, null, null, null, null, null);
    }

    // Builder gains: minContextWindow(Integer), minMaxOutput(Integer), preferVendor(String)
}
```

- [ ] **Step 4: Add filter lines to InMemoryModelRegistry.query()**

After the existing `authMethod` filter:

```java
.filter(d -> query.minContextWindow() == null || d.contextWindow() >= query.minContextWindow())
.filter(d -> query.minMaxOutput() == null || d.maxOutput() >= query.minMaxOutput())
```

No filter for `preferVendor` — it's a tiebreaker, not a filter. The registry ignores it.

- [ ] **Step 5: Fix existing callers**

Existing `ModelQuery.builder().build()` calls are unaffected (new fields default to null in builder). The `RoutingAgentProvider.resolveTier()` call `ModelQuery.builder().tier(tier).build()` passes null for new fields — correct behavior.

- [ ] **Step 6: Run all tests**

Run: `mvn test -pl platform-api,platform --batch-mode`
Expected: all PASS including new filter tests

- [ ] **Step 7: Write tests for minMaxOutput and preferVendor-is-ignored-by-query**

```java
@Test
void queryFiltersMinMaxOutput() {
    // models with maxOutput 4096 and 32768 — query minMaxOutput=16384 returns only the larger
}

@Test
void queryIgnoresPreferVendor() {
    // two models from different vendors — query with preferVendor set returns both (not filtered)
}
```

- [ ] **Step 8: Run tests, verify pass**

Run: `mvn test -pl platform-api,platform --batch-mode`
Expected: all PASS

- [ ] **Step 9: Commit**

```bash
git add platform-api/ platform/
git commit -m "feat(#335): extend ModelQuery with minContextWindow, minMaxOutput, preferVendor"
```

### Task 2: Manifest data model + CredentialRef + ManifestCredentialResolver in agent-config-core

**Files:**
- Create: `agent-config-core/pom.xml`
- Create: `agent-config-core/src/main/java/io/casehub/platform/agent/config/Manifest.java`
- Create: `agent-config-core/src/main/java/io/casehub/platform/agent/config/ProviderDeclaration.java`
- Create: `agent-config-core/src/main/java/io/casehub/platform/agent/config/AliasDeclaration.java`
- Create: `agent-config-core/src/main/java/io/casehub/platform/agent/config/LocalModelDeclaration.java`
- Create: `agent-config-core/src/main/java/io/casehub/platform/agent/config/SourceDeclaration.java`
- Create: `agent-config-core/src/main/java/io/casehub/platform/agent/config/ManifestDefaults.java`
- Create: `agent-config-core/src/main/java/io/casehub/platform/agent/config/CredentialRef.java`
- Create: `agent-config-core/src/main/java/io/casehub/platform/agent/config/ManifestCredentialResolver.java`
- Create: `agent-config-core/src/main/java/io/casehub/platform/agent/config/ManifestResult.java`
- Create: `agent-config-core/src/main/java/io/casehub/platform/agent/config/LocalModelReconciler.java`
- Modify: `pom.xml` (add module)
- Test: `agent-config-core/src/test/java/io/casehub/platform/agent/config/CredentialRefTest.java`
- Test: `agent-config-core/src/test/java/io/casehub/platform/agent/config/ManifestCredentialResolverTest.java`

**Interfaces:**
- Produces: `Manifest` record, `CredentialRef` sealed interface (EnvRef, FileRef, ExternalRef), `ManifestCredentialResolver.resolve(CredentialRef) → String`, `ManifestResult(Map<String, ModelQuery> aliases, String defaultBackendKey)`, `LocalModelReconciler` functional interface
- Consumes: `CredentialResolver` from platform-api (injected, for `ref:` prefix delegation)

- [ ] **Step 1: Write failing test for CredentialRef parsing**

```java
@Test
void parsesEnvRef() {
    var ref = CredentialRef.parse("env:MY_KEY");
    assertInstanceOf(CredentialRef.EnvRef.class, ref);
    assertEquals("MY_KEY", ((CredentialRef.EnvRef) ref).variableName());
}

@Test
void parsesFileRef() {
    var ref = CredentialRef.parse("file:/tmp/key.txt");
    assertInstanceOf(CredentialRef.FileRef.class, ref);
    assertEquals("/tmp/key.txt", ((CredentialRef.FileRef) ref).path());
}

@Test
void parsesExternalRef() {
    var ref = CredentialRef.parse("ref:vault/my-secret");
    assertInstanceOf(CredentialRef.ExternalRef.class, ref);
    assertEquals("vault/my-secret", ((CredentialRef.ExternalRef) ref).credentialRef());
}

@Test
void rejectsRawValue() {
    assertThrows(IllegalArgumentException.class, () -> CredentialRef.parse("sk-ant-1234"));
}
```

- [ ] **Step 2: Run test — verify compilation fails (module doesn't exist yet)**

- [ ] **Step 3: Create agent-config-core module**

Create `agent-config-core/pom.xml` with dependencies: `casehub-platform-api` (compile), `jackson-dataformat-yaml` (compile), `junit-jupiter` (test). Package `io.casehub.platform.agent.config`. Add `<module>agent-config-core</module>` to parent pom (after `agent-router-core`, before `agent-router`).

- [ ] **Step 4: Implement CredentialRef sealed interface**

```java
public sealed interface CredentialRef {
    record EnvRef(String variableName) implements CredentialRef {}
    record FileRef(String path) implements CredentialRef {}
    record ExternalRef(String credentialRef) implements CredentialRef {}

    static CredentialRef parse(String value) {
        if (value.startsWith("env:")) return new EnvRef(value.substring(4));
        if (value.startsWith("file:")) return new FileRef(value.substring(5));
        if (value.startsWith("ref:")) return new ExternalRef(value.substring(4));
        throw new IllegalArgumentException(
            "Credential reference must start with env:, file:, or ref: — got: " + value);
    }
}
```

- [ ] **Step 5: Implement Manifest record and related types**

```java
public record Manifest(
    List<ModelDescriptor> models,
    List<ProviderDeclaration> providers,
    List<SourceDeclaration> sources,
    Map<String, AliasDeclaration> aliases,
    List<LocalModelDeclaration> localModels,
    ManifestDefaults defaults
) {
    public Manifest {
        models = models != null ? List.copyOf(models) : List.of();
        providers = providers != null ? List.copyOf(providers) : List.of();
        sources = sources != null ? List.copyOf(sources) : List.of();
        aliases = aliases != null ? Map.copyOf(aliases) : Map.of();
        localModels = localModels != null ? List.copyOf(localModels) : List.of();
    }
}

public record ProviderDeclaration(String vendor, Object credential, String host) {}
public record AliasDeclaration(String tier, List<String> capabilities, String locality,
    String maxCost, Integer minContext, Integer minOutput, String preferVendor) {}
public record LocalModelDeclaration(String id, String ensure) {}
public record SourceDeclaration(String uri, int priority) {}
public record ManifestDefaults(String backend) {}
public record ManifestResult(Map<String, ModelQuery> aliases, String defaultBackendKey) {}

@FunctionalInterface
public interface LocalModelReconciler {
    void ensurePresent(String modelId);
}
```

- [ ] **Step 6: Implement ManifestCredentialResolver**

```java
public class ManifestCredentialResolver {
    private final CredentialResolver externalResolver;

    public ManifestCredentialResolver(CredentialResolver externalResolver) {
        this.externalResolver = externalResolver;
    }

    public String resolve(CredentialRef ref) {
        return switch (ref) {
            case CredentialRef.EnvRef env -> {
                String value = System.getenv(env.variableName());
                if (value == null) throw new IllegalStateException(
                    "Environment variable not set: " + env.variableName());
                yield value;
            }
            case CredentialRef.FileRef file -> {
                try { yield java.nio.file.Files.readString(java.nio.file.Path.of(file.path())).trim(); }
                catch (java.io.IOException e) { throw new IllegalStateException(
                    "Cannot read credential file: " + file.path(), e); }
            }
            case CredentialRef.ExternalRef ext -> {
                var creds = externalResolver.resolve(ext.credentialRef());
                if (creds.isEmpty()) throw new IllegalStateException(
                    "Credential ref not found: " + ext.credentialRef());
                yield creds.values().iterator().next();
            }
        };
    }
}
```

- [ ] **Step 7: Write ManifestCredentialResolver tests**

Test env: resolution (set env var in test), file resolution (temp file), external delegation (mock CredentialResolver). Test failure cases: missing env var, missing file, empty external ref.

- [ ] **Step 8: Run all tests**

Run: `mvn test -pl agent-config-core --batch-mode`
Expected: all PASS

- [ ] **Step 9: Commit**

```bash
git add agent-config-core/ pom.xml
git commit -m "feat(#335): add agent-config-core — manifest types, CredentialRef, ManifestCredentialResolver"
```

---

## Batch 2: Loader + Processor — manifest files become a running AgentProvider

After this batch: ManifestLoader discovers and parses YAML files from the directory hierarchy. ManifestProcessor drives existing SPIs. End-to-end tests prove the pipeline works.

### Task 3: ManifestLoader — YAML parsing, file discovery, merging

**Files:**
- Create: `agent-config-core/src/main/java/io/casehub/platform/agent/config/ManifestLoader.java`
- Test: `agent-config-core/src/test/java/io/casehub/platform/agent/config/ManifestLoaderTest.java`
- Test fixture: `agent-config-core/src/test/resources/manifests/base.yaml`
- Test fixture: `agent-config-core/src/test/resources/manifests/override.yaml`

**Interfaces:**
- Consumes: `Manifest` record (from Task 2)
- Produces: `ManifestLoader.load(List<Path> searchPaths, String profile) → Manifest` (merged result)

- [ ] **Step 1: Write failing test for single-file parsing**

```java
@Test
void loadsSingleManifest() {
    var loader = new ManifestLoader();
    var manifest = loader.loadResource(
        getClass().getClassLoader().getResource("manifests/base.yaml").toURI());
    assertEquals(1, manifest.providers().size());
    assertEquals("anthropic", manifest.providers().get(0).vendor());
}
```

Create `base.yaml`:
```yaml
providers:
  - vendor: anthropic
    credential: env:ANTHROPIC_API_KEY
defaults:
  backend: claude
```

- [ ] **Step 2: Run test — fails (ManifestLoader doesn't exist)**

- [ ] **Step 3: Implement ManifestLoader — single-resource parsing**

Jackson ObjectMapper with YAMLFactory. Deserialize into `Manifest` record. Handle missing sections (all fields nullable with defaults in compact constructor).

- [ ] **Step 4: Run test — passes**

- [ ] **Step 5: Write test for directory hierarchy discovery**

```java
@Test
void discoversFilesInPriorityOrder() {
    // Create temp dir structure: project/agent-config.yaml (priority 30)
    // + user dir with agent-config.yaml (priority 20)
    // Verify loader finds both, project has higher priority
}
```

- [ ] **Step 6: Implement discovery — walk fixed hierarchy**

Check each path in the implicit chain. For each: if file exists, parse it. Collect with priorities. Return merged result using accumulation rules (model by ID, provider by vendor, alias by name — higher priority wins).

- [ ] **Step 7: Write test for profile-specific file loading**

```java
@Test
void loadsProfileSpecificFile() {
    // agent-config.yaml + agent-config-ci.yaml
    // With profile "ci": both loaded, ci overrides base
    // Without profile: only base loaded
}
```

- [ ] **Step 8: Implement profile file discovery**

After loading base file at each level, check for `agent-config-{profile}.yaml` at priority + 5.

- [ ] **Step 9: Write test for accumulation — models by ID**

```java
@Test
void higherPriorityModelOverridesLower() {
    // base has model "claude-opus-5" with tier FLAGSHIP
    // override has model "claude-opus-5" with tier STANDARD
    // merged result has STANDARD (higher priority wins)
}
```

- [ ] **Step 10: Implement merge logic**

Merge two Manifest records: models by ID (later wins), providers by vendor (later wins), aliases by name (later wins), defaults last writer wins, sources union, local-models union.

- [ ] **Step 11: Write test for remote source loading with cycle detection**

```java
@Test
void detectsCycleInSourceChain() {
    // manifest A declares source B, source B declares source A
    // Loader warns and stops recursion, no infinite loop
}
```

- [ ] **Step 12: Implement remote source loading with guards**

Follow `sources:` URIs recursively. Guards: URI set for cycle detection, max depth 3, max 20 total sources. HTTP fetch with 10s timeout. Log warnings on failure — degrade, don't crash.

- [ ] **Step 13: Run all tests**

Run: `mvn test -pl agent-config-core --batch-mode`
Expected: all PASS

- [ ] **Step 14: Commit**

```bash
git add agent-config-core/
git commit -m "feat(#335): ManifestLoader — YAML parsing, directory hierarchy discovery, merging, remote sources"
```

### Task 4: ManifestProcessor — drives existing SPIs from merged manifest

**Files:**
- Create: `agent-config-core/src/main/java/io/casehub/platform/agent/config/ManifestProcessor.java`
- Test: `agent-config-core/src/test/java/io/casehub/platform/agent/config/ManifestProcessorTest.java`

**Interfaces:**
- Consumes: `Manifest` (from Task 2/3), `ManifestCredentialResolver` (from Task 2), `LlmCredentialStore` (platform-api), `MutableModelRegistry` (platform-api), `LocalModelReconciler` (from Task 2)
- Produces: `ManifestResult` (aliases + defaultBackendKey)

- [ ] **Step 1: Write failing test for credential storage**

```java
@Test
void storesResolvedCredentials() {
    var credStore = new InMemoryLlmCredentialStore();
    var manifest = manifestWithProvider("anthropic", "env:TEST_KEY");
    // Set env var TEST_KEY=sk-test-123

    var processor = new ManifestProcessor(credStore, registry, resolver,
        vendorRequirements, reconciler);
    var result = processor.process(manifest);

    var stored = credStore.resolve("platform", "cloud-anthropic");
    assertEquals("sk-test-123", stored.get("api-key"));
}
```

- [ ] **Step 2: Run test — fails**

- [ ] **Step 3: Implement ManifestProcessor.process()**

Constructor takes: `LlmCredentialStore`, `MutableModelRegistry`, `ManifestCredentialResolver`, `Map<String, List<String>> vendorRequiredFields`, `LocalModelReconciler`. The `process(Manifest)` method runs steps 1-4 from the spec:

1. **Providers → Credentials:** Resolve refs, validate required fields, store as `"cloud-{vendor}"`
2. **Models → Registry:** Register via `replaceSource("manifest", 8, models)`. Default `apiModelId` to `id` if null.
3. **Local models → Reconciliation:** Call `reconciler.ensurePresent(id)` for each
4. **Aliases + Defaults → ManifestResult:** Convert `AliasDeclaration` → `ModelQuery`, determine default backend

Returns `ManifestResult`.

- [ ] **Step 4: Run test — passes**

- [ ] **Step 5: Write test for model registration with priority 8**

```java
@Test
void registersModelsAtPriority8() {
    var registry = new InMemoryModelRegistry();
    registry.replaceSource("seed-catalog", 0, List.of(seedModel("claude-opus-5", "FLAGSHIP")));

    var manifest = manifestWithModel("claude-opus-5", "STANDARD"); // override tier
    processor.process(manifest);

    // Manifest (priority 8) beats seed catalog (priority 0)
    assertEquals(ModelTier.STANDARD, registry.resolveById("claude-opus-5").get().tier());
}
```

- [ ] **Step 6: Write test for alias → ModelQuery conversion**

```java
@Test
void convertsAliasToModelQuery() {
    var manifest = manifestWithAlias("reasoning-heavy",
        new AliasDeclaration("FLAGSHIP", List.of("reasoning"), null, null, 128000, null, "anthropic"));
    var result = processor.process(manifest);

    var query = result.aliases().get("reasoning-heavy");
    assertEquals(ModelTier.FLAGSHIP, query.tier());
    assertEquals(Set.of("reasoning"), query.requiredCapabilities());
    assertEquals(128000, query.minContextWindow());
    assertEquals("anthropic", query.preferVendor());
}
```

- [ ] **Step 7: Write test for local model reconciliation**

```java
@Test
void callsReconcilerForLocalModels() {
    var reconciled = new ArrayList<String>();
    var reconciler = (LocalModelReconciler) reconciled::add;

    var manifest = manifestWithLocalModel("llama-4-scout", "present");
    processor.process(manifest);

    assertEquals(List.of("llama-4-scout"), reconciled);
}
```

- [ ] **Step 8: Run all tests**

Run: `mvn test -pl agent-config-core --batch-mode`
Expected: all PASS

- [ ] **Step 9: Commit**

```bash
git add agent-config-core/
git commit -m "feat(#335): ManifestProcessor — credential storage, model registration, alias conversion, local model reconciliation"
```

### Task 5: Router extension — alias lookup + preferVendor tiebreaking

**Files:**
- Modify: `agent-router-core/src/main/java/io/casehub/platform/agent/router/RoutingAgentProvider.java`
- Modify: `agent-router/src/main/java/io/casehub/platform/agent/router/quarkus/RouterBeans.java`
- Modify: `agent-api/src/main/java/io/casehub/platform/agent/AgentSessionConfig.java`
- Test: `agent-router-core/src/test/java/io/casehub/platform/agent/router/RoutingAgentProviderTest.java`

**Interfaces:**
- Consumes: `ManifestResult` (from Task 4), `ModelQuery` (from Task 1)
- Produces: Extended `RoutingAgentProvider(registry, defaultBackendKey, modelRegistry, aliases)`, `AgentSessionConfig.withModel(String)`

- [ ] **Step 1: Write failing test for alias resolution**

```java
@Test
void resolvesAlias() {
    var aliases = Map.of("reasoning-heavy",
        ModelQuery.builder().tier(ModelTier.FLAGSHIP)
            .requiredCapabilities(Set.of("reasoning")).build());

    var provider = new RoutingAgentProvider(registry, "claude", modelRegistry, aliases);

    // Register a FLAGSHIP model with reasoning capability
    modelRegistry.replaceSource("test", 1, List.of(flagshipModel));

    var route = provider.resolve("reasoning-heavy");
    // verify it resolves to the flagship model
}
```

- [ ] **Step 2: Run test — fails (4-arg constructor doesn't exist)**

- [ ] **Step 3: Add 4-arg constructor and alias resolution to RoutingAgentProvider**

```java
private final Map<String, ModelQuery> aliases;

public RoutingAgentProvider(BackendInstanceRegistry registry,
                            String defaultBackendKey,
                            ModelRegistry modelRegistry,
                            Map<String, ModelQuery> aliases) {
    this.registry = registry;
    this.defaultBackendKey = defaultBackendKey;
    this.modelRegistry = modelRegistry;
    this.aliases = aliases != null ? Map.copyOf(aliases) : Map.of();
}
```

Update existing 3-arg constructor to call 4-arg with empty map.

In `resolve(String model)`:
```java
// Step 0: Alias?
if (aliases.containsKey(model)) {
    return resolveQuery(aliases.get(model));
}
```

Add `resolveQuery(ModelQuery)` that filters via `modelRegistry.query()`, then tiebreaks: (1) prefer default backend, (2) prefer `query.preferVendor()`, (3) first match.

- [ ] **Step 4: Add withModel() to AgentSessionConfig**

```java
public AgentSessionConfig withModel(String model) {
    return new AgentSessionConfig(systemPrompt, userPrompt, mcpServers, timeout, correlationId, model);
}
```

- [ ] **Step 5: Update RouterBeans to accept optional ManifestResult**

```java
@Produces @ApplicationScoped
public RoutingAgentProvider routingAgentProvider(
        RoutingAgentConfig config,
        Instance<ManifestResult> manifestResult) {
    if (manifestResult.isResolvable()) {
        var result = manifestResult.get();
        return new RoutingAgentProvider(registry,
            result.defaultBackendKey() != null ? result.defaultBackendKey() : config.defaultBackend(),
            modelRegistry, result.aliases());
    }
    return new RoutingAgentProvider(registry, config.defaultBackend(), modelRegistry);
}
```

- [ ] **Step 6: Write test for preferVendor tiebreaking**

```java
@Test
void preferVendorTiebreaksAmongMatches() {
    // Two FLAGSHIP models: one anthropic, one openai
    // Query with preferVendor="openai"
    // Verify openai model is selected even though default backend is claude
}
```

- [ ] **Step 7: Write test for alias miss falls through to tier/ID/key**

```java
@Test
void unknownAliasDoesNotMatchFallsToTierRef() {
    var provider = new RoutingAgentProvider(registry, "claude", modelRegistry, Map.of());
    // "tier:FAST" should still work even with aliases enabled
}
```

- [ ] **Step 8: Run all tests**

Run: `mvn test -pl agent-api,agent-router-core,agent-router --batch-mode`
Expected: all PASS

- [ ] **Step 9: Commit**

```bash
git add agent-api/ agent-router-core/ agent-router/
git commit -m "feat(#335): router alias resolution + preferVendor tiebreaking + AgentSessionConfig.withModel()"
```

---

## Batch 3: Quarkus wiring + integration — manifest drives a running app

After this batch: Drop an `agent-config.yaml` in a Quarkus app, and AgentProvider works at startup. Full end-to-end integration test proves the pipeline.

### Task 6: agent-config module — Quarkus @Startup wiring

**Files:**
- Create: `agent-config/pom.xml`
- Create: `agent-config/src/main/java/io/casehub/platform/agent/config/quarkus/AgentConfigBeans.java`
- Modify: `pom.xml` (add module after agent-config-core)
- Test: `agent-config/src/test/java/io/casehub/platform/agent/config/quarkus/AgentConfigBeansTest.java`
- Test fixture: `agent-config/src/test/resources/agent-config.yaml`

**Interfaces:**
- Consumes: `ManifestLoader` (Task 3), `ManifestProcessor` (Task 4), `VendorClient` beans from llm-config, `OllamaModelSource` from llm-config, `LlmConfigService` from llm-config
- Produces: `ManifestResult` as CDI bean

- [ ] **Step 1: Write failing integration test**

```java
@QuarkusTest
class AgentConfigBeansTest {
    @Inject ManifestResult manifestResult;

    @Test
    void manifestResultProducedAtStartup() {
        assertNotNull(manifestResult);
        assertEquals("claude", manifestResult.defaultBackendKey());
    }
}
```

With `src/test/resources/agent-config.yaml`:
```yaml
defaults:
  backend: claude
aliases:
  fast:
    tier: FAST
```

- [ ] **Step 2: Create agent-config module**

`pom.xml` depends on: `agent-config-core` (compile), `llm-config` (compile — for VendorClient, OllamaModelSource, LlmConfigService), `platform` (compile — for InMemoryModelRegistry, InMemoryLlmCredentialStore), Quarkus CDI.

- [ ] **Step 3: Implement AgentConfigBeans**

```java
@ApplicationScoped
public class AgentConfigBeans {

    @Inject LlmCredentialStore credentialStore;
    @Inject MutableModelRegistry modelRegistry;
    @Inject CredentialResolver credentialResolver;
    @Inject @Any Instance<VendorClient> vendorClients;
    @Inject @Any Instance<OllamaModelSource> ollamaSource;
    @Inject @Any Instance<LlmConfigApi> configApi;

    private ManifestResult result;

    void onStartup(@Observes @Priority(50) StartupEvent event) {
        var vendorReqs = buildVendorRequirements();
        var reconciler = buildReconciler();
        var resolver = new ManifestCredentialResolver(credentialResolver);
        var loader = new ManifestLoader();
        var profile = resolveProfile();

        var manifest = loader.load(discoverSearchPaths(), profile);
        var processor = new ManifestProcessor(
            credentialStore, modelRegistry, resolver, vendorReqs, reconciler);
        this.result = processor.process(manifest);
    }

    @Produces @ApplicationScoped
    public ManifestResult manifestResult() {
        return result != null ? result : new ManifestResult(Map.of(), null);
    }

    private String resolveProfile() {
        String profile = System.getenv("CASEHUB_AGENT_PROFILE");
        if (profile == null) profile = System.getenv("QUARKUS_PROFILE");
        return profile;
    }
}
```

- [ ] **Step 4: Run integration test**

Run: `mvn test -pl agent-config --batch-mode`
Expected: PASS

- [ ] **Step 5: Write integration test for credential resolution from env var**

Set env var in test, verify credentials stored in LlmCredentialStore after startup.

- [ ] **Step 6: Run all tests**

Run: `mvn test -pl agent-config-core,agent-config --batch-mode`
Expected: all PASS

- [ ] **Step 7: Commit**

```bash
git add agent-config/ pom.xml
git commit -m "feat(#335): agent-config Quarkus module — @Startup manifest loading + ManifestResult producer"
```

### Task 7: JSON Schema + CLAUDE.md + documentation

**Files:**
- Create: `agent-config-core/src/main/resources/schema/model-selection.schema.json`
- Modify: `CLAUDE.md` — add agent-config-core and agent-config module descriptions
- Modify: `docs/guides/consumer-guide.md` — add agent configuration section

**Interfaces:**
- Produces: Published schema resource for cross-repo `$ref`

- [ ] **Step 1: Write model-selection.schema.json**

The full JSON Schema from the spec — string | ModelConstraints union type with all enum values.

- [ ] **Step 2: Add module descriptions to CLAUDE.md**

Add `agent-config-core` and `agent-config` to the Modules table following existing patterns.

- [ ] **Step 3: Add configuration section to consumer guide**

Explain: drop agent-config.yaml in project, set env vars, AgentProvider works. Show the three example configurations (developer, CI, production).

- [ ] **Step 4: Commit**

```bash
git add agent-config-core/src/main/resources/ CLAUDE.md docs/
git commit -m "docs(#335): JSON Schema, CLAUDE.md module entries, consumer guide agent config section"
```

---

## References

- [2026-09-16-agent-config-manifest-design.md] — design spec this plan implements
- `platform-api/src/main/java/io/casehub/platform/api/model/ModelQuery.java` — extended with 3 new fields
- `platform/src/main/java/io/casehub/platform/model/InMemoryModelRegistry.java:84-97` — query() filter chain
- `agent-router-core/src/main/java/io/casehub/platform/agent/router/RoutingAgentProvider.java` — resolve() extended with alias step
- `agent-router/src/main/java/io/casehub/platform/agent/router/quarkus/RouterBeans.java` — consumes ManifestResult
- `agent-api/src/main/java/io/casehub/platform/agent/AgentSessionConfig.java` — withModel() added
- `llm-config/src/main/java/io/casehub/platform/llm/config/LlmConfigService.java` — imperative API (unchanged, used by AgentConfigBeans)
- `platform-api/src/main/java/io/casehub/platform/api/credentials/CredentialResolver.java` — delegated by ManifestCredentialResolver
- `platform/src/main/resources/models/seed-catalog.yaml` — seed catalog loaded by ManifestLoader as classpath resource
- GitHub #335 — focal issue
