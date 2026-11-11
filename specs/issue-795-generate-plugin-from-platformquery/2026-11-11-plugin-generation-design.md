# Generate @Plugin Playbook Step Types from @PlatformQuery/@PlatformMutation

**Issue:** casehubio/platform#795
**Date:** 2026-11-11
**Status:** Design

## Summary

Extend the `GraphQLResolverProcessor` APT to generate `@Plugin` playbook step types as a fourth output alongside GraphQL resolvers, REST resources, and MCP tool definitions. One source (`@McpDomain` class or interface with `@PlatformQuery`/`@PlatformMutation` methods), four generated outputs.

## Two-Tier Generation Strategy

Generated plugins operate at the level appropriate to the `@McpDomain` target type:

### Tier 1 — Platform interfaces

`@McpDomain` on an **interface** (e.g., `AclApi`, `NotificationApi`, `PreferenceApi`). The plugin takes the interface as an `@Execute` parameter and calls the method directly. No SPI routing, no `pluginCapability` needed. Works automatically with zero annotation changes.

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

`@McpDomain` on a **class** with `@Inject` fields (e.g., `ConnectorBankApi`, `ConnectorVoiceApi`). The plugin takes the resolved SPI type (e.g., `BankPlatform`) as an `@Execute` parameter. Uses `pluginCapability` annotation metadata to determine the call chain through capability sub-interfaces.

```java
// Source: ConnectorBankApi class
@McpDomain(value = "connectors/bank", app = "connectors")
@ApplicationScoped
public class ConnectorBankApi {
    @Inject BankPlatformService bankService;

    @PlatformQuery(value = "Get current balance for a bank account",
        pluginCapability = AccountInformation.class,
        pluginAbsorb = true,
        pluginSubject = "accountId")
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
        var result = spi.accountInformation(userId != null ? userId : "user-1")
                .balance(accountId);
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

### Attributes on @PlatformQuery and @PlatformMutation

Four optional attributes added to both annotations in `mcp-api/`:

| Attribute | Type | Default | Purpose |
|-----------|------|---------|---------|
| `pluginName` | `String` | `""` | Override generated plugin name |
| `pluginAbsorb` | `boolean` | `false` | Sets `@Plugin(absorbSiblings = true)` |
| `pluginSubject` | `String` | `""` | Parameter for bare-value YAML syntax |
| `pluginCapability` | `Class<?>` | `void.class` | Capability sub-interface for connector SPI routing |

When all attributes are at their defaults, the plugin is still generated — the defaults produce a functional plugin. The attributes are the quality control mechanism for producing beautiful YAML step surfaces.

### Fallback @GeneratePlugin annotation

For methods where `@PlatformQuery` attributes can't express the required plugin shape, a separate `@GeneratePlugin` annotation provides explicit control:

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
    boolean exclude() default false;         // opt out of generation
}
```

When both `@PlatformQuery` attributes and `@GeneratePlugin` are present, `@GeneratePlugin` takes precedence. `exclude = true` suppresses plugin generation for that method.

Module location: `mcp-api/` (alongside `@PlatformQuery`).

### Plugin name derivation

When `pluginName` is empty (default):
1. Take the `@McpDomain` value: `"connectors/bank"`
2. Extract the last segment: `"bank"`
3. Kebab-case the method name: `"listTransactions"` → `"list-transactions"`
4. Combine: `"bank-list-transactions"`

For platform interfaces: `@McpDomain("acl")` + `canAccess` → `"acl-can-access"`.

## APT Processing Flow

### Extension point

Plugin generation slots into `GraphQLResolverProcessor.process()` at the existing per-domain loop (line 141), gated by a `generatePlugins` processor option (default: `false`).

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

### SPI type resolution

**Interface path:** The `@McpDomain` interface itself is the `@Execute` parameter type. No inference needed.

**Connector class path:**
1. Find `@Inject` fields on the `@McpDomain` class
2. For each field type, check via Jandex if it has a `platform(String)` method
3. The return type of that method is the SPI type (e.g., `BankPlatformService.platform()` → `BankPlatform`)
4. If `@GeneratePlugin(spi = X.class)` is present, use that instead

If inference fails, emit a compile error — no silent fallback.

### Capability call chain resolution

When `pluginCapability` is set (not `void.class`):
1. Derive accessor name: decapitalize capability class name (`AccountInformation` → `accountInformation`)
2. If `@GeneratePlugin(accessor = "...")` is present, use that instead
3. Verify via Jandex: the SPI type must have a method with that name returning the capability type — emit compile error otherwise
4. Introspect accessor parameters: if the accessor takes parameters (e.g., `accountInformation(String userId)`), add corresponding `@Optional` fields to the plugin record
5. Find the method on the capability interface matching the API method name

When `pluginCapability` is `void.class`, call the method directly on the interface/SPI type.

### Parameter mapping

| Source annotation | Plugin field |
|-------------------|-------------|
| `@PathParam` | `@Required` |
| `@QueryParam` with `@DefaultValue` | `@Optional` |
| `@QueryParam` without default, reference type | `@Optional` |
| `@QueryParam` without default, primitive type | `@Required` |
| `@ContextParam` | Excluded |
| Routing parameter (connector `platform` param) | Excluded |
| Capability accessor parameters | Added as `@Optional` fields |

**Routing parameter identification:** A parameter is a routing parameter if its name matches the argument of the `platform(String)` method on the `@Inject` service type. Only applies to connector classes.

### Skip detection

Scan for existing `@Plugin` classes with matching `value()` names — same pattern as GraphQL/REST hand-written skip detection. If a hand-written plugin exists with the same name, skip generation for that method. Log a NOTE diagnostic.

## Result Handling

Generated plugins use `Records.toMap(Object record)` — a runtime utility in `yaml-step-runtime`:

```java
public final class Records {
    public static Map<String, Object> toMap(Object record) {
        // Uses java.lang.reflect.RecordComponent
        // Recursively flattens nested records
        // Returns simple Map<String, Object>
    }
}
```

| Return type | Generated code |
|-------------|----------------|
| Record type | `Result.of(Records.toMap(result))` |
| `boolean` | `Result.of(Map.of("result", result))` |
| `String` | `Result.of(Map.of("result", result))` |
| Primitive wrapper | `Result.of(Map.of("result", result))` |
| `void` | `Result.of(Map.of())` |
| `List<T>` where T is a record | `Result.of(Map.of("items", result.stream().map(Records::toMap).toList()))` |
| `Page<T>` | `Result.of(Map.of("items", ..., "cursor", ..., "hasMore", ...))` |

## Error Handling

Generated plugins do NOT catch SPI exceptions. Exceptions propagate to the step runner, which wraps them into step failure results uniformly. This matches the existing hand-written plugin convention (`BankBalancePlugin` has no try-catch).

## What Is NOT Generated

- Methods on classes without `@McpDomain`
- Methods without `@PlatformQuery` or `@PlatformMutation`
- Methods annotated with `@GeneratePlugin(exclude = true)`
- Methods whose plugin name matches an existing hand-written `@Plugin`
- Methods where SPI type inference fails (connector classes only) — compile error
- Methods where capability accessor verification fails — compile error

Processing plugins with no MCP equivalent (AudioPlugin, AudioDenoisePlugin, SpeakerPlugin) remain hand-written — they have no `@PlatformQuery`/`@PlatformMutation` annotation.

## Generated Code Examples

### Streaming mutation — voice speak

```java
@Plugin(value = "voice-speak", streaming = true,
        description = "Synthesise text to speech audio")
public record VoiceSpeakPlugin(
        @Required String text,
        @Optional String voice,
        @Optional String language,
        @Optional String audioFormat,
        @Optional boolean includePhonemes) {

    @Execute
    public Result execute(VoicePlatform spi) {
        var result = spi.textToSpeech()
                .synthesise(text, new SynthesisOptions(voice, language, audioFormat, includePhonemes));
        return Result.of(Records.toMap(result));
    }
}
```

### Mutation with complex type — bank payment

```java
@Plugin(value = "bank-initiate-payment", description = "Initiate a payment")
public record BankInitiatePaymentPlugin(
        @Required PaymentRequest payment,
        @Optional String userId) {

    @Execute
    public Result execute(BankPlatform spi) {
        var result = spi.paymentInitiation(userId != null ? userId : "user-1")
                .initiatePayment(payment);
        return Result.of(Records.toMap(result));
    }
}
```

### Platform interface — notification query

```java
@Plugin(value = "notifications-find", description = "Find notifications for a user")
public record NotificationsFindPlugin(
        @Required String userId,
        @Required String tenancyId,
        @Optional String status,
        @Optional String category,
        @Optional String cursor,
        @Optional Integer limit) {

    @Execute
    public Result execute(NotificationStore store) {
        var query = new NotificationQuery(userId, tenancyId,
                status != null ? NotificationStatus.valueOf(status) : null,
                category, cursor, limit != null ? limit : 50);
        var result = store.find(query);
        return Result.of(Records.toMap(result));
    }
}
```

## Testing Strategy

### 1. Generator tests (graphql-generator/src/test/)

Compile-testing with `javax.tools.JavaCompiler` — feed mock `@McpDomain` types to the processor, assert generated plugin source matches expected output. Test cases:
- Simple query (interface method → direct delegation)
- Connector method with pluginCapability
- Streaming mutation
- Complex type parameter
- Skip detection (existing hand-written plugin)
- pluginName/pluginAbsorb/pluginSubject overrides
- @GeneratePlugin fallback annotation
- Compile error on failed SPI inference
- Compile error on failed accessor verification

### 2. APT chain test (connectors module)

Verify the two-round processing chain: `GraphQLResolverProcessor` generates `@Plugin` records → `StepPluginProcessor` emits JSON Schema + Action classes. Assert artifacts exist in `META-INF/yaml-plugins/`.

### 3. Plugin runtime tests (connectors module)

`.test.yaml` files exercising generated plugins with mock SPI implementations registered in `yaml-services.yaml`. Validates: YAML step → generated Action → generated Plugin record → SPI call → result flatten.

### 4. Records.toMap() tests (yaml-step-runtime)

Unit tests for the flatten utility: simple records, nested records, records with lists, null handling, non-record types.

## Scale

Generates plugins for all 13 connector platform SPIs (60-80 operations) plus platform interface methods across `@McpDomain` interfaces in platform-api. Total coverage: potentially 100+ generated plugins.

## Migration

Existing hand-written plugins with MCP equivalents (bank-balance, chat-send, email-messages, tts-synthesise, stt-transcribe) can be deleted once the generated equivalents produce identical YAML surfaces. Migration is per-plugin: verify the generated plugin name, parameter names, and absorb/subject behavior match the hand-written version before deleting.

## References

- `graphql-generator/src/main/java/.../GraphQLResolverProcessor.java` — APT extension point (line 141 per-domain loop)
- `yaml-plugin-api/src/main/java/.../Plugin.java` — @Plugin annotation contract
- `yaml-plugin-processor/src/main/java/.../StepPluginProcessor.java` — downstream processor for generated @Plugin records
- `mcp-api/src/main/java/.../PlatformQuery.java` — annotation to extend
- `mcp-api/src/main/java/.../PlatformMutation.java` — annotation to extend
- `connectors/graphql/src/main/java/.../ConnectorBankApi.java` — representative connector API
- `connectors/bank-spi/src/main/java/.../BankBalancePlugin.java` — existing hand-written plugin
- `connectors/graphql/src/main/java/.../ConnectorVoiceApi.java` — complex connector pattern (multi-service, streaming)
- casehubio/platform#795 — tracking issue
