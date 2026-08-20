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
| D3 | SPI shape | `McpResourceRegistry` with `newResource(descriptor)` → builder → `register()` → `McpResourceHandle` |
| D4 | Resource type representation | Sealed `McpResourceDescriptor` with `StaticResourceDescriptor` / `TemplateResourceDescriptor` records |
| D5 | Branch scope | SPI + bridge + domain metadata resources + tests. IoT deferred to iot#77 |
| D6 | Template completions | Via `.completion(argName, supplier)` calls on the registration builder |
| D7 | EndpointRegistry divergence | MCP resource contribution uses `McpResourceRegistry`, not `EndpointRegistry` |
| D8 | Server scoping | Config-driven default with optional per-resource `.serverName()` override on builder |
| D9 | Notification model | Push-only — no subscriber awareness in SPI |

## 3. Changes

### 3.1 platform-api — SPI types

Package: `io.casehub.platform.api.mcp`

**`McpResourceDescriptor`** — sealed interface with two record implementations:

```java
public sealed interface McpResourceDescriptor
        permits StaticResourceDescriptor, TemplateResourceDescriptor {

    String name();
    String mimeType();
    String description();
    boolean subscribable();

    static StaticResourceDescriptor of(
            String name, String uri, String mimeType, String description) {
        return new StaticResourceDescriptor(name, uri, mimeType, description, false);
    }

    static TemplateResourceDescriptor template(
            String name, String uriTemplate, String mimeType, String description) {
        return new TemplateResourceDescriptor(name, uriTemplate, mimeType, description, false);
    }
}

public record StaticResourceDescriptor(
    String name, String uri, String mimeType, String description, boolean subscribable
) implements McpResourceDescriptor {
    public StaticResourceDescriptor {
        Objects.requireNonNull(name, "name");
        Objects.requireNonNull(uri, "uri");
        Objects.requireNonNull(description, "description");
    }

    public StaticResourceDescriptor withSubscribable(boolean subscribable) {
        return new StaticResourceDescriptor(name, uri, mimeType, description, subscribable);
    }
}

public record TemplateResourceDescriptor(
    String name, String uriTemplate, String mimeType, String description, boolean subscribable
) implements McpResourceDescriptor {
    public TemplateResourceDescriptor {
        Objects.requireNonNull(name, "name");
        Objects.requireNonNull(uriTemplate, "uriTemplate");
        Objects.requireNonNull(description, "description");
    }

    public TemplateResourceDescriptor withSubscribable(boolean subscribable) {
        return new TemplateResourceDescriptor(name, uriTemplate, mimeType, description, subscribable);
    }
}
```

Sealed hierarchy gives compile-time field safety (`StaticResourceDescriptor.uri()` vs
`TemplateResourceDescriptor.uriTemplate()`), exhaustiveness checking on switch, and
prevents invalid states. `mimeType` is nullable — when null, the bridge omits it from
the quarkus registration (the MCP protocol treats mimeType as optional).

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
    McpResourceContent read(McpResourceReadRequest request) throws Exception;
}
```

Blocking. `throws Exception` permits handlers to call methods like
`ObjectMapper.writeValueAsString()` without wrapping. The bridge adapter
catches all exceptions: `IllegalArgumentException` returns an MCP error
response; unexpected exceptions are logged and returned as MCP error
responses. This matches `DynamicToolRegistrar`'s error handling pattern.
The bridge wraps handlers with `setHandler(fn, true)` to run on a virtual
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
completion registrations. Idempotent — calling `deregister()` twice is a no-op
on the second call. After `deregister()`, `notifyUpdate()` is a no-op.
`McpResourceRegistry.deregister(name)` invalidates any outstanding handle for
that name — the handle's subsequent operations become no-ops.

**`McpResourceRegistry`** — SPI interface:

```java
public interface McpResourceRegistry {
    McpResourceRegistration newResource(McpResourceDescriptor descriptor);

    void deregister(String name);

    Optional<McpResourceDescriptor> resolve(String name);

    List<McpResourceDescriptor> list();
}
```

**`McpResourceRegistration`** — builder for registration-time concerns:

```java
public interface McpResourceRegistration {
    McpResourceRegistration handler(McpResourceHandler handler);
    McpResourceRegistration completion(String argumentName,
                                       Supplier<List<String>> values);
    McpResourceRegistration serverName(String serverName);
    McpResourceHandle register();
}
```

`newResource(descriptor)` creates a registration builder. `.handler(h)` sets
the content handler (required — `register()` throws if omitted).
`.completion(argName, supplier)` adds per-variable template completions
(optional, repeatable). `.serverName(name)` overrides the default MCP server
(optional — defaults to bridge config). `.register()` completes registration,
fires `McpResourceRegistered` event, and returns the handle.

`deregister(String name)` removes by resource name. No-op if not found.
`resolve(String name)` and `list()` return descriptors only (not handlers) —
for introspection and discovery.

Builder pattern parallels `ResourceManager.newResource(name).setUri(...).register()`
and `ToolManager.newTool(name).setHandler(...).register()` from quarkus-mcp-server.

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

**`McpResourceUpdated`** — CDI event for decoupled notification:

```java
public record McpResourceUpdated(String uri) {
    public McpResourceUpdated {
        Objects.requireNonNull(uri, "uri");
    }
}
```

Domain repos that cannot hold a `McpResourceHandle` reference (e.g., the data
producer is in a different CDI bean from the registrar) fire this event instead.
The bridge observes `@ObservesAsync McpResourceUpdated` and delegates to the
appropriate handle's `notifyUpdate(uri)`. If no resource is registered for the
URI, the event is silently ignored.

Both notification paths coexist — `handle.notifyUpdate(uri)` for the co-located
case (more efficient, no CDI overhead) and `McpResourceUpdated` event for the
decoupled case.

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
    public McpResourceRegistration newResource(McpResourceDescriptor d) {
        return new NoOpRegistration();
    }

    @Override
    public void deregister(String name) {}

    @Override
    public Optional<McpResourceDescriptor> resolve(String name) {
        return Optional.empty();
    }

    @Override
    public List<McpResourceDescriptor> list() { return List.of(); }

    private static class NoOpRegistration implements McpResourceRegistration {
        @Override public McpResourceRegistration handler(McpResourceHandler h) { return this; }
        @Override public McpResourceRegistration completion(String n, Supplier<List<String>> v) { return this; }
        @Override public McpResourceRegistration serverName(String n) { return this; }
        @Override public McpResourceHandle register() { return NOOP_HANDLE; }
    }
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

0. **Guard:** If `descriptor.subscribable()` is `true`, throw
   `IllegalArgumentException` — quarkus-mcp-server 1.11.1 does not support
   `resources/subscribe` on template-resolved URIs. Advertising subscribability
   on a template would be a protocol-level lie. Domains needing subscription
   on template-resolved URIs should register individual STATIC resources.
1. Call `resourceTemplateManager.newResourceTemplate(descriptor.name())`
2. `.setUriTemplate(descriptor.uriTemplate())`
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
        String mime = content.mimeType() != null
                ? content.mimeType() : descriptor.mimeType();
        return new ResourceResponse(
            new TextResourceContents(content.uri(), content.text(), mime));
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
        String mime = content.mimeType() != null
                ? content.mimeType() : descriptor.mimeType();
        return new ResourceResponse(
            new TextResourceContents(content.uri(), content.text(), mime));
    };
}
```

**Handle implementation:**

For STATIC resources, `notifyUpdate(uri)` delegates to
`ResourceInfo.sendUpdateAndForget()`. The URI parameter is validated against
the registered URI.

For TEMPLATE resources, `notifyUpdate(uri)` is a **known limitation** of
quarkus-mcp-server 1.11.1. The `ResourceManagerImpl.subscribe()` method
requires `getResource(uri)` to return a statically registered resource.
Template-resolved URIs (e.g., `iot://devices/123/state`) are not in the
`uriToResource` map — they're resolved dynamically by the template manager
at read time. This means clients **cannot subscribe** to template-resolved
URIs in quarkus-mcp-server 1.11.1.

For STATIC resources with `subscribable=true`, notifications work correctly:
`handle.notifyUpdate(descriptor.uri())` delegates to
`ResourceInfo.sendUpdateAndForget()`, which sends
`notifications/resources/updated` to all subscribers of that URI.

For TEMPLATE resources, the handle's `notifyUpdate(uri)` is a no-op in this
implementation. When quarkus-mcp-server adds template subscription support
(or we contribute a fix upstream), the bridge can be updated to delegate.
Until then, domains needing subscription on template-resolved URIs should
register individual STATIC resources instead of a TEMPLATE.

This limitation does not block any in-scope consumer: domain metadata is
`subscribable=false`. The IoT consumer (iot#77) will need to evaluate
whether to register one STATIC resource per device or wait for upstream
template subscription support.

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
        resourceRegistry.newResource(McpResourceDescriptor.of(
                "casehub-domain-index",
                "casehub://domain-index",
                "application/json",
                "Lists all CaseHub domains with summaries and operation counts"))
            .handler(request -> {
                var domains = modelRegistry.getDomains().stream()
                    .map(this::domainSummary)
                    .toList();
                String json = mapper.writeValueAsString(Map.of("domains", domains));
                return McpResourceContent.of(request.uri(), json, "application/json");
            })
            .register();

        // 2. Register per-domain template with completions
        resourceRegistry.newResource(McpResourceDescriptor.template(
                "casehub-domains",
                "casehub://domains/{domain}",
                "application/json",
                "Domain detail: operations, params, state, events"))
            .handler(request -> {
                String domainName = request.templateArgs().get("domain");
                var domain = modelRegistry.getDomain(domainName)
                    .orElseThrow(() -> new IllegalArgumentException(
                        "Unknown domain: " + domainName));
                String json = mapper.writeValueAsString(domainDetail(domain));
                return McpResourceContent.of(request.uri(), json, "application/json");
            })
            .completion("domain", () -> modelRegistry.getDomains().stream()
                .map(DomainModel::name).toList())
            .register();
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
- `McpResourceDescriptor` (sealed: `StaticResourceDescriptor`,
  `TemplateResourceDescriptor`), `McpResourceReadRequest`, `McpResourceContent`,
  `McpResourceHandler`, `McpResourceHandle`, `McpResourceRegistry`,
  `McpResourceRegistration`, `McpResourceRegistered`, `McpResourceUpdated`
  in `platform-api`
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
- Template subscription workaround — quarkus-mcp-server 1.11.1 does not
  support `resources/subscribe` on template-resolved URIs. File upstream
  issue when IoT consumer needs it. Workaround: register individual STATIC
  resources per entity
- Path-based resource discovery (issue #241 requirement #2) — MCP resources
  use URI-based discovery natively via `resources/list` and
  `resources/templates/list`. The platform's `Path` hierarchy is designed
  for endpoint routing, not MCP resource organization. If Path-based
  organization is needed in the future (e.g., grouping resources by domain
  path prefix), it can be layered on top of the URI scheme without SPI
  changes. Deferred — no current consumer needs it

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
and `ResourceTemplateCompletionManager` are all in
`quarkus-mcp-server-core` 1.11.1. Notifications use
`ResourceInfo.sendUpdateAndForget()` — no `NotificationManager` needed.

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
        McpResourceRegistry (SPI: newResource/deregister/resolve/list),
        McpResourceRegistration (builder: handler/completion/serverName/register),
        McpResourceRegistered (CDI event record: descriptor),
        McpResourceUpdated (CDI event record: uri — decoupled notification relay)
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
