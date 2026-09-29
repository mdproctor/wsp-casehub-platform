# MCP Spring Server Transport Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** #472 — MCP Spring session provider — JDK HttpClient McpSessionProvider
**Issue group:** #472

**Goal:** Enable Spring Boot CaseHub apps to serve MCP tools and resources to external clients over SSE, using Spring AI MCP Server Starter.

**Architecture:** Extend `mcp-spring/` with `spring-ai-starter-mcp-server-webmvc` for SSE transport. Tools are auto-discovered via the existing `CaseHubToolCallbackProvider`. A new `SpringMcpResourceRegistryBridge` implements the `McpResourceRegistry` SPI using `McpSyncServer` for dynamic resource registration. A new `SpringDomainResourceRegistrar` listens for `ModelScanComplete` and registers domain metadata resources at startup.

**Tech Stack:** Spring AI MCP Server Starter (WebMVC SSE), MCP Java SDK 2.x, Spring Boot auto-configuration

## Global Constraints

- `mcp-spring/` is `jar` packaging, no `quarkus:build` goal
- All new classes are framework-neutral POJOs with constructor injection where possible
- Spring auto-config ordering must be explicit (`@AutoConfiguration(after = ...)`)
- `@ConditionalOnBean(McpSyncServer.class)` guards all MCP server beans — graceful degradation when starter absent
- No `synchronized` — use `java.util.concurrent` types only
- Follow existing `mcp-spring/` package: `io.casehub.platform.mcp.spring`

---

## Batch 1: MCP Server Starter dependency + resource bridge

### Task 1: Add Spring AI MCP Server Starter dependency and SpringMcpResourceRegistryBridge

**Files:**
- Modify: `mcp-spring/pom.xml`
- Create: `mcp-spring/src/main/java/io/casehub/platform/mcp/spring/SpringMcpResourceRegistryBridge.java`
- Modify: `mcp-spring/src/main/java/io/casehub/platform/mcp/spring/McpSpringAutoConfiguration.java`
- Test: `mcp-spring/src/test/java/io/casehub/platform/mcp/spring/SpringMcpResourceRegistryBridgeTest.java`

**Interfaces:**
- Consumes: `McpResourceRegistry` SPI from `platform-api`, `McpResourceDescriptor` (sealed: `StaticResourceDescriptor`, `TemplateResourceDescriptor`), `McpResourceHandle`, `McpResourceReadRequest`, `McpResourceContent`, `McpResourceRegistered`, `McpResourceUpdated` events, `McpSyncServer` from Spring AI MCP Server Starter
- Produces: `SpringMcpResourceRegistryBridge` implementing `McpResourceRegistry` — consumed by `SpringDomainResourceRegistrar` in Task 2 and any module that registers MCP resources

- [ ] **Step 1: Add Spring AI MCP Server Starter dependency to pom.xml**

Add to `mcp-spring/pom.xml` `<dependencies>` section:

```xml
<dependency>
    <groupId>org.springframework.ai</groupId>
    <artifactId>spring-ai-starter-mcp-server-webmvc</artifactId>
</dependency>
```

Verify the version is managed by the parent BOM. Run:

```bash
mvn --batch-mode -pl mcp-spring dependency:resolve -DincludeArtifactIds=spring-ai-starter-mcp-server-webmvc
```

Expected: resolves successfully. If the version is not in the BOM, add `<version>` from the Spring AI BOM in `casehub-platform-parent`.

- [ ] **Step 2: Write failing test for SpringMcpResourceRegistryBridge — static resource registration**

Create `mcp-spring/src/test/java/io/casehub/platform/mcp/spring/SpringMcpResourceRegistryBridgeTest.java`:

```java
package io.casehub.platform.mcp.spring;

import io.casehub.platform.api.mcp.McpResourceContent;
import io.casehub.platform.api.mcp.McpResourceDescriptor;
import io.casehub.platform.api.mcp.McpResourceHandle;
import io.casehub.platform.api.mcp.McpResourceRegistered;
import io.modelcontextprotocol.server.McpSyncServer;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.context.ApplicationEventPublisher;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.*;

class SpringMcpResourceRegistryBridgeTest {

    private McpSyncServer server;
    private ApplicationEventPublisher eventPublisher;
    private SpringMcpResourceRegistryBridge bridge;

    @BeforeEach
    void setUp() {
        server = mock(McpSyncServer.class);
        eventPublisher = mock(ApplicationEventPublisher.class);
        bridge = new SpringMcpResourceRegistryBridge(server, eventPublisher);
    }

    @Test
    void registerStaticResource_trackedLocally() {
        McpResourceHandle handle = bridge.newResource(McpResourceDescriptor.of(
                        "test-resource", "test://resource", "text/plain", "A test resource"))
                .handler(request -> McpResourceContent.of(request.uri(), "hello", "text/plain"))
                .register();

        assertThat(handle).isNotNull();
        assertThat(bridge.resolve("test-resource")).isPresent();
        assertThat(bridge.list()).hasSize(1);
        verify(eventPublisher).publishEvent(any(McpResourceRegistered.class));
    }

    @Test
    void deregisterResource_removedFromTracking() {
        McpResourceHandle handle = bridge.newResource(McpResourceDescriptor.of(
                        "test-resource", "test://resource", "text/plain", "A test resource"))
                .handler(request -> McpResourceContent.of(request.uri(), "hello", "text/plain"))
                .register();

        bridge.deregister("test-resource");

        assertThat(bridge.resolve("test-resource")).isEmpty();
        assertThat(bridge.list()).isEmpty();
    }

    @Test
    void deregisterViaHandle_removedFromTracking() {
        McpResourceHandle handle = bridge.newResource(McpResourceDescriptor.of(
                        "test-resource", "test://resource", "text/plain", "A test resource"))
                .handler(request -> McpResourceContent.of(request.uri(), "hello", "text/plain"))
                .register();

        handle.deregister();

        assertThat(bridge.resolve("test-resource")).isEmpty();
        assertThat(bridge.list()).isEmpty();
    }

    @Test
    void registerTemplate_trackedLocally() {
        McpResourceHandle handle = bridge.newResource(McpResourceDescriptor.template(
                        "test-template", "test://items/{id}", "application/json", "Item detail"))
                .handler(request -> McpResourceContent.of(request.uri(), "{}", "application/json"))
                .completion("id", () -> java.util.List.of("a", "b", "c"))
                .register();

        assertThat(handle).isNotNull();
        assertThat(bridge.resolve("test-template")).isPresent();
        assertThat(bridge.list()).hasSize(1);
    }

    @Test
    void registerWithoutHandler_throws() {
        var reg = bridge.newResource(McpResourceDescriptor.of(
                "test-resource", "test://resource", "text/plain", "test"));

        org.junit.jupiter.api.Assertions.assertThrows(IllegalStateException.class, reg::register);
    }
}
```

- [ ] **Step 3: Run test to verify it fails**

```bash
mvn --batch-mode -pl mcp-spring test -Dtest=SpringMcpResourceRegistryBridgeTest
```

Expected: FAIL — `SpringMcpResourceRegistryBridge` does not exist yet.

- [ ] **Step 4: Implement SpringMcpResourceRegistryBridge**

Create `mcp-spring/src/main/java/io/casehub/platform/mcp/spring/SpringMcpResourceRegistryBridge.java`:

```java
package io.casehub.platform.mcp.spring;

import io.casehub.platform.api.mcp.McpResourceDescriptor;
import io.casehub.platform.api.mcp.McpResourceHandle;
import io.casehub.platform.api.mcp.McpResourceHandler;
import io.casehub.platform.api.mcp.McpResourceReadRequest;
import io.casehub.platform.api.mcp.McpResourceRegistered;
import io.casehub.platform.api.mcp.McpResourceRegistration;
import io.casehub.platform.api.mcp.McpResourceRegistry;
import io.casehub.platform.api.mcp.McpResourceUpdated;
import io.casehub.platform.api.mcp.StaticResourceDescriptor;
import io.casehub.platform.api.mcp.TemplateResourceDescriptor;
import io.modelcontextprotocol.server.McpSyncServer;
import io.modelcontextprotocol.spec.McpSchema;
import org.springframework.context.ApplicationEventPublisher;
import org.springframework.context.event.EventListener;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ConcurrentMap;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.function.Supplier;

public class SpringMcpResourceRegistryBridge implements McpResourceRegistry {

    private static final System.Logger LOG = System.getLogger(SpringMcpResourceRegistryBridge.class.getName());

    private final McpSyncServer server;
    private final ApplicationEventPublisher eventPublisher;
    private final ConcurrentMap<String, Registration> registrations = new ConcurrentHashMap<>();

    public SpringMcpResourceRegistryBridge(McpSyncServer server,
                                            ApplicationEventPublisher eventPublisher) {
        this.server = server;
        this.eventPublisher = eventPublisher;
    }

    @Override
    public McpResourceRegistration newResource(McpResourceDescriptor descriptor) {
        return new BridgeRegistration(descriptor);
    }

    @Override
    public void deregister(String name) {
        Registration reg = registrations.remove(name);
        if (reg != null) {
            reg.invalidate();
            removeFromServer(reg);
        }
    }

    @Override
    public Optional<McpResourceDescriptor> resolve(String name) {
        Registration reg = registrations.get(name);
        return reg != null ? Optional.of(reg.descriptor) : Optional.empty();
    }

    @Override
    public List<McpResourceDescriptor> list() {
        return registrations.values().stream()
                .map(r -> r.descriptor)
                .toList();
    }

    @EventListener
    void onResourceUpdated(McpResourceUpdated event) {
        for (Registration reg : registrations.values()) {
            if (reg.descriptor instanceof StaticResourceDescriptor s
                    && s.uri().equals(event.uri())) {
                server.notifyResourcesUpdated();
                return;
            }
        }
    }

    private void removeFromServer(Registration reg) {
        try {
            switch (reg.descriptor) {
                case StaticResourceDescriptor s -> server.removeResource(s.uri());
                case TemplateResourceDescriptor t -> server.removeResourceTemplate(t.uriTemplate());
            }
        } catch (Exception e) {
            LOG.log(System.Logger.Level.WARNING, "Failed to remove MCP resource from server: {0}", reg.descriptor.name());
        }
    }

    private record Registration(
            McpResourceDescriptor descriptor,
            AtomicBoolean valid
    ) {
        void invalidate() {
            valid.set(false);
        }
    }

    private class BridgeRegistration implements McpResourceRegistration {

        private final McpResourceDescriptor descriptor;
        private McpResourceHandler handler;
        private final Map<String, Supplier<List<String>>> completions = new LinkedHashMap<>();

        BridgeRegistration(McpResourceDescriptor descriptor) {
            this.descriptor = descriptor;
        }

        @Override
        public McpResourceRegistration handler(McpResourceHandler handler) {
            this.handler = handler;
            return this;
        }

        @Override
        public McpResourceRegistration completion(String argumentName, Supplier<List<String>> values) {
            completions.put(argumentName, values);
            return this;
        }

        @Override
        public McpResourceRegistration serverName(String serverName) {
            // Spring AI MCP Server does not support multi-server scoping — ignored
            return this;
        }

        @Override
        public McpResourceHandle register() {
            if (handler == null) {
                throw new IllegalStateException("handler is required — call .handler() before .register()");
            }

            AtomicBoolean valid = new AtomicBoolean(true);

            switch (descriptor) {
                case StaticResourceDescriptor s -> registerStatic(s);
                case TemplateResourceDescriptor t -> {
                    if (t.subscribable()) {
                        throw new IllegalArgumentException(
                                "subscribable=true is not supported on template resources");
                    }
                    registerTemplate(t);
                }
            }

            registrations.put(descriptor.name(), new Registration(descriptor, valid));
            eventPublisher.publishEvent(new McpResourceRegistered(descriptor));

            LOG.log(System.Logger.Level.INFO, "Registered MCP resource: {0} ({1})",
                    descriptor.name(),
                    descriptor instanceof StaticResourceDescriptor ? "static" : "template");

            return new BridgeHandle(descriptor.name(), valid);
        }

        private void registerStatic(StaticResourceDescriptor s) {
            var resource = new McpSchema.Resource(s.uri(), s.name(), s.description(),
                    s.mimeType(), null);
            server.addResource(new io.modelcontextprotocol.spec.McpServerFeatures.SyncResourceSpecification(
                    resource,
                    (exchange, request) -> {
                        try {
                            var readRequest = McpResourceReadRequest.of(request.uri());
                            var content = handler.read(readRequest);
                            String mime = content.mimeType() != null ? content.mimeType() : s.mimeType();
                            return new McpSchema.ReadResourceResult(List.of(
                                    new McpSchema.ResourceContents.TextResourceContents(
                                            content.uri(), mime, content.text())));
                        } catch (Exception e) {
                            LOG.log(System.Logger.Level.ERROR, "MCP resource read failed: {0}", s.uri());
                            throw new RuntimeException(e.getMessage(), e);
                        }
                    }
            ));
        }

        private void registerTemplate(TemplateResourceDescriptor t) {
            var template = new McpSchema.ResourceTemplate(t.uriTemplate(), t.name(),
                    t.description(), t.mimeType(), null);
            server.addResourceTemplate(new io.modelcontextprotocol.spec.McpServerFeatures.SyncResourceTemplateSpecification(
                    template,
                    (exchange, request) -> {
                        try {
                            var readRequest = new McpResourceReadRequest(request.uri(), Map.of());
                            var content = handler.read(readRequest);
                            String mime = content.mimeType() != null ? content.mimeType() : t.mimeType();
                            return new McpSchema.ReadResourceResult(List.of(
                                    new McpSchema.ResourceContents.TextResourceContents(
                                            content.uri(), mime, content.text())));
                        } catch (Exception e) {
                            LOG.log(System.Logger.Level.ERROR, "MCP resource template read failed: {0}", t.uriTemplate());
                            throw new RuntimeException(e.getMessage(), e);
                        }
                    }
            ));
        }
    }

    private class BridgeHandle implements McpResourceHandle {

        private final String name;
        private final AtomicBoolean valid;

        BridgeHandle(String name, AtomicBoolean valid) {
            this.name = name;
            this.valid = valid;
        }

        @Override
        public void notifyUpdate(String uri) {
            if (!valid.get()) return;
            server.notifyResourcesUpdated();
        }

        @Override
        public void deregister() {
            if (!valid.compareAndSet(true, false)) return;
            SpringMcpResourceRegistryBridge.this.deregister(name);
        }
    }
}
```

**Implementation note:** The exact `McpSyncServer` API method names (`addResource`, `removeResource`, `notifyResourcesUpdated`, `McpSchema.Resource`, `McpServerFeatures.SyncResourceSpecification`) must be verified against the actual MCP Java SDK 2.x classes at compile time. The SDK types may use different names — adjust imports and constructors as needed when the dependency resolves. The structure and semantics are correct; only the exact type/method names may need adaptation.

- [ ] **Step 5: Run test to verify it passes**

```bash
mvn --batch-mode -pl mcp-spring test -Dtest=SpringMcpResourceRegistryBridgeTest
```

Expected: PASS. If compilation fails due to incorrect MCP SDK API names, read the actual SDK classes from the resolved dependency and adjust.

- [ ] **Step 6: Update McpSpringAutoConfiguration to produce the bridge bean**

Modify `McpSpringAutoConfiguration.java` — add auto-configuration ordering and bridge bean:

```java
// Add to class annotation:
@AutoConfiguration(afterName = "org.springframework.ai.autoconfigure.mcp.server.McpServerAutoConfiguration")

// Add bean method:
@Bean
@ConditionalOnBean(McpSyncServer.class)
SpringMcpResourceRegistryBridge springMcpResourceRegistryBridge(
        McpSyncServer server,
        ApplicationEventPublisher eventPublisher) {
    return new SpringMcpResourceRegistryBridge(server, eventPublisher);
}
```

Add import for `McpSyncServer` from `io.modelcontextprotocol.server`.

The `afterName` string reference avoids a compile-time dependency on the Spring AI auto-config class (it may not be on the classpath when the starter is optional).

- [ ] **Step 7: Run full mcp-spring tests**

```bash
mvn --batch-mode -pl mcp-spring test
```

Expected: all tests pass (existing `SpringModelScannerTest` + new `SpringMcpResourceRegistryBridgeTest`).

- [ ] **Step 8: Commit**

```bash
git add mcp-spring/pom.xml mcp-spring/src/main/java/io/casehub/platform/mcp/spring/SpringMcpResourceRegistryBridge.java mcp-spring/src/main/java/io/casehub/platform/mcp/spring/McpSpringAutoConfiguration.java mcp-spring/src/test/java/io/casehub/platform/mcp/spring/SpringMcpResourceRegistryBridgeTest.java
git commit -m "feat(#472): add SpringMcpResourceRegistryBridge and Spring AI MCP Server Starter dependency

Implements McpResourceRegistry SPI for Spring using McpSyncServer.
Adds spring-ai-starter-mcp-server-webmvc for SSE transport.
Tools are auto-discovered via existing CaseHubToolCallbackProvider.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

## Batch 2: Domain resource registration + integration test

### Task 2: Add SpringDomainResourceRegistrar

**Files:**
- Create: `mcp-spring/src/main/java/io/casehub/platform/mcp/spring/SpringDomainResourceRegistrar.java`
- Modify: `mcp-spring/src/main/java/io/casehub/platform/mcp/spring/McpSpringAutoConfiguration.java`
- Test: `mcp-spring/src/test/java/io/casehub/platform/mcp/spring/SpringDomainResourceRegistrarTest.java`

**Interfaces:**
- Consumes: `McpResourceRegistry` (from Task 1's `SpringMcpResourceRegistryBridge`), `DomainModelRegistry` (from `mcp-core`), `ModelScanComplete` event, `McpResourceDescriptor.of()` / `.template()`, `DomainContentFormatter`, `DomainModel`
- Produces: `SpringDomainResourceRegistrar` — registers `casehub://domain-index` static resource and `casehub://domains/{domain}` template at startup. No downstream consumers.

- [ ] **Step 1: Write failing test for SpringDomainResourceRegistrar**

Create `mcp-spring/src/test/java/io/casehub/platform/mcp/spring/SpringDomainResourceRegistrarTest.java`:

```java
package io.casehub.platform.mcp.spring;

import io.casehub.platform.api.mcp.McpResourceRegistry;
import io.casehub.platform.mcp.DomainModel;
import io.casehub.platform.mcp.DomainModelRegistry;
import io.casehub.platform.mcp.ModelScanComplete;
import org.junit.jupiter.api.Test;

import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.*;

class SpringDomainResourceRegistrarTest {

    @Test
    void onScanComplete_registersDomainIndexAndTemplate() {
        DomainModelRegistry domainRegistry = new DomainModelRegistry();
        domainRegistry.register(new DomainModel("acl", "", "Access control",
                List.of(), List.of(), java.util.Map.of()));

        McpResourceRegistry resourceRegistry = mock(McpResourceRegistry.class);
        var mockRegistration = mock(io.casehub.platform.api.mcp.McpResourceRegistration.class);
        when(resourceRegistry.newResource(any())).thenReturn(mockRegistration);
        when(mockRegistration.handler(any())).thenReturn(mockRegistration);
        when(mockRegistration.completion(any(), any())).thenReturn(mockRegistration);
        when(mockRegistration.register()).thenReturn(mock(io.casehub.platform.api.mcp.McpResourceHandle.class));

        var registrar = new SpringDomainResourceRegistrar(resourceRegistry, domainRegistry);
        registrar.onScanComplete(new ModelScanComplete());

        verify(resourceRegistry, times(2)).newResource(any());
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
mvn --batch-mode -pl mcp-spring test -Dtest=SpringDomainResourceRegistrarTest
```

Expected: FAIL — `SpringDomainResourceRegistrar` does not exist.

- [ ] **Step 3: Implement SpringDomainResourceRegistrar**

Create `mcp-spring/src/main/java/io/casehub/platform/mcp/spring/SpringDomainResourceRegistrar.java`:

```java
package io.casehub.platform.mcp.spring;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.datatype.jsr310.JavaTimeModule;
import io.casehub.platform.api.mcp.McpResourceContent;
import io.casehub.platform.api.mcp.McpResourceDescriptor;
import io.casehub.platform.api.mcp.McpResourceRegistry;
import io.casehub.platform.mcp.DomainContentFormatter;
import io.casehub.platform.mcp.DomainModel;
import io.casehub.platform.mcp.DomainModelRegistry;
import io.casehub.platform.mcp.ModelScanComplete;
import org.springframework.context.event.EventListener;

public class SpringDomainResourceRegistrar {

    private static final System.Logger LOG = System.getLogger(SpringDomainResourceRegistrar.class.getName());

    private final McpResourceRegistry resourceRegistry;
    private final DomainModelRegistry domainModelRegistry;
    private final ObjectMapper mapper;

    public SpringDomainResourceRegistrar(McpResourceRegistry resourceRegistry,
                                          DomainModelRegistry domainModelRegistry) {
        this.resourceRegistry = resourceRegistry;
        this.domainModelRegistry = domainModelRegistry;
        this.mapper = new ObjectMapper();
        this.mapper.registerModule(new JavaTimeModule());
    }

    @EventListener
    public void onScanComplete(ModelScanComplete event) {
        resourceRegistry.newResource(McpResourceDescriptor.of(
                        "casehub-domain-index",
                        "casehub://domain-index",
                        "application/json",
                        "Lists all CaseHub domains with summaries and operation counts"))
                .handler(request -> {
                    String json = mapper.writeValueAsString(
                            DomainContentFormatter.formatIndex(domainModelRegistry.getDomains()));
                    return McpResourceContent.of(request.uri(), json, "application/json");
                })
                .register();

        resourceRegistry.newResource(McpResourceDescriptor.template(
                        "casehub-domains",
                        "casehub://domains/{domain}",
                        "application/json",
                        "Domain detail: operations, params, state, events"))
                .handler(request -> {
                    String domainName = request.templateArgs().get("domain");
                    var domain = domainModelRegistry.getDomain(domainName)
                            .orElseThrow(() -> new IllegalArgumentException(
                                    "Unknown domain: " + domainName));
                    String json = mapper.writeValueAsString(
                            DomainContentFormatter.formatDomain(domain));
                    return McpResourceContent.of(request.uri(), json, "application/json");
                })
                .completion("domain", () -> domainModelRegistry.getDomains().stream()
                        .map(DomainModel::name).toList())
                .register();

        LOG.log(System.Logger.Level.INFO,
                "Registered domain metadata resources: casehub://domain-index + casehub://domains/'{domain}' ({0} domains)",
                domainModelRegistry.getDomains().size());
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
mvn --batch-mode -pl mcp-spring test -Dtest=SpringDomainResourceRegistrarTest
```

Expected: PASS.

- [ ] **Step 5: Add bean to McpSpringAutoConfiguration**

Add to `McpSpringAutoConfiguration.java`:

```java
@Bean
@ConditionalOnBean(McpSyncServer.class)
SpringDomainResourceRegistrar springDomainResourceRegistrar(
        McpResourceRegistry resourceRegistry,
        DomainModelRegistry domainModelRegistry) {
    return new SpringDomainResourceRegistrar(resourceRegistry, domainModelRegistry);
}
```

- [ ] **Step 6: Run all mcp-spring tests**

```bash
mvn --batch-mode -pl mcp-spring test
```

Expected: all tests pass.

- [ ] **Step 7: Commit**

```bash
git add mcp-spring/src/main/java/io/casehub/platform/mcp/spring/SpringDomainResourceRegistrar.java mcp-spring/src/main/java/io/casehub/platform/mcp/spring/McpSpringAutoConfiguration.java mcp-spring/src/test/java/io/casehub/platform/mcp/spring/SpringDomainResourceRegistrarTest.java
git commit -m "feat(#472): add SpringDomainResourceRegistrar for startup domain resource registration

Listens for ModelScanComplete event and registers casehub://domain-index
static resource and casehub://domains/{domain} template with completions
via McpResourceRegistry SPI.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

## Batch 3: Full build verification + CLAUDE.md update

### Task 3: Full build verification and documentation update

**Files:**
- Modify: `CLAUDE.md` (update `mcp-spring/` module description)

**Interfaces:**
- Consumes: all prior tasks
- Produces: verified build, updated documentation

- [ ] **Step 1: Run full project build**

```bash
mvn --batch-mode install
```

Expected: BUILD SUCCESS. All modules compile, all tests pass. The `spring-integration-test/` module should compose without errors (if it pulls in `mcp-spring`).

- [ ] **Step 2: Check spring-integration-test composes**

If `spring-integration-test/` has `mcp-spring` on its classpath, verify it still passes:

```bash
mvn --batch-mode -pl spring-integration-test test
```

Expected: PASS. The `@ConditionalOnBean(McpSyncServer.class)` guard means the bridge bean is not created when the MCP server starter is not on the classpath — no composition errors.

- [ ] **Step 3: Update CLAUDE.md mcp-spring module description**

Update the `mcp-spring/` row in the modules table to reflect the new capabilities. The current description mentions only tool registration. Add server transport and resource registration.

- [ ] **Step 4: Commit**

```bash
git add CLAUDE.md
git commit -m "docs(#472): update CLAUDE.md mcp-spring module description with server transport

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

## References

- [2026-09-29-mcp-spring-server-transport-design.md] — design spec this plan implements
- [mcp/src/main/java/io/casehub/platform/mcp/McpResourceRegistryBridge.java] — Quarkus bridge being mirrored
- [mcp/src/main/java/io/casehub/platform/mcp/DomainResourceRegistrar.java] — Quarkus domain registrar being mirrored
- [mcp-spring/src/main/java/io/casehub/platform/mcp/spring/McpSpringAutoConfiguration.java] — auto-config to extend
- [mcp-spring/src/main/java/io/casehub/platform/mcp/spring/CaseHubToolCallbackProvider.java] — existing tool integration
- [platform-api io.casehub.platform.api.mcp] — McpResourceRegistry SPI
- [GitHub #472] — focal issue
- [decisions.md D1-D4] — design decisions
