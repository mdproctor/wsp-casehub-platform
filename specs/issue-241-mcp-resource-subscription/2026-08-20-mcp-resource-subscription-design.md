# MCP Resource Subscription and Notification Infrastructure — Design Spec

**Issue:** casehubio/platform#241
**Date:** 2026-08-20
**Status:** Draft
**Depends on:** #240 (dynamic MCP tool schema), #228 (MCP hierarchical model)

## 1. Problem Statement

The platform's MCP server (`@McpServer("casehub")`) supports tool discovery and
dispatch (`casehub_action`, `casehub_model`) but has no infrastructure for MCP
Resources — read-only, subscribable data that clients can browse and monitor.

`quarkus-mcp-server-core` 1.11.1 provides full resource support: `ResourceManager`,
`ResourceTemplateManager`, `ResourceTemplateCompletionManager`, and
`ResourceInfo.sendUpdateAndForget()` for push notifications. The platform needs an
SPI that lets domain repos contribute resource content through this infrastructure
without depending on quarkus-mcp-server types directly.

Two consumers are identified:
1. **Domain metadata** (from #240 design review R1-03) — `casehub://domain-index`
   and `casehub://domains/{domain}` exposing the operation catalog as resources.
   Static data, no subscription needed initially. Validates the registration path.
2. **IoT device state** (casehubio/iot#77) — `iot://devices/{deviceId}/state`
   with subscription and push notifications on state changes. High-frequency updates.
   Deferred to iot#77 — uses the infrastructure this issue builds.

## 2. Design Decisions

| # | Decision | Choice |
|---|----------|--------|
| D1 | Resource serving direction | Platform-serves-content — domains contribute content through a platform SPI |
| D2 | SPI location | `platform-api` (`io.casehub.platform.api.mcp`) — pure Java, zero deps |
| D3 | SPI shape | `McpResourceRegistry` with `register(descriptor, handler)` returning `McpResourceHandle` |
| D4 | Resource type representation | Single `McpResourceDescriptor` record with `Kind` enum (STATIC/TEMPLATE) |
| D5 | Branch scope | SPI + bridge + domain metadata resources + tests. IoT deferred to iot#77 |
| D6 | Template completions | On the descriptor via optional `completions` parameter on `register()` |

## 3. Changes

### 3.1 platform-api — SPI types

Package: `io.casehub.platform.api.mcp`

**`McpResourceDescriptor`** — immutable record describing a resource:

```java
public record McpResourceDescriptor(
    String name,
    String uri,
    String mimeType,
    String description,
    Kind kind,
    boolean subscribable
) {
    public enum Kind { STATIC, TEMPLATE }

    public McpResourceDescriptor {
        Objects.requireNonNull(name, "name");
        Objects.requireNonNull(uri, "uri");
        Objects.requireNonNull(description, "description");
        Objects.requireNonNull(kind, "kind");
    }

    public static McpResourceDescriptor of(
            String name, String uri, String mimeType, String description) {
        return new McpResourceDescriptor(name, uri, mimeType, description,
                Kind.STATIC, false);
    }

    public static McpResourceDescriptor template(
            String name, String uriTemplate, String mimeType, String description) {
        return new McpResourceDescriptor(name, uriTemplate, mimeType, description,
                Kind.TEMPLATE, false);
    }

    public McpResourceDescriptor withSubscribable(boolean subscribable) {
        return new McpResourceDescriptor(name, uri, mimeType, description,
                kind, subscribable);
    }
}
```

`mimeType` is nullable — when null, the bridge omits it from the quarkus
registration (the MCP protocol treats mimeType as optional).

**`McpResourceReadRequest`** — input to the handler:

```java
public record McpResourceReadRequest(
    String uri,
    Map<String, String> templateArgs
) {
    public McpResourceReadRequest {
        Objects.requireNonNull(uri, "uri");
        templateArgs = templateArgs != null ? Map.copyOf(templateArgs) : Map.of();
    }

    public static McpResourceReadRequest of(String uri) {
        return new McpResourceReadRequest(uri, Map.of());
    }
}
```

For STATIC resources, `templateArgs` is empty. For TEMPLATE resources, it contains
the resolved template variables (e.g., `{"domain": "cases"}`).

**`McpResourceContent`** — handler return value:

```java
public record McpResourceContent(
    String uri,
    String text,
    String mimeType
) {
    public McpResourceContent {
        Objects.requireNonNull(uri, "uri");
        Objects.requireNonNull(text, "text");
    }

    public static McpResourceContent of(String uri, String text) {
        return new McpResourceContent(uri, text, null);
    }

    public static McpResourceContent of(String uri, String text, String mimeType) {
        return new McpResourceContent(uri, text, mimeType);
    }
}
```

`uri` is included because the MCP protocol requires `TextResourceContents` to carry
the resolved URI. `mimeType` is nullable — falls back to the descriptor's mimeType
when null.

**`McpResourceHandler`** — functional interface:

```java
@FunctionalInterface
public interface McpResourceHandler {
    McpResourceContent read(McpResourceReadRequest request);
}
```

Blocking. The bridge wraps this with `setHandler(fn, true)` to run on a virtual
thread, avoiding event-loop blocking.

**`McpResourceHandle`** — returned from registration:

```java
public interface McpResourceHandle {
    void notifyUpdate(String uri);
    void deregister();
}
```

`notifyUpdate(String uri)` sends `notifications/resources/updated` to all
subscribers of the given URI. For STATIC resources, the URI is the descriptor's
literal URI. For TEMPLATE resources, it's a resolved URI (e.g.,
`iot://devices/123/state`).

`deregister()` removes the resource from the MCP server and cleans up any
completion registrations.

**`McpResourceRegistry`** — SPI interface:

```java
public interface McpResourceRegistry {
    McpResourceHandle register(McpResourceDescriptor descriptor,
                               McpResourceHandler handler);

    McpResourceHandle register(McpResourceDescriptor descriptor,
                               McpResourceHandler handler,
                               Map<String, Supplier<List<String>>> completions);

    void deregister(String name);

    Optional<McpResourceDescriptor> resolve(String name);

    List<McpResourceDescriptor> list();
}
```

The two-arg `register()` is for resources without completions (static resources
and templates that don't need argument completion). The three-arg overload adds
completions for template variables — each map entry is variable name →
supplier of valid values.

`deregister(String name)` removes by resource name. No-op if not found.
`resolve(String name)` and `list()` return descriptors only (not handlers) —
for introspection and discovery.

**`McpResourceRegistered`** — CDI event record:

```java
public record McpResourceRegistered(McpResourceDescriptor descriptor) {
    public McpResourceRegistered {
        Objects.requireNonNull(descriptor, "descriptor");
    }
}
```

Fired by non-no-op implementations via `fireAsync()` after successful
registration. Follows the `EndpointRegistered` pattern.

### 3.2 platform/ — NoOp default

**`NoOpMcpResourceRegistry @DefaultBean`** in `platform/`:

```java
@DefaultBean
@ApplicationScoped
public class NoOpMcpResourceRegistry implements McpResourceRegistry {
    private static final McpResourceHandle NOOP_HANDLE = new McpResourceHandle() {
        @Override public void notifyUpdate(String uri) {}
        @Override public void deregister() {}
    };

    @Override
    public McpResourceHandle register(McpResourceDescriptor d, McpResourceHandler h) {
        return NOOP_HANDLE;
    }

    @Override
    public McpResourceHandle register(McpResourceDescriptor d, McpResourceHandler h,
                                       Map<String, Supplier<List<String>>> c) {
        return NOOP_HANDLE;
    }

    @Override
    public void deregister(String name) {}

    @Override
    public Optional<McpResourceDescriptor> resolve(String name) {
        return Optional.empty();
    }

    @Override
    public List<McpResourceDescriptor> list() { return List.of(); }
}
```

Active when `mcp/` is not on the classpath. Silent no-op — does not fire
`McpResourceRegistered`. Consistent with `NoOpEndpointRegistry` pattern.

### 3.3 mcp/ — McpResourceRegistryBridge

**`McpResourceRegistryBridge @ApplicationScoped`** implements `McpResourceRegistry`.
Beats `@DefaultBean` by CDI precedence (regular `@ApplicationScoped` always wins
over `@DefaultBean`).

```java
@ApplicationScoped
public class McpResourceRegistryBridge implements McpResourceRegistry {

    @Inject ResourceManager resourceManager;
    @Inject ResourceTemplateManager resourceTemplateManager;
    @Inject ResourceTemplateCompletionManager completionManager;
    @Inject Event<McpResourceRegistered> registeredEvent;

    @ConfigProperty(name = "casehub.mcp.server-name", defaultValue = "casehub")
    String serverName;

    private final ConcurrentMap<String, Registration> registrations =
            new ConcurrentHashMap<>();

    // ...
}
```

**Registration flow (STATIC):**

1. Call `resourceManager.newResource(descriptor.name())`
2. `.setUri(descriptor.uri())`
3. `.setTitle(descriptor.description())` — MCP uses "title" as display name
4. `.setMimeType(descriptor.mimeType())` if non-null
5. `.setDescription(descriptor.description())`
6. `.setServerName(serverName)`
7. `.setHandler(adaptStaticHandler(handler), true)` — virtual thread
8. `.register()` → returns `ResourceInfo`
9. Store in `registrations` map
10. Fire `McpResourceRegistered` via `fireAsync()`
11. Return `McpResourceHandle` wrapping the `ResourceInfo`

**Registration flow (TEMPLATE):**

1. Call `resourceTemplateManager.newResourceTemplate(descriptor.name())`
2. `.setUriTemplate(descriptor.uri())`
3. `.setTitle(descriptor.description())`
4. `.setMimeType(descriptor.mimeType())` if non-null
5. `.setDescription(descriptor.description())`
6. `.setServerName(serverName)`
7. `.setHandler(adaptTemplateHandler(handler), true)` — virtual thread
8. `.register()` → returns `ResourceTemplateInfo`
9. Register completions if provided:
   ```java
   for (var entry : completions.entrySet()) {
       completionManager.newCompletion(descriptor.name())
           .setArgumentName(entry.getKey())
           .setServerName(serverName)
           .setHandler(args -> {
               List<String> values = entry.getValue().get();
               String prefix = args.argumentValue();
               if (prefix != null && !prefix.isEmpty()) {
                   values = values.stream()
                       .filter(v -> v.startsWith(prefix))
                       .toList();
               }
               return CompletionResponse.create(values);
           })
           .register();
   }
   ```
10. Store in `registrations` map
11. Fire `McpResourceRegistered` via `fireAsync()`
12. Return `McpResourceHandle`

**Handler adaptation:**

Static handler adapter — converts `ResourceArguments` to `McpResourceReadRequest`:
```java
private Function<ResourceArguments, ResourceResponse> adaptStaticHandler(
        McpResourceHandler handler) {
    return args -> {
        var request = McpResourceReadRequest.of(args.requestUri().value());
        var content = handler.read(request);
        return new ResourceResponse(
            new TextResourceContents(content.uri(), content.text(),
                content.mimeType()));
    };
}
```

Template handler adapter — extracts template args from `ResourceTemplateArguments`:
```java
private Function<ResourceTemplateArguments, ResourceResponse> adaptTemplateHandler(
        McpResourceHandler handler) {
    return args -> {
        var request = new McpResourceReadRequest(
            args.requestUri().value(), args.args());
        var content = handler.read(request);
        return new ResourceResponse(
            new TextResourceContents(content.uri(), content.text(),
                content.mimeType()));
    };
}
```

**Handle implementation:**

For STATIC resources, `notifyUpdate(uri)` delegates to
`ResourceInfo.sendUpdateAndForget()`. The URI parameter is validated against
the registered URI.

For TEMPLATE resources, `notifyUpdate(uri)` needs the `ResourceManager` to
look up the dynamically-resolved resource. Since quarkus-mcp-server's
`ResourceManagerImpl.sendUpdateNotifications()` works by URI lookup in its
subscriber map, and template-resolved URIs are tracked there, the bridge calls
`resourceManager.getResource(uri)` and then `sendUpdateAndForget()` on the
result. If no resource exists for that URI (no subscriber), this is a no-op.

**Deregistration:**

`handle.deregister()` calls `resourceManager.removeResource(uri)` (for STATIC)
or `resourceTemplateManager.removeResourceTemplate(name)` (for TEMPLATE) +
`completionManager.removeCompletion(...)` for associated completions. Removes
from the internal `registrations` map.

### 3.4 DomainResourceRegistrar — domain metadata as resources

**`DomainResourceRegistrar @ApplicationScoped`** in `mcp/` module. Observes
`ModelScanComplete` (the same CDI event that triggers `DynamicToolRegistrar`).

```java
@ApplicationScoped
public class DomainResourceRegistrar {

    @Inject McpResourceRegistry resourceRegistry;
    @Inject ModelRegistry modelRegistry;

    private final ObjectMapper mapper;

    public DomainResourceRegistrar() {
        this.mapper = new ObjectMapper();
        this.mapper.registerModule(new JavaTimeModule());
    }

    void onScanComplete(@Observes ModelScanComplete event) {
        // 1. Register domain index (static resource)
        resourceRegistry.register(
            McpResourceDescriptor.of(
                "casehub-domain-index",
                "casehub://domain-index",
                "application/json",
                "Lists all CaseHub domains with summaries and operation counts"),
            request -> {
                var domains = modelRegistry.getDomains().stream()
                    .map(this::domainSummary)
                    .toList();
                String json = mapper.writeValueAsString(Map.of("domains", domains));
                return McpResourceContent.of(request.uri(), json, "application/json");
            });

        // 2. Register per-domain template with completions
        resourceRegistry.register(
            McpResourceDescriptor.template(
                "casehub-domains",
                "casehub://domains/{domain}",
                "application/json",
                "Domain detail: operations, params, state, events"),
            request -> {
                String domainName = request.templateArgs().get("domain");
                var domain = modelRegistry.getDomain(domainName)
                    .orElseThrow(() -> new IllegalArgumentException(
                        "Unknown domain: " + domainName));
                String json = mapper.writeValueAsString(domainDetail(domain));
                return McpResourceContent.of(request.uri(), json, "application/json");
            },
            Map.of("domain", () -> modelRegistry.getDomains().stream()
                .map(DomainModel::name).toList()));
    }

    // domainSummary() and domainDetail() produce the same JSON structure
    // as CaseHubMcpTools.buildTier0() and buildTier1() respectively.
    // The logic is extracted to shared methods (or reused from CaseHubMcpTools).
}
```

Content format matches `casehub_model` output — the domain index resource
returns the same JSON as `casehub_model` with no domain argument, and the
per-domain resource returns the same JSON as `casehub_model` with a domain
argument. This gives MCP clients two equivalent paths to the same data:
tool-based navigation via `casehub_model` or resource browsing via
`casehub://domains/*`.

### 3.5 Shared content formatting

`CaseHubMcpTools.buildTier0()` and `buildTier1()` currently produce domain
catalog JSON. `DomainResourceRegistrar` needs the same output. Rather than
duplicating the formatting logic, extract it to a shared utility:

**`DomainContentFormatter`** in `mcp/` module — package-private, stateless,
takes `DomainModel` / `List<DomainModel>` and returns `Map<String, Object>`:

```java
final class DomainContentFormatter {
    static Map<String, Object> formatIndex(List<DomainModel> domains) { ... }
    static Map<String, Object> formatDomain(DomainModel domain) { ... }
}
```

`CaseHubMcpTools` and `DomainResourceRegistrar` both delegate to this formatter.
No duplication.

## 4. Scope Boundaries

### In scope

**Batch 1 — SPI and bridge:**
- `McpResourceDescriptor`, `McpResourceReadRequest`, `McpResourceContent`,
  `McpResourceHandler`, `McpResourceHandle`, `McpResourceRegistry`,
  `McpResourceRegistered` in `platform-api`
- `NoOpMcpResourceRegistry @DefaultBean` in `platform/`
- `McpResourceRegistryBridge @ApplicationScoped` in `mcp/`
- Tests for SPI types, NoOp, and bridge

**Batch 2 — Domain metadata resources:**
- `DomainResourceRegistrar` in `mcp/`
- `DomainContentFormatter` extraction from `CaseHubMcpTools`
- `casehub://domain-index` static resource
- `casehub://domains/{domain}` template resource with completions
- Tests for resource registration, content, and completions

### Not in scope

- IoT consumer (iot#77) — separate repo, separate issue
- Runtime re-registration on hot deploy — future work
- Binary resource content (BlobResourceContents) — text-only for now
- MCP resource listing aggregation across remote MCP servers — out of scope
  (D1: platform serves content, does not proxy)
- Resource-level access control — no tenant-scoping on resources yet
- Subscription-based notification for domain metadata (subscribable=false) —
  domain catalog is static after startup

## 5. Testing Strategy

| Layer | Approach |
|-------|----------|
| `McpResourceDescriptor` | Unit — factory methods, validation, wither |
| `McpResourceReadRequest` | Unit — defensive copy, null handling |
| `McpResourceContent` | Unit — factory methods, null mimeType |
| `NoOpMcpResourceRegistry` | Unit — verify no-op behavior, handle operations |
| `McpResourceRegistryBridge` | Integration (`@QuarkusTest`) — verify resource registered with ResourceManager, handler dispatch, completions, deregistration, CDI event fired |
| `McpResourceRegistryBridge` subscription | Integration — register subscribable resource, call `notifyUpdate()`, verify notification sent |
| `DomainResourceRegistrar` | Integration — verify resources registered after `ModelScanComplete`, content matches `casehub_model` output |
| `DomainContentFormatter` | Unit — verify JSON structure matches expected format |
| Template completions | Integration — register template with completions, verify completion values returned, prefix filtering works |

## 6. CDI Tier

| Tier | Bean | Annotation | Module |
|------|------|-----------|--------|
| 0 — No-op default | `NoOpMcpResourceRegistry` | `@DefaultBean` | `platform/` |
| 1 — Bridge | `McpResourceRegistryBridge` | `@ApplicationScoped` | `mcp/` |

No `@Alternative` or `@Priority` needed. Regular `@ApplicationScoped` always
wins over `@DefaultBean` — the simplest CDI displacement pattern.

## 7. Maven Changes

### platform-api/pom.xml

No dependency changes. All new types are pure Java.

### platform/pom.xml

No dependency changes. `NoOpMcpResourceRegistry` is a new source file only.

### mcp/pom.xml

No new dependencies. `mcp/` already depends on `casehub-platform-api` and
`quarkus-mcp-server-core`. `ResourceManager`, `ResourceTemplateManager`,
`ResourceTemplateCompletionManager`, and `NotificationManager` are all in
`quarkus-mcp-server-core` 1.11.1.

## 8. Document Updates

### CLAUDE.md module table

Update `mcp/` entry to include:
```
+ `McpResourceRegistryBridge @ApplicationScoped` (bridges McpResourceRegistry → quarkus ResourceManager/ResourceTemplateManager/CompletionManager, virtual-thread handlers, CDI event on registration)
+ `DomainResourceRegistrar @ApplicationScoped` (observes ModelScanComplete → registers casehub://domain-index static resource + casehub://domains/{domain} template with completions)
+ `DomainContentFormatter` (shared JSON formatting for domain catalog — used by CaseHubMcpTools and DomainResourceRegistrar)
```

Update `platform-api` package structure to include:
```
.mcp — McpDomain, ModelEnricher, PlatformQuery, PlatformMutation, CallbackEligible,
        McpResourceDescriptor (record: name, uri, mimeType, description, Kind, subscribable),
        McpResourceReadRequest (record: uri, templateArgs),
        McpResourceContent (record: uri, text, mimeType),
        McpResourceHandler (functional interface: read(McpResourceReadRequest) → McpResourceContent),
        McpResourceHandle (interface: notifyUpdate(uri), deregister()),
        McpResourceRegistry (SPI: register/register-with-completions/deregister/resolve/list),
        McpResourceRegistered (CDI event record: descriptor)
```

### ARC42STORIES.MD

- **§5 Building Block View:** Add `McpResourceRegistryBridge` and
  `DomainResourceRegistrar` to the MCP boundary container
- **§8 Crosscutting Concepts:** Note the handler adaptation pattern
  (platform → quarkus types, virtual thread execution)

### Issue #241 status table

Update rows:
```
| MCP domain metadata as resources (casehub://domains/*) | ✅ Implemented |
| MCP resource registration via platform SPI | ✅ Implemented |
| MCP resource subscription discovery | ✅ Implemented (via ResourceManager) |
| MCP notification relay (domain CDI event → client notification) | ✅ Implemented (McpResourceHandle.notifyUpdate) |
```

## References

- [DynamicToolRegistrar.java:41-74] — existing `ModelScanComplete` observer pattern
- [CaseHubMcpTools.java:33-123] — domain catalog JSON formatting (to be extracted)
- [ResourceManager.java] — quarkus-mcp-server 1.11.1 programmatic resource registration
- [ResourceTemplateManager.java] — quarkus-mcp-server 1.11.1 template registration
- [ResourceTemplateCompletionManager.java → CompletionManager.java] — quarkus-mcp-server 1.11.1 completion registration
- [ResourceManagerImpl.java:155-171] — `sendUpdateNotifications()` implementation (URI → subscriber lookup → JSON-RPC notification)
- [TextResourceContents.java] — quarkus-mcp-server text content record
- [EndpointRegistry design spec] — CDI event pattern, NoOp @DefaultBean pattern
- [#240 spec §3.5] — DomainResourceRegistrar design (domain metadata as resources)
- [#240 decisions.md] — R1-03 (runtime state → resources)
- [GitHub #241] — this issue
- [GitHub iot#77] — first external consumer (IoT device state, deferred)
- [GE-20260806-0dadb3] — dual transport (streamable HTTP + SSE) confirmed working
