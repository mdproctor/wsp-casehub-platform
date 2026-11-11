# Generate @Plugin Playbook Step Types from @PlatformQuery/@PlatformMutation

**Issue:** casehubio/platform#795
**Date:** 2026-11-11
**Status:** Design

## Summary

Extend the `GraphQLResolverProcessor` APT to generate `@Plugin` playbook step types as a fourth output alongside GraphQL resolvers, REST resources, and MCP tool definitions. One source (`@McpDomain` class or interface with `@PlatformQuery`/`@PlatformMutation` methods), four generated outputs.

## Two-Tier Generation Strategy

Generated plugins operate at the level appropriate to the `@McpDomain` target type:

### Tier 1 — Platform interfaces

`@McpDomain` on an **interface** (e.g., `AclApi`, `NotificationApi`, `PreferenceApi`). The plugin takes the interface as an `@Execute` parameter and calls the method directly. No SPI routing, no capability annotation needed. Works automatically with zero annotation changes.

```java
// Source: AclApi interface
@McpDomain("acl")
public interface AclApi {
    @PlatformQuery("Check whether an actor can access a resource")
    boolean canAccess(String actorId, ResourceId resourceId, AclAction action);
}

// Generated plugin
@Plugin(value = "acl-can-access", description = "Check whether an actor can access a resource")
public record AclCanAccessPlugin(
        @Required String actorId,
        @Required ResourceId resourceId,
        @Required AclAction action) {

    @Execute
    public Result execute(AclApi api) {
        var result = api.canAccess(actorId, resourceId, action);
        return Result.of(Map.of("result", result));
    }
}
```

### Tier 2 — Connector classes

`@McpDomain` on a **class** with `@Inject` fields (e.g., `ConnectorBankApi`, `ConnectorVoiceApi`). The plugin takes the resolved SPI type (e.g., `BankPlatform`) as an `@Execute` parameter. Uses `@GeneratePlugin(capability = ...)` to determine the call chain through capability sub-interfaces.

```java
// Source: ConnectorBankApi class
@McpDomain(value = "connectors/bank", app = "connectors")
@ApplicationScoped
public class ConnectorBankApi {
    @Inject BankPlatformService bankService;

    @PlatformQuery("Get current balance for a bank account")
    @GeneratePlugin(capability = AccountInformation.class,
                    absorb = true, subject = "accountId")
    public AccountBalance balance(
            @QueryParam("platform") String platform,
            @PathParam String accountId) { ... }
}

// Generated plugin
@Plugin(value = "bank-balance",
        description = "Get current balance for a bank account",
        absorbSiblings = true)
public record BankBalancePlugin(
        @Required String accountId,
        @Optional String userId) {

    @Execute
    public Result execute(BankPlatform spi) {
        var result = spi.accountInformation(userId).balance(accountId);
        return Result.of(Records.toMap(result));
    }
}
```

YAML surface:
```yaml
- bank-balance: "12345678"
```
or:
```yaml
- bank-balance:
    accountId: "12345678"
    userId: alice
```

## Annotation Changes

### No changes to @PlatformQuery or @PlatformMutation

`@PlatformQuery` and `@PlatformMutation` are unchanged. Plugin metadata lives on a dedicated `@GeneratePlugin` annotation, following the same surface-separation pattern as REST (`@RestPath`, `@RestMethod`, `@RestStatus`, `@RestName`).

### @GeneratePlugin annotation

Plugin generation is triggered by the `generatePlugins` compiler option, not by annotation presence. When `generatePlugins=true`, ALL `@PlatformQuery`/`@PlatformMutation` methods generate plugins with sensible defaults. `@GeneratePlugin` provides explicit control when defaults are insufficient — it is the sole source of plugin metadata.

```java
@Target(ElementType.METHOD)
@Retention(RetentionPolicy.RUNTIME)
public @interface GeneratePlugin {
    String name() default "";
    String description() default "";
    boolean absorb() default false;
    String subject() default "";
    Class<?> capability() default void.class;
    Class<?> spi() default void.class;      // explicit SPI type override
    String accessor() default "";            // explicit accessor method name
    String spiMethod() default "";           // SPI method name when it differs from the API method name
    String[] optionalParams() default {};    // parameter names to generate as @Optional instead of @Required
    boolean exclude() default false;         // opt out of generation
}
```

- When absent: generate with defaults (name derived, no absorb, no subject, no capability routing)
- When present: use its values for the generated plugin
- `exclude = true`: suppress plugin generation for that method

Module location: `mcp-api/` (alongside `@RestPath` and other surface annotations).

**Scope divergence from issue #795:** The issue proposed three inline attributes on `@PlatformQuery`/`@PlatformMutation` with no new annotation type. This design uses a dedicated annotation instead, adding `capability` and `exclude` attributes beyond the original scope. The issue should be updated to reflect the expanded design.

### Plugin name derivation

When `@GeneratePlugin` is absent or `name()` is empty (default):
1. Take the `@McpDomain` value: `"connectors/bank"`
2. Extract the last segment: `"bank"`
3. Kebab-case the method name: `"listTransactions"` → `"list-transactions"`
4. Combine: `"bank-list-transactions"`

For platform interfaces: `@McpDomain("acl")` + `canAccess` → `"acl-can-access"`.

## APT Processing Flow

### Extension point

Plugin generation slots into `GraphQLResolverProcessor.process()` at the existing per-domain loop (line 141), gated by a `generatePlugins` processor option (default: `false`).

`getSupportedOptions()` must be updated to include the new option:

```java
@Override
public Set<String> getSupportedOptions() {
    return Set.of("generateGraphQL", "generateRest", "domainFilter",
                  "restPackage", "graphqlPackage", "restPathPrefix",
                  "generatePlugins", "pluginPackage");   // NEW
}
```

The `pluginPackage` option sets the Java package for generated plugin records. When unset, the default uses `deriveOutputPackage(spiPackage, "plugin")` — the same derivation as `graphqlPackage`/`restPackage`: replaces `.api.` in the source package with `.plugin.` (e.g., `io.casehub.platform.api.acl` → `io.casehub.platform.plugin.acl`). When set, all generated plugins use the specified package.

```java
for (var entry : allDomains.entrySet()) {
    if (generateGraphQL) generateResolverSource(...);
    if (generateRest)    generateRestResourceSource(...);
    if (generatePlugins) generatePluginSource(...);   // NEW
}
```

### APT processing chain

1. **Round 1:** `GraphQLResolverProcessor` scans `@McpDomain` types, generates `@Plugin` record `.java` files
2. **Round 2:** `StepPluginProcessor` discovers the generated `@Plugin` records and emits JSON Schema + Action class + registry manifest

**Prerequisite: `StepPluginProcessor` must be made multi-round-aware.** The current implementation has a `processed` boolean guard that fires once in Round 1 and prevents processing generated `@Plugin` types in Round 2:

```java
if (processed || roundEnv.processingOver()) return false;
processed = true;
```

**Fix:** Replace the `processed` boolean with a `Set<String>` of already-processed qualified type names. On each round, process only newly-appearing `@Plugin` types not already in the set. This is the correct APT multi-round pattern — processors should be multi-round-aware by design.

```java
private final Set<String> processedTypes = new HashSet<>();

@Override
public boolean process(Set<? extends TypeElement> annotations, RoundEnvironment roundEnv) {
    if (roundEnv.processingOver()) return false;
    for (Element element : roundEnv.getElementsAnnotatedWith(Plugin.class)) {
        String qname = ((TypeElement) element).getQualifiedName().toString();
        if (processedTypes.contains(qname)) continue;
        processedTypes.add(qname);
        // ... existing validation and generation
    }
    return false;
}
```

### SPI type resolution

**Interface path:** The `@McpDomain` interface itself is the `@Execute` parameter type. No inference needed.

**Connector class path:**
1. If `@GeneratePlugin(spi = X.class)` is present, use that directly (explicit override — skips inference)
2. If `@GeneratePlugin(capability = X.class)` is present, find which `@Inject` field's SPI type contains that capability interface via Jandex. If exactly one SPI type matches, use it. If multiple contain the capability, emit compile error requiring `@GeneratePlugin(spi = ...)`
3. Otherwise, find `@Inject` fields on the `@McpDomain` class. For each field type, check via Jandex if it has a `platform(String)` method. The return type of that method is the SPI type (e.g., `BankPlatformService.platform()` → `BankPlatform`)
4. If exactly one `@Inject` field qualifies, use its SPI type. If **multiple** `@Inject` fields qualify (multi-service connectors), emit compile error requiring `@GeneratePlugin(spi = ...)` to disambiguate

If inference fails (no qualifying field found), emit a compile error — no silent fallback.

### Capability call chain resolution

When `@GeneratePlugin(capability = X.class)` is set (not `void.class`):
1. Derive accessor name: decapitalize capability class name (`AccountInformation` → `accountInformation`)
2. If `@GeneratePlugin(accessor = "...")` is present, use that instead
3. Verify via Jandex: the SPI type must have a method with that name returning the capability type — emit compile error otherwise
4. Introspect accessor parameters: if the accessor takes parameters (e.g., `accountInformation(String userId)`), add corresponding `@Optional` fields to the plugin record
5. Find the method on the capability interface: if `@GeneratePlugin(spiMethod = "...")` is specified, use that name; otherwise use the API method name. Emit compile error if no matching method is found on the capability interface.
6. **Parameter type compatibility:** The source method parameters (excluding routing, context, and streaming-input parameters) must match the SPI method parameters in type. When parameter types diverge (e.g., source has individual `String` params but the SPI method takes a record), the generator emits a compile error — the plugin must be hand-written. The generator does NOT auto-construct record types from individual parameters.

When no `@GeneratePlugin` is present or `capability` is `void.class`, call the method directly on the interface/SPI type.

### Parameter mapping

| Source annotation | Plugin field |
|-------------------|-------------|
| `@PathParam` | `@Required` |
| `@QueryParam` with `@DefaultValue` | `@Optional` |
| `@QueryParam` without default, reference type | `@Optional` |
| `@QueryParam` without default, primitive type | `@Required` |
| Unannotated, primitive type | `@Required` |
| Unannotated, boxed primitive (`Integer`, `Long`, `Boolean`, etc.) | `@Optional` |
| Unannotated, reference type (`String`, records, etc.) | `@Required` |
| `@ContextParam` | Excluded |
| Routing parameter (connector `platform` param) | Excluded |
| Capability accessor parameters | Added as `@Optional` fields |

**Unannotated parameters:** Tier 1 platform interface methods (e.g., `AclApi.check(String actorId, ResourceId resourceId, AclAction action)`) have no `@PathParam`/`@QueryParam` annotations. All unannotated parameters become plugin record fields. Boxed primitive types indicate nullable/optional semantics (e.g., `Integer limit`); all other types default to `@Required` since the safe default is to require inputs.

**Overriding optionality for specific parameters:** Two mechanisms are supported:

1. **`@GeneratePlugin(optionalParams = {"cursor", "category"})`** — lists parameter names that should generate as `@Optional` instead of `@Required`. The APT validates that listed names exist as parameters on the method — compile error if a listed name doesn't match. Example:
   ```java
   @PlatformQuery("List available models — all params optional.")
   @GeneratePlugin(optionalParams = {"vendor", "family", "tier", "locality", "maxCostTier"})
   List<ModelDescriptor> listModels(String vendor, String family,
                                    String tier, String locality, String maxCostTier);
   ```

2. **Java nullability annotations** — if a parameter is annotated with `@Nullable` (from `jakarta.annotation`, `org.jspecify.annotations`, or `org.jetbrains.annotations`), the generator treats it as `@Optional`. This is the canonical Java mechanism for expressing parameter optionality and is not plugin-specific.

**Routing parameter identification:** A parameter is a routing parameter if its name matches the argument of the `platform(String)` method on the `@Inject` service type. Only applies to connector classes.

### Skip detection

Scan for existing `@Plugin` classes with matching `value()` names using the same dual-scan pattern as GraphQL/REST skip detection:

1. **Jandex index:** scan dependency jars on the classpath for `@Plugin` annotations, collect their `value()` names. This catches hand-written plugins in other modules (e.g., `BankBalancePlugin` in `connectors/bank-spi/`) provided the module's Jandex index is on the compilation classpath.
2. **RoundEnvironment:** scan the current compilation unit for `@Plugin` records, collect their `value()` names. This catches hand-written plugins in the same module.

If a hand-written plugin exists with the same name as a generated plugin, skip generation for that method. Log a NOTE diagnostic.

**Implementation note:** `graphql-generator` does not depend on `yaml-plugin-api`, so the scan uses `DotName.createSimple("io.casehub.yaml.plugin.api.Plugin")` — the same string-based annotation reference pattern used throughout the processor for all other annotations.

## Result Handling

### Records.toMap() — new utility class

`Records.toMap(Object record)` is a **new** runtime utility to be written in `yaml-step-runtime`. No such class currently exists in the codebase.

```java
public final class Records {
    public static Map<String, Object> toMap(Object record) {
        // Uses java.lang.reflect.RecordComponent
        // Recursively flattens nested records
        // Returns simple Map<String, Object>
    }
}
```

**Edge case behaviour:**
- `null` input → throw `IllegalArgumentException` (a null result from the SPI is an error)
- Non-record input → throw `IllegalArgumentException`
- Null component values → `null` values in the map
- Nested records → recursive: component value that is a record → `toMap(component)`
- Records containing `List<T>` → if T is a record, `list.stream().map(Records::toMap).toList()`; if T is a simple type, pass through
- Records with `Optional<T>` components → unwrap: `optional.orElse(null)` in the map
- Records with `Map<K,V>` components → pass through as-is

### Return type table

| Return type | Generated code |
|-------------|----------------|
| Record type | `Result.of(Records.toMap(result))` |
| `boolean` | `Result.of(Map.of("result", result))` |
| `String` | `Result.of(Map.of("result", result))` |
| Primitive wrapper | `Result.of(Map.of("result", result))` |
| `void` | `Result.of(Map.of())` |
| `Optional<T>` where T is a record | `Result.of(result.map(Records::toMap).orElse(Map.of()))` |
| `Optional<T>` where T is a simple type | `Result.of(result.map(v -> Map.of("result", v)).orElse(Map.of()))` |
| `List<T>` where T is a record | `Result.of(Map.of("items", result.stream().map(Records::toMap).toList()))` |
| `Set<T>` where T is a record | `Result.of(Map.of("items", result.stream().map(Records::toMap).toList()))` |
| `Page<T>` | `Result.of(Map.of("items", ..., "cursor", ..., "hasMore", ...))` |
| `Map<K,V>`, raw `Object` | Unsupported — skip with WARNING diagnostic (see §What Is NOT Generated) |
| `Multi<T>`, `Flow.Publisher<T>` | Unsupported — excluded from generation (see §What Is NOT Generated) |

## Error Handling

Generated plugins do NOT catch SPI exceptions. Exceptions propagate to the step runner, which wraps them into step failure results uniformly. This matches the existing hand-written plugin convention (`BankBalancePlugin` has no try-catch).

## What Is NOT Generated

- Methods on classes without `@McpDomain`
- Methods without `@PlatformQuery` or `@PlatformMutation`
- Methods annotated with `@GeneratePlugin(exclude = true)`
- Methods whose plugin name matches an existing hand-written `@Plugin`
- Methods where SPI type inference fails (connector classes only) — compile error
- Methods where capability accessor verification fails — compile error
- Methods returning reactive types (`Multi<T>`, `Flow.Publisher<T>`, `Publisher<T>`) — these are MCP streaming endpoints with fundamentally different semantics; they do not map to the plugin streaming contract
- Methods returning `Map<K,V>` or raw `Object` — unsupported return types, skip with WARNING diagnostic (e.g., `NotificationApi.unreadCount()` returns `Map<String, Long>` — skipped, not an error)

Processing plugins with no MCP equivalent (AudioPlugin, AudioDenoisePlugin, SpeakerPlugin) remain hand-written — they have no `@PlatformQuery`/`@PlatformMutation` annotation.

## Generated Code Examples

### Streaming mutation — agent query

The streaming plugin contract differs from non-streaming: the `@Execute` method's first parameter is the streaming input, it returns a typed output (not `Result`), and remaining parameters are services. Configuration parameters are record fields.

For `@PlatformMutation(streaming = true)` methods, `@GeneratePlugin(subject = "prompt")` identifies which method parameter becomes the streaming input. All other non-excluded parameters become plugin record fields. If `subject` is not specified for a streaming mutation, emit a compile error.

This example uses a Tier 1 interface (direct delegation, no capability routing):

```java
// Source: AgentHttpApi interface
@McpDomain("agent-http")
public interface AgentHttpApi {
    @PlatformMutation(value = "Query within a session", streaming = true)
    @GeneratePlugin(subject = "prompt")
    Multi<AgentEvent> querySession(String sessionId, String prompt);
}

// Generated plugin (Multi<T> return is excluded from generation — see §What Is NOT Generated)
// This method would NOT generate a plugin due to the reactive return type.
```

For streaming mutations with non-reactive return types (e.g., a record output), the generated plugin forwards parameters directly:

```java
// Source: hypothetical streaming interface method
@PlatformMutation(value = "Transcribe audio to text", streaming = true)
@GeneratePlugin(subject = "audio")
TranscriptionResult transcribe(String audio, String language);

// Generated plugin
@Plugin(value = "example-transcribe", streaming = true,
        description = "Transcribe audio to text")
public record ExampleTranscribePlugin(@Required String language) {

    @Execute
    public TranscriptionResult process(String audio, TranscriptionService spi) {
        return spi.transcribe(audio, language);
    }
}
```

The generator forwards source method parameters directly to the SPI method call. When the source method and SPI method have the same parameter types, no type synthesis is needed. When they diverge (different parameter types or counts), the generator emits a compile error — the plugin must be hand-written.

For Tier 2 streaming connector methods with capability routing, use `@GeneratePlugin(spiMethod = "...")` when the API method name differs from the capability interface method name. If `spiMethod` is unspecified, the generator uses the API method name to find the capability method.

### Mutation with complex type — bank payment

Complex method parameters (records, POJOs) are passed as whole plugin record fields — the generator does NOT decompose them into individual fields. JSON Schema generated by `StepPluginProcessor` handles the record's field structure for the YAML surface.

```java
@Plugin(value = "bank-initiate-payment", description = "Initiate a payment")
public record BankInitiatePaymentPlugin(
        @Required PaymentRequest payment,
        @Optional String userId) {

    @Execute
    public Result execute(BankPlatform spi) {
        var result = spi.paymentInitiation(userId).initiatePayment(payment);
        return Result.of(Records.toMap(result));
    }
}
```

Accessor parameters (`userId` here) are always `@Optional` with no hardcoded defaults. If null at runtime, the value is passed directly to the SPI — the SPI implementation decides how to handle absent accessor parameters.

### Platform interface — label query

```java
// Source: LabelApi interface
@McpDomain("labels")
public interface LabelApi {
    @PlatformQuery("List immediate children at a label path. Pass empty string for top-level nodes.")
    List<LabelDescriptor> children(String parentPath);
}

// Generated plugin
@Plugin(value = "labels-children",
        description = "List immediate children at a label path. Pass empty string for top-level nodes.")
public record LabelsChildrenPlugin(@Required String parentPath) {

    @Execute
    public Result execute(LabelApi api) {
        var result = api.children(parentPath);
        return Result.of(Map.of("items", result.stream()
                .map(Records::toMap).toList()));
    }
}
```

## Plugin Annotation Defaults

Generated plugins use these `@Plugin` attribute values:

| Attribute | Value | Rationale |
|-----------|-------|-----------|
| `portability` | `Portability.JAVA` | Generated plugins are Java code calling Java interfaces/SPIs — they can only run on a JVM. Even Tier 1 interface plugins call Java interfaces. `UNIVERSAL` is for language-agnostic implementations. |
| `capability` | `"steps"` | These are playbook step plugins, which is the default plugin capability. |

Both use `@Plugin` annotation defaults — no explicit attributes needed in generated code.

## Testing Strategy

### 1. Generator tests — platform repo (graphql-generator/src/test/)

Compile-testing with `javax.tools.JavaCompiler` — feed mock `@McpDomain` types to the processor, assert generated plugin source matches expected output. Test cases:
- Simple query (interface method → direct delegation)
- Connector method with `@GeneratePlugin(capability = ...)`
- Streaming mutation with correct contract
- Complex type parameter (pass whole, no decomposition)
- Unannotated parameters (Tier 1 interface methods)
- Skip detection (existing hand-written plugin)
- `@GeneratePlugin` name/absorb/subject overrides
- `@GeneratePlugin(exclude = true)` suppression
- Compile error on failed SPI inference
- Compile error on failed accessor verification
- Compile error on parameter type mismatch between source and SPI methods
- Warning + skip on unsupported return types (`Map`)
- `StepPluginProcessor` multi-round processing (generated `@Plugin` records processed in Round 2)

### 2. APT chain test — connectors repo (tracked separately)

Verify the two-round processing chain: `GraphQLResolverProcessor` generates `@Plugin` records → `StepPluginProcessor` emits JSON Schema + Action classes. Assert artifacts exist in `META-INF/yaml-plugins/`. **Cross-repo:** This test runs in the connectors build where the APT processors from platform execute against real connector `@McpDomain` classes. Tracked under a separate connectors issue.

### 3. Plugin runtime tests — connectors repo (tracked separately)

`.test.yaml` files exercising generated plugins with mock SPI implementations registered in `yaml-services.yaml`. Validates: YAML step → generated Action → generated Plugin record → SPI call → result flatten. **Cross-repo:** Tracked under a separate connectors issue.

### 4. Records.toMap() tests — platform repo (yaml-step-runtime)

Unit tests for the new flatten utility: simple records, nested records, records with lists, records with `Optional` fields, records with `Map` components, null component values, null input (throws), non-record input (throws).

## Deployment Strategy

### Where plugins are generated

`platform-api/` is a zero-dependency API module — it cannot run APT processors. Tier 1 plugins are generated by downstream modules that have `platform-api/` on their classpath and enable `generatePlugins=true`.

| Module | Generates | How |
|--------|-----------|-----|
| `connectors/graphql/` | Tier 2 connector plugins + Tier 1 platform interface plugins | `platform-api/` is on its classpath via transitive deps; `GraphQLResolverProcessor` scans the combined Jandex index containing both connector and platform-api `@McpDomain` types |
| Future `platform-plugins/` module | Tier 1 platform interface plugins only | Dedicated module for deployments without connectors; depends on `platform-api/` and `graphql-generator` as APT |

**Default strategy:** The connectors module generates BOTH tiers from its combined classpath. Since the YAML step runtime in production always has the connectors module loaded, this covers all generated plugins. `domainFilter` can restrict which domains generate plugins in any given module if needed.

**Standalone deployments:** If platform-api plugins are needed without the connectors module (e.g., a platform-only deployment), a `platform-plugins/` module should be created. This is not needed initially but is the natural extension point.

## Scale

Generates plugins for all 13 connector platform SPIs (60-80 operations) plus platform interface methods across `@McpDomain` interfaces in platform-api. Total coverage: potentially 100+ generated plugins.

## Migration

Existing hand-written plugins with MCP equivalents (bank-balance, chat-send, email-messages, tts-synthesise, stt-transcribe) can be deleted once the generated equivalents produce identical YAML surfaces. Migration is per-plugin: verify the generated plugin name, parameter names, and absorb/subject behavior match the hand-written version before deleting.

## References

- `graphql-generator/src/main/java/.../GraphQLResolverProcessor.java` — APT extension point (line 141 per-domain loop)
- `yaml-plugin-api/src/main/java/.../Plugin.java` — @Plugin annotation contract
- `yaml-plugin-processor/src/main/java/.../StepPluginProcessor.java` — downstream processor for generated @Plugin records
- `mcp-api/src/main/java/.../PlatformQuery.java` — source annotation (unchanged)
- `mcp-api/src/main/java/.../PlatformMutation.java` — source annotation (unchanged)
- `mcp-api/src/main/java/.../GeneratePlugin.java` — new plugin metadata annotation
- `connectors/graphql/src/main/java/.../ConnectorBankApi.java` — representative connector API
- `connectors/bank-spi/src/main/java/.../BankBalancePlugin.java` — existing hand-written plugin
- `connectors/graphql/src/main/java/.../ConnectorVoiceApi.java` — complex connector pattern (multi-service, streaming)
- casehubio/platform#795 — tracking issue
