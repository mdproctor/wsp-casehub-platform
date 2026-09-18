# Design: Domain-Specific Corpus Builders (#328)

## Problem

Seeding simulation corpora today is painful:

```java
corpus.seed("access-control-provider.canAccess", List.of(
    new InvocationRecord<>("hospital-a", "admin:case:c-1:WRITE",
        new Object[]{"admin", new ResourceId("case", "c-1"), AclAction.WRITE},
        true, Instant.now())));
runtime.registerExtractor("access-control-provider.canAccess",
    (Object[] p) -> p[0] + ":" + p[1] + ":" + p[2]);
```

Four pain sources: (1) InvocationRecord's 5-arg constructor when you need 2, (2) multi-param methods pack to `Object[]` with no type safety, (3) qualified name magic strings, (4) extractor registration disconnected from corpus seeding.

## Architecture

Composition over inheritance (D55). The issue proposed `abstract CorpusBuilder<I,O>` with per-SPI subclasses. First-principles analysis showed inheritance adds no value: the base class behavior is identical for every SPI, per-SPI variation is all static, and `Object[]` inputs can't be made type-safe through inheritance. Instead:

### Four layers

```
simulation-api       InvocationRecord.of() factories
simulation-api       CorpusSeed<I, O>  — final, concrete accumulator
simulation-testing   Per-SPI descriptors — static utility classes
simulation-testing   LlmCorpusPopulator — LLM-based generation
```

### Layer 1: InvocationRecord.of() (simulation-api)

```java
public record InvocationRecord<I, O>(
        String tenancyId, String key, I input, O output, Instant recordedAt) {

    public static <I, O> InvocationRecord<I, O> of(String tenancyId, I input, O output) {
        return new InvocationRecord<>(tenancyId, null, input, output, Instant.now());
    }

    public static <I, O> InvocationRecord<I, O> of(
            String tenancyId, String key, I input, O output) {
        return new InvocationRecord<>(tenancyId, key, input, output, Instant.now());
    }
}
```

### Layer 2: CorpusSeed<I, O> (simulation-api)

Final concrete class. Lives in simulation-api because its only dependencies are SimulationCorpus, InvocationRecord, and KeyExtractor — all in simulation-api. No SimulationRuntime dependency (D57 revision: seedInto is data-only, extractor registration is separate).

```java
public final class CorpusSeed<I, O> {
    private final String qualifiedName;
    private final String defaultTenancyId;
    private final List<InvocationRecord<I, O>> records = new ArrayList<>(); // not thread-safe — corpus seeding is single-threaded test setup
    private KeyExtractor<I> keyExtractor;
    private Function<I, O> outputMapper;

    public CorpusSeed(String qualifiedName, String defaultTenancyId) {
        this.qualifiedName = Objects.requireNonNull(qualifiedName);
        this.defaultTenancyId = Objects.requireNonNull(defaultTenancyId);
    }

    public CorpusSeed<I, O> withKeyExtractor(KeyExtractor<I> extractor) {
        this.keyExtractor = extractor;
        return this;
    }

    public CorpusSeed<I, O> withOutputMapper(Function<I, O> mapper) {
        this.outputMapper = mapper;
        return this;
    }

    // Auto-derives key from extractor when set
    public CorpusSeed<I, O> add(I input, O output) {
        String key = keyExtractor != null ? keyExtractor.extract(input) : null;
        records.add(InvocationRecord.of(defaultTenancyId, key, input, output));
        return this;
    }

    // Explicit key override
    public CorpusSeed<I, O> add(String key, I input, O output) {
        records.add(InvocationRecord.of(defaultTenancyId, key, input, output));
        return this;
    }

    // Different tenant for this entry
    public CorpusSeed<I, O> add(String tenancyId, String key, I input, O output) {
        records.add(InvocationRecord.of(tenancyId, key, input, output));
        return this;
    }

    // Uses outputMapper to derive output (D58)
    public CorpusSeed<I, O> add(I input) {
        if (outputMapper == null) {
            throw new IllegalStateException(
                "add(input) requires withOutputMapper() — call add(input, output) instead");
        }
        return add(input, outputMapper.apply(input));
    }

    // Data seeding only — no runtime mutation (D57)
    public void seedInto(SimulationCorpus<I, O> corpus) {
        corpus.seed(qualifiedName, List.copyOf(records));
    }

    public List<InvocationRecord<I, O>> build() {
        return List.copyOf(records);
    }

    public String qualifiedName() { return qualifiedName; }

    public KeyExtractor<I> keyExtractor() { return keyExtractor; }
}
```

**Extractor registration is explicit and separate** (D57):

```java
var seed = canAccess("hospital-a");
seed.add(check("admin", resource("case", "c-1"), WRITE), true);

seed.seedInto(corpus);
runtime.registerExtractor(seed.qualifiedName(), seed.keyExtractor());
```

Forgetting the second line causes a loud `SimulationConfigException` at resolution time, not a silent passthrough.

### Layer 3: Per-SPI descriptor classes (simulation-testing)

Each descriptor is a `public final class` with only static members (D59). Qualified name constants come from generated companion classes (D66), not hand-authored strings.

#### Example: AclCorpus

```java
package io.casehub.platform.simulation.testing;

import io.casehub.platform.api.acl.AclAction;
import io.casehub.platform.api.acl.ResourceId;
import io.casehub.platform.simulation.CorpusSeed;
import io.casehub.platform.simulation.KeyExtractor;
import io.casehub.platform.simulation.generated.AccessControlProviderQN;

public final class AclCorpus {

    private AclCorpus() {}

    public static CorpusSeed<Object[], Boolean> canAccess(String tenancyId) {
        return new CorpusSeed<>(AccessControlProviderQN.CAN_ACCESS, tenancyId)
            .withKeyExtractor(canAccessExtractor());
    }

    public static Object[] check(String actorId, ResourceId resourceId, AclAction action) {
        return new Object[]{actorId, resourceId, action};
    }

    public static ResourceId resource(String type, String id) {
        return new ResourceId(type, id);
    }

    public static KeyExtractor<Object[]> canAccessExtractor() {
        return params -> params[0] + ":" + params[1] + ":" + params[2];
    }
}
```

#### Example: ModelCorpus

`ModelRegistry.resolveById()` returns `Optional<ModelDescriptor>` — the corpus output type must match the SPI return type for the generated decorator's cast to succeed. The `found()` wrapper keeps `add()` calls clean while producing the required `Optional` value.

```java
public final class ModelCorpus {

    private ModelCorpus() {}

    public static CorpusSeed<String, Optional<ModelDescriptor>> resolveById(String tenancyId) {
        return new CorpusSeed<>(ModelRegistryQN.RESOLVE_BY_ID, tenancyId)
            .withKeyExtractor(id -> id);
    }

    public static Optional<ModelDescriptor> found(ModelDescriptor descriptor) {
        return Optional.of(descriptor);
    }

    public static ModelDescriptor model(String id, String backendKey, String vendor,
                                         String family, ModelTier tier, ModelLocality locality) {
        return new ModelDescriptor(id, id, backendKey, null, vendor, family, family,
            tier, Set.of(ModelCapabilities.TEXT), 128000, 4096, locality, null, null, Map.of());
    }
}
```

For Optional-returning SPIs, each descriptor provides a wrapper method (`found()`) that pairs with the domain factory (`model()`). This keeps CorpusSeed generic — the wrapping concern belongs in the descriptor layer where SPI-specific knowledge lives.

#### Example: NotificationCorpus (with output mapper)

```java
public final class NotificationCorpus {

    private NotificationCorpus() {}

    public static CorpusSeed<NotificationInput, Notification> store(String tenancyId) {
        return new CorpusSeed<>(NotificationStoreQN.STORE, tenancyId)
            .withKeyExtractor(i -> i.category() + ":" + i.severity())
            .withOutputMapper(NotificationCorpus::fromInput);
    }

    public static NotificationInput input(String title, String category,
                                            NotificationSeverity severity) {
        return new NotificationInput("user-1", "default", title, null, category,
            severity, null, new NotificationSource("evt-1", "system", "sys-1", "actor-1"));
    }

    public static Notification fromInput(NotificationInput input) {
        return new Notification(UUIDv7.generate().toString(), input.userId(),
            input.tenancyId(), input.title(), input.body(), input.category(),
            input.severity(), input.actionUrl(), input.source(),
            NotificationStatus.UNREAD, Instant.now(), null, null);
    }
}
```

#### Example: PreferenceCorpus

`PreferenceProvider.resolve(SettingsScope)` returns `Preferences` (the interface — `MapPreferences` is the concrete implementation used in test fixtures). Input type is `SettingsScope` (a 3-arg record: tenancyId, scope Path, effectiveAt Instant).

```java
public final class PreferenceCorpus {

    private PreferenceCorpus() {}

    public static CorpusSeed<SettingsScope, Preferences> resolve(String tenancyId) {
        return new CorpusSeed<>(PreferenceProviderQN.RESOLVE, tenancyId)
            .withKeyExtractor(scope -> scope.scope().value());
    }

    public static SettingsScope scope(String tenancyId, String... pathSegments) {
        return SettingsScope.of(tenancyId, Path.of(pathSegments));
    }

    public static Preferences preferences(Map<String, Object> values) {
        return new MapPreferences(values);
    }
}
```

#### Example: CredentialCorpus

`CredentialResolver.resolve(String)` returns `Map<String, String>` — the simplest descriptor. Input key is the credential ref string itself.

```java
public final class CredentialCorpus {

    private CredentialCorpus() {}

    public static CorpusSeed<String, Map<String, String>> resolve(String tenancyId) {
        return new CorpusSeed<>(CredentialResolverQN.RESOLVE, tenancyId)
            .withKeyExtractor(ref -> ref);
    }

    public static Map<String, String> credential(String key, String value) {
        return Map.of(key, value);
    }

    public static Map<String, String> credential(String k1, String v1, String k2, String v2) {
        return Map.of(k1, v1, k2, v2);
    }
}
```

### Layer 4: AgentCorpus (agent-simulation-core)

`AgentProvider` already has a hand-written simulation (`SimulatedAgentBackend`) — it is not in any `simulation-eligible.txt` listing file. Adding it would trigger both QN generation and decorator generation, but the decorator would conflict with `SimulatedAgentBackend`. Therefore `AgentProviderQN` is hand-authored alongside `SimulatedAgentBackend` in `agent-simulation-core`, not generated:

```java
public final class AgentProviderQN {
    public static final String INVOKE = "agent-provider.invoke";
    private AgentProviderQN() {}
}
```

`SimulatedAgentBackend` should be updated to use this constant (replacing its current `private static final String QN_INVOKE = "agent-provider.invoke"` hardcoded string).

```java
public final class AgentCorpus {

    private AgentCorpus() {}

    public static CorpusSeed<AgentSimulationInput, List<AgentEvent>> invoke(String tenancyId) {
        return new CorpusSeed<>(AgentProviderQN.INVOKE, tenancyId)
            .withKeyExtractor(SimulatedAgentBackend.defaultKeyExtractor());
    }

    public static AgentSimulationInput input(String systemPrompt, String userPrompt) {
        return new AgentSimulationInput(systemPrompt, userPrompt, null);
    }

    public static List<AgentEvent> textResponse(String text) {
        return List.of(new AgentEvent.TextDelta(text));
    }

    public static Function<String, String> llmFunction(AgentProvider agentProvider) {
        return prompt -> {
            var events = agentProvider.invoke(
                AgentSessionConfig.of("You are a test data generator.", prompt))
                .collect().asList().await().indefinitely();
            return events.stream()
                .filter(e -> e instanceof AgentEvent.TextDelta)
                .map(e -> ((AgentEvent.TextDelta) e).text())
                .collect(Collectors.joining());
        };
    }
}
```

### Generator enhancement: qualified name constants (D66)

`SimulationDecoratorProcessor` generates a companion constants class per SPI:

```java
// GENERATED by SimulationDecoratorProcessor — do not edit
package io.casehub.platform.simulation.generated;

public final class AccessControlProviderQN {
    public static final String CAN_ACCESS = "access-control-provider.canAccess";
    public static final String GRANT = "access-control-provider.grant";
    public static final String REVOKE = "access-control-provider.revoke";
    // ... one constant per intercepted method
    private AccessControlProviderQN() {}
}
```

Descriptors import these constants. A listing file rename or SPI method rename causes a compile error, not a silent runtime mismatch.

**Implementation scope:** `generateFromIndex()` currently produces only decorator sources — QN constants classes are new. Implementation requires:
1. Add `generateQNSource(ClassInfo spiClass, String spiName)` method to `SimulationDecoratorProcessor`
2. Emit one additional `GeneratedSource` per SPI with constants derived from `spiName + "." + method.name()` (same construction as the decorator's qualified name on line 171)
3. Update `SimulationDecoratorProcessorTest` to verify QN class generation alongside decorators

### LlmCorpusPopulator (simulation-testing)

Takes `Function<String, String>` — framework-agnostic (D62). Uses `PlatformSchemaGenerator` to produce JSON Schema from Java types.

```java
public final class LlmCorpusPopulator {

    private final Function<String, String> llmFunction;
    private final ObjectMapper objectMapper;
    private final PlatformSchemaGenerator schemaGen;

    public LlmCorpusPopulator(Function<String, String> llmFunction,
                                ObjectMapper objectMapper) {
        this.llmFunction = llmFunction;
        this.objectMapper = objectMapper;
        this.schemaGen = new PlatformSchemaGenerator();
    }

    public <I, O> void populate(CorpusSeed<I, O> seed,
                                 Class<I> inputType, Class<O> outputType,
                                 int count, String domainContext) {
        populate(seed, inputType, outputType, Function.identity(), count, domainContext);
    }

    public <I, O, R> void populate(CorpusSeed<I, O> seed,
                                    Class<I> inputType, Class<R> rawOutputType,
                                    Function<R, O> outputAdapter,
                                    int count, String domainContext) {
        List<InvocationRecord<I, O>> existing = seed.build();
        JsonNode inputSchema = schemaGen.generate(inputType);
        JsonNode outputSchema = schemaGen.generate(rawOutputType);

        String prompt = buildPrompt(inputSchema, outputSchema, existing, count, domainContext);
        String response = llmFunction.apply(prompt);

        try {
            JsonNode parsed = objectMapper.readTree(response);
            for (JsonNode entry : parsed) {
                I input = objectMapper.treeToValue(entry.get("input"), inputType);
                R rawOutput = objectMapper.treeToValue(entry.get("output"), rawOutputType);
                seed.add(input, outputAdapter.apply(rawOutput));
            }
        } catch (IOException e) {
            throw new UncheckedIOException("Failed to parse LLM corpus response", e);
        }
    }
}
```

The two-overload design handles Optional-returning SPIs: the convenience overload uses `Function.identity()` for direct types, while the full overload takes a `rawOutputType` and `outputAdapter` for wrapped types. For `ModelCorpus`, the adapter is `Optional::of` — Jackson deserializes into `ModelDescriptor`, the adapter wraps it before calling `seed.add()`.

**Prompt structure:** the generated prompt includes (1) JSON Schema for input and output types, (2) serialized existing entries as few-shot examples (if any), (3) the requested count, (4) the domain context string. Expected response format: a JSON array of `{"input": ..., "output": ...}` objects matching the schemas.

**Hybrid few-shot pattern:** existing entries in the seed serve as examples in the LLM prompt. Seed with 2-3 hand-crafted entries, then `populate()` generates 10-50 more consistent with the examples.

**Object[] input limitation:** SPIs with multi-param methods (e.g., AclCorpus) use `Object[]` as the input type. `PlatformSchemaGenerator.generate(Object[].class)` produces an "array of any" schema — unusable for LLM generation. LLM population is limited to SPIs with typed input classes (ModelCorpus, NotificationCorpus, CredentialCorpus, PreferenceCorpus). This is inherent in the `Object[]` representation and not a design flaw — multi-param SPIs use hand-authored corpora.

**Error handling:** Jackson's `readTree()` and `treeToValue()` throw checked `JsonProcessingException extends IOException`. These are wrapped in `UncheckedIOException` — all exceptions propagate as unchecked. Invalid JSON, schema mismatch, function errors (rate limit, timeout, content filter) all fail fast. Tests see clear stack traces without checked exception ceremony (D62).

## End-to-end usage

### ACL simulation (multi-param method)

```java
import static io.casehub.platform.simulation.testing.AclCorpus.*;

@QuarkusTest
class AuthorizationTest {
    @Inject SimulationRuntime runtime;
    @Inject SimulationCorpus corpus;

    @Test
    void adminCanWriteCases() {
        var seed = canAccess("hospital-a");
        seed.add(check("admin", resource("case", "c-1"), WRITE), true);
        seed.add(check("nurse", resource("case", "c-1"), READ), true);
        seed.add(check("nurse", resource("case", "c-1"), WRITE), false);

        seed.seedInto(corpus);
        runtime.registerExtractor(seed.qualifiedName(), seed.keyExtractor());

        // ... test code ...
    }
}
```

### Model registry simulation (single-param method, Optional return)

```java
import static io.casehub.platform.simulation.testing.ModelCorpus.*;

var seed = resolveById("tenant-1");
seed.add("claude-opus-5", found(model("claude-opus-5", "claude", "Anthropic", "Opus", FLAGSHIP, CLOUD)));
seed.add("gpt-4o", found(model("gpt-4o", "openai", "OpenAI", "GPT-4", STANDARD, CLOUD)));

seed.seedInto(corpus);
runtime.registerExtractor(seed.qualifiedName(), seed.keyExtractor());
```

### Notification pipeline with output derivation

```java
import static io.casehub.platform.simulation.testing.NotificationCorpus.*;

var seed = store("hospital-a");
seed.add(input("SLA Breached", "sla.breach", URGENT));
seed.add(input("Case Updated", "case.update", INFO));

seed.seedInto(corpus);
runtime.registerExtractor(seed.qualifiedName(), seed.keyExtractor());
```

### LLM hybrid (few-shot + generation)

```java
var populator = new LlmCorpusPopulator(AgentCorpus.llmFunction(agentProvider), objectMapper);

var seed = resolveById("tenant-1");
seed.add("claude-opus-5", found(model("claude-opus-5", "claude", "Anthropic", "Opus", FLAGSHIP, CLOUD)));
seed.add("gpt-4o", found(model("gpt-4o", "openai", "OpenAI", "GPT-4", STANDARD, CLOUD)));

populator.populate(seed, String.class, ModelDescriptor.class, Optional::of, 10,
    "Generate realistic AI model descriptors for a healthcare platform");

seed.seedInto(corpus);
```

The adapter overload (`Optional::of`) tells the populator to deserialize into `ModelDescriptor` and wrap each result before calling `seed.add()`. For SPIs with direct return types (NotificationCorpus, CredentialCorpus), use the convenience overload without an adapter.

### Overlay integration (per-test isolation)

```java
var overlay = runtime.pushOverlay(config);
canAccess("hospital-a")
    .add(check("admin", resource("case", "c-1"), WRITE), true)
    .seedInto(overlay.corpus());
// ... test ...
runtime.popOverlay(overlay);
```

Note: `SimulationOverlay.corpus()` returns raw `SimulationCorpus` (no type params). `CorpusSeed.seedInto()` accepts this via raw-type compatibility — produces an unchecked warning. Test code using this pattern will typically suppress with `@SuppressWarnings("unchecked")` on the test method. This is inherent in the overlay's raw-type design and not a CorpusSeed concern.

## Module layout

| Module | Artifact | New/Existing | Contents |
|--------|----------|-------------|----------|
| simulation-api | casehub-platform-simulation-api | Existing | `InvocationRecord.of()` factories, `CorpusSeed<I,O>` |
| simulation-core | casehub-platform-simulation-core | Existing | (unchanged) |
| simulation-generator | casehub-platform-simulation-generator | Existing | `*QN` companion constants classes |
| simulation-testing | casehub-platform-simulation-testing | **New** | AclCorpus, ModelCorpus, NotificationCorpus, PreferenceCorpus, CredentialCorpus, LlmCorpusPopulator |
| agent-simulation-core | casehub-platform-agent-simulation-core | Existing | AgentCorpus descriptor, llmFunction() adapter |

### simulation-testing dependencies

```xml
<dependencies>
    <dependency>
        <groupId>io.casehub</groupId>
        <artifactId>casehub-platform-simulation-api</artifactId>
    </dependency>
    <dependency>
        <groupId>io.casehub</groupId>
        <artifactId>casehub-platform-api</artifactId>
    </dependency>
    <dependency>
        <groupId>io.casehub</groupId>
        <artifactId>casehub-platform-platform-simulation-core</artifactId>
        <!-- Generated QN constants for platform-api SPIs -->
    </dependency>
    <dependency>
        <groupId>io.casehub</groupId>
        <artifactId>casehub-platform-schema-generator</artifactId>
    </dependency>
    <dependency>
        <groupId>com.fasterxml.jackson.core</groupId>
        <artifactId>jackson-databind</artifactId>
    </dependency>
</dependencies>
```

No agent-api dependency. The `Function<String, String>` abstraction keeps agent concerns in agent-simulation-core.

## SPI descriptor scope (D63)

### In scope (5 high-value SPIs)

| Descriptor | SPI | Key methods | Input shape | LLM generation |
|-----------|-----|-------------|-------------|----------------|
| AclCorpus | AccessControlProvider | canAccess, accessibleResources | Object[] (3 params) | No — Object[] schema unusable |
| ModelCorpus | ModelRegistry | resolveById, query, all | String / ModelQuery / null | Yes (via adapter) |
| NotificationCorpus | NotificationStore | store, find | NotificationInput / NotificationQuery | Yes |
| PreferenceCorpus | PreferenceProvider | resolve | SettingsScope | Yes (via adapter) |
| CredentialCorpus | CredentialResolver | resolve | String | Yes |

### Deferred (6 SPIs — mechanical to add later, tracked as #TBD)

DataSourceRegistry, EndpointRegistry, SubscriptionStore, ExpressionEngineRegistry, DocumentSigningService, CurrentPrincipal. Consumers can seed these directly via CorpusSeed without convenience factories. Umbrella issue to be filed before implementation begins.

## Testing strategy

1. **CorpusSeed unit tests** — accumulation, key derivation, output mapping, seedInto
2. **InvocationRecord.of() tests** — factory methods produce correct records
3. **Per-descriptor unit tests** — factory methods produce valid domain objects, qualified names match generated constants
4. **LlmCorpusPopulator unit test** — mock Function, verify schema in prompt, verify parsing
5. **Generator test** — verify `*QN` companion class generation alongside decorators
6. **Integration test** — one `@QuarkusTest` verifying end-to-end: descriptor → CorpusSeed → corpus → strategy resolution

## Data realism roadmap

CorpusSeed is the universal accumulation point for three layers:

```
#328 (this)  Seeding      — CorpusSeed, descriptors, LLM populator
#347         Synthesis    — named patterns, perturbation primitives, domain mutators
#348         Catalogue    — exemplar storage, statistical envelopes, canonical sequences
```

Each layer adds entries via `seed.add()`. Each improves synthesis quality independently. The architecture supports the full stack without #328 needing to anticipate synthesis internals.

## References

- SimulationDecoratorProcessor.java (lines 186-194 — Object[] for multi-param methods)
- SimulationRuntime.java (strategyFor, registerExtractor, requireExtractor)
- InvocationRecord.java, SimulationCorpus.java, KeyExtractor.java (simulation-api types)
- AgentSimulationInput.java, SimulatedAgentBackend.java (agent-simulation-core precedents)
- PlatformSchemaGenerator.java (JSON Schema generation for LLM prompts)
- platform-simulation-core/META-INF/simulation-eligible.txt (11 listed SPIs)
- Decisions D55-D67 in decisions.md
- Issue #328, follow-ons #347 (synthesis), #348 (catalogue)
