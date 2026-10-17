# Standalone AgentProvider Factory — Design Spec

**Issue:** Platform#628
**Branch:** issue-628-standalone-agent-provider-factory

## Problem

Non-CDI consumers (topology integration tests, standalone tools) cannot
use `AgentProvider` without reimplementing routing with raw HTTP calls.
The only construction path requires CDI: `Instance<AgentBackend>` for
backend discovery, `@ApplicationScoped` for registry lifecycle,
`@ConfigMapping` for properties binding.

The manifest already declares providers and their configuration. The
classpath already declares which backend implementations are available.
Consumer code should not duplicate either.

## Design

### Consumer API

One line. No backend classes, registries, or manifest types visible:

```java
var provider = RoutingAgentProvider.discover(projectDir);
provider.invoke(AgentSessionConfig.of(system, user));
```

With requirements (tier, capability, locality):

```java
provider.invoke(AgentSessionConfig.builder()
    .modelQuery(ModelQuery.builder()
        .tier(ModelTier.FLAGSHIP)
        .requiredCapabilities(Set.of(ModelCapabilities.TOOL_USE))
        .build())
    .build());
```

With manifest alias:

```java
provider.invoke(AgentSessionConfig.builder().model("fast").build());
```

With profile selection:

```java
var provider = RoutingAgentProvider.discover(projectDir, "production");
```

### Component Changes

#### 1. `BackendProvider` SPI (new — `agent-api`)

```java
public interface BackendProvider {
    String vendorKey();
    AgentBackend create(Map<String, String> properties);
}
```

Each backend core module provides an implementation and registers it
via `META-INF/services/io.casehub.platform.agent.BackendProvider`.

SDK backends (ollama, openai, gemini) parse host/api-key/model/timeout
from the properties map. CLI backends (claude, codex, gemini-cli) create
a `SubprocessRuntime` internally for process management.

#### 2. `InMemoryBackendInstanceRegistry` extraction (`agent-router` → `agent-router-core`)

Strip `@ApplicationScoped`. Add static factory:

```java
public static InMemoryBackendInstanceRegistry of(AgentBackend... backends)
```

CDI module: `RouterBeans` produces it as `@ApplicationScoped @DefaultBean`.

No behavioral change — same ConcurrentHashMap + BackendRef key structure.

#### 3. `RoutingAgentProvider.discover()` (new — `agent-router-core`)

```java
public static RoutingAgentProvider discover(Path projectDir) {
    return discover(projectDir, null);
}

public static RoutingAgentProvider discover(Path projectDir, String profile) {
    var loader = AgentConfigLoader.withDefaults(projectDir, profile);
    var manifest = loader.load();

    var providers = ServiceLoader.load(BackendProvider.class);
    var registry = new InMemoryBackendInstanceRegistry();

    for (var entry : manifest.providers().entrySet()) {
        providers.stream()
            .map(ServiceLoader.Provider::get)
            .filter(p -> p.vendorKey().equals(entry.getKey()))
            .findFirst()
            .ifPresent(p -> registry.register(p.create(entry.getValue())));
    }

    return create(registry, manifest.defaultBackendKey(),
        loader.modelRegistry(), Optional.of(manifest));
}
```

Unresolvable providers (manifest declares a vendor with no matching
`BackendProvider` on the classpath) are logged at WARN and skipped.
The provider starts with whatever backends ARE available. This matches
CDI behavior — missing optional modules don't prevent startup.

Existing `create()` and constructor APIs remain unchanged — platform-internal
building blocks for CDI wiring and advanced composition.

#### 4. `RoutingAgentProvider.of()` escape hatches (`agent-router-core`)

For tests and programmatic wiring where manifest is not available:

```java
public static RoutingAgentProvider of(AgentBackend... backends)
public static RoutingAgentProvider of(List<AgentBackend> backends, ManifestResult manifest)
public static RoutingAgentProvider of(List<AgentBackend> backends,
    ManifestResult manifest, ModelRegistry modelRegistry)
```

These are NOT the primary consumer API. They exist for platform internals
and test harnesses that need explicit control.

#### 5. `AgentConfigLoader.withDefaults()` (new — `agent-config-core`)

```java
public static AgentConfigLoader withDefaults(Path projectDir)
public static AgentConfigLoader withDefaults(Path projectDir, String profile)
```

Creates in-memory stubs for all 9 constructor parameters:

| Parameter | Standalone Default |
|---|---|
| `LlmCredentialStore` | Package-private `MapLlmCredentialStore` (ConcurrentHashMap) |
| `MutableModelRegistry` | Package-private `MapMutableModelRegistry` (ConcurrentHashMap) |
| `CredentialResolver` | No-op `ref -> Map.of()` |
| `vendorRequirements` | Empty map |
| `LocalModelReconciler` | No-op `model -> {}` |
| `profile` | Provided (nullable) |
| `projectDir` | Provided |
| `DIDResolver` | No-op `did -> Optional.empty()` |
| `allowInsecure` | `false` |

Exposes `modelRegistry()` accessor for consumers who need the populated
registry for advanced composition.

Manifest loading preserves full `ManifestLoader` behavior: directory
hierarchy discovery, YAML merging, recursive remote source loading
with cycle detection.

#### 6. `ManifestResult` expansion (`agent-config-core`)

Add provider declarations to the record:

```java
public record ManifestResult(
    Map<String, ModelChain> aliases,
    String defaultBackendKey,
    List<PoolDeclaration> pools,
    Map<String, Map<String, String>> providers  // NEW — vendor key → properties
) {
    public static ManifestResult empty() {
        return new ManifestResult(Map.of(), null, List.of(), Map.of());
    }
}
```

`ManifestProcessor` retains provider entries (currently consumed and
discarded) in the result. Backward-compatible — existing callers use
the new constructor; the field is additive.

#### 7. `ModelRegistry.empty()` (`platform-api`)

Static factory on the SPI interface:

```java
static ModelRegistry empty() {
    return new ModelRegistry() {
        @Override public Optional<ModelDescriptor> resolveById(String id) {
            return Optional.empty();
        }
        @Override public List<ModelDescriptor> query(ModelQuery query) {
            return List.of();
        }
        @Override public List<ModelDescriptor> all() {
            return List.of();
        }
    };
}
```

Used by `of()` escape hatches when no model registry is provided.

#### 8. Route observability (`agent-api`)

Add `backendKey` and `instanceId` to `AgentEvent.InvocationComplete`:

```java
public record InvocationComplete(
    // ... existing fields ...
    String backendKey,    // NEW
    String instanceId     // NEW
) implements AgentEvent { ... }
```

Set by `RoutingAgentProvider` after resolution, before streaming.
Consumers see which backend handled each request in the terminal event.

### ServiceLoader Registrations

Each backend core module adds:

| Module | Provider Class | Vendor Key |
|---|---|---|
| `agent-ollama-core` | `OllamaBackendProvider` | `"ollama"` |
| `agent-openai-core` | `OpenAiBackendProvider` | `"openai"` |
| `agent-gemini-core` | `GeminiBackendProvider` | `"gemini"` |
| `agent-claude-core` | `ClaudeBackendProvider` | `"claude"` |
| `agent-codex-core` | `CodexBackendProvider` | `"codex"` |
| `agent-gemini-cli-core` | `GeminiCliBackendProvider` | `"gemini-cli"` |
| `agent-simulation-core` | `SimulatedBackendProvider` | `"simulation"` |

Each provider implements `BackendProvider`, parses its properties from
`Map<String, String>`, and creates the corresponding `AgentBackend`.

CLI backends (claude, codex, gemini-cli) create a `SubprocessRuntime`
internally — the consumer never manages process lifecycle.

### CDI Module Impact

Existing CDI modules are unchanged. The new standalone path is additive:

- `RouterBeans` still produces `InMemoryBackendInstanceRegistry` and
  `RoutingAgentProvider` via CDI injection
- `BackendInstanceCoordinator` still uses `Instance<AgentBackend>` for
  CDI discovery
- `AgentConfigBeans` still uses `@ConfigMapping` and CDI startup

The CDI path and standalone path share core classes but have independent
construction: CDI uses container injection, standalone uses
`discover()` + ServiceLoader.

### What This Does NOT Change

- `BackendInstanceRegistry` SPI stays in `agent-api` — justified by
  shared read contract (RoutingAgentProvider + SessionPoolRegistry)
- `BackendInstanceCoordinator` stays in `agent-router` — CDI-specific
  backend discovery unchanged
- `AgentConfigLoader` 9-arg constructor stays — `withDefaults()` is
  additive, not a replacement
- Backend core classes keep their properties-interface constructors —
  `BackendProvider` implementations use them internally

## Testing

- Unit test: `RoutingAgentProvider.discover()` with test manifest +
  mock `BackendProvider` via ServiceLoader
- Unit test: `AgentConfigLoader.withDefaults()` loads real manifest
  without CDI dependencies
- Unit test: `InMemoryBackendInstanceRegistry.of()` construction
- Unit test: `InvocationComplete` carries backendKey/instanceId
- Integration test: end-to-end standalone invocation with Ollama
  (requires Ollama running — excluded from `mvn test`, run via
  `mvn verify`)

## References

- BackendInstanceRegistry.java (agent-api) — SPI justification
- RoutingAgentProvider.java (agent-router-core) — existing create() factories
- AgentConfigLoader.java (agent-config-core) — 9-arg constructor, ManifestLoader delegation
- ManifestResult.java (agent-config-core) — record expansion
- SessionPoolRegistry.java (agent-session-core) — shared registry consumer
- BackendInstanceFactory.java (agent-api) — existing credential-driven factory pattern
- ModelQuery.java (platform-api) — requirements-based model selection
- AgentEvent.java (agent-api) — InvocationComplete record
- ManifestLoader (agent-config-core) — directory hierarchy discovery, merging, remote sources
