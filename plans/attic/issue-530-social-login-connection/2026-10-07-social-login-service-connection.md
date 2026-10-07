# Social Login → Service Connection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** #530 — Link social login to service connection
**Issue group:** #530

**Goal:** Add a `ServiceConnectionProvider` SPI to platform-api and implement it in authn-social-core, enabling downstream modules to query service connection status and obtain valid access tokens from social login OAuth flows.

**Architecture:** Derived view over existing `OAuthTokenStore` + `ScopeRegistry` + `OAuthTokenManagerCore`. No new persistence. `ScopeMergingLoginCustomizer` merges service scopes into the social login flow via `AuthenticationRouterCore`. `access_type=offline` ensures refresh tokens are issued for service connections.

**Tech Stack:** Java 21, Quarkus CDI, Spring Boot auto-configuration, SmallRye ConfigMapping

## Pre-requisite (out of scope for this plan)

The spec identifies that `access_type=offline` must be set in Google's authorization URL for refresh tokens to be issued. Without this, service connections die after ~1 hour. This change modifies `AbstractOAuthAuthenticationProvider.buildAuthorizationUrl()` and affects all social providers — it should be a separate issue to avoid scope creep. The service connection SPI works correctly regardless; the refresh token gap only matters when a consumer calls `getAccessToken()` after the initial token expires.

## Global Constraints

- `platform-api/` must remain zero-dependency — pure Java only
- Core POJOs use constructor injection — no CDI, no Spring imports
- Every SPI in platform-api gets a `@DefaultBean` implementation in `platform/`
- SPI methods use `ScopeRegistry` interface, not `ScopeRegistryCore` concrete type
- All new types in package `io.casehub.platform.api.authn`
- NoOp implementations in `platform/` package `io.casehub.platform.authn`
- Tests use TDD: write failing test → verify fail → implement → verify pass

---

## Batch 1: SPI Foundation — platform-api types + NoOp default

After this batch: new SPI types compile, NoOp default exists, `ScopeRegistry.registeredProviders()` is available. No wiring yet.

### Task 1: ServiceConnectionProvider SPI and supporting types in platform-api

**Files:**
- Create: `platform-api/src/main/java/io/casehub/platform/api/authn/ServiceConnectionProvider.java`
- Create: `platform-api/src/main/java/io/casehub/platform/api/authn/ServiceConnection.java`
- Create: `platform-api/src/main/java/io/casehub/platform/api/authn/ServiceConnectionStatus.java`
- Create: `platform-api/src/main/java/io/casehub/platform/api/authn/ServiceAccessToken.java`
- Create: `platform-api/src/main/java/io/casehub/platform/api/authn/ServiceConnectionException.java`
- Modify: `platform-api/src/main/java/io/casehub/platform/api/authn/ScopeRegistry.java:5-11` — add `registeredProviders()` default method
- Test: `platform-api/src/test/java/io/casehub/platform/api/authn/ServiceConnectionTest.java`

**Interfaces:**
- Produces: `ServiceConnectionProvider` (SPI interface), `ServiceConnection` (record), `ServiceConnectionStatus` (enum: CONNECTED/PARTIAL/DISCONNECTED), `ServiceAccessToken` (record: accessToken, expiresAt, grantedScopes), `ServiceConnectionException` (RuntimeException: provider, actorId, requiredScopes, grantedScopes, missingScopes), `ScopeRegistry.registeredProviders()` (default method returning `Set<String>`)

- [ ] **Step 1: Write tests for the new records and enum**

```java
package io.casehub.platform.api.authn;

import org.junit.jupiter.api.Test;
import java.time.Instant;
import java.util.Set;
import static org.junit.jupiter.api.Assertions.*;

class ServiceConnectionTest {

    @Test
    void serviceConnectionRecordFields() {
        var conn = new ServiceConnection("actor1", "google", "tenant1",
            ServiceConnectionStatus.CONNECTED,
            Set.of("openid", "email"), Set.of(), Instant.parse("2026-01-01T00:00:00Z"));
        assertEquals("actor1", conn.actorId());
        assertEquals("google", conn.provider());
        assertEquals(ServiceConnectionStatus.CONNECTED, conn.status());
        assertTrue(conn.missingScopes().isEmpty());
    }

    @Test
    void serviceAccessTokenRecordFields() {
        var token = new ServiceAccessToken("abc123",
            Instant.parse("2026-01-01T01:00:00Z"),
            Set.of("openid", "drive.readonly"));
        assertEquals("abc123", token.accessToken());
        assertEquals(2, token.grantedScopes().size());
    }

    @Test
    void serviceConnectionExceptionCarriesScopeContext() {
        var ex = new ServiceConnectionException("No connection",
            "google", "actor1",
            Set.of("drive.readonly"), Set.of("openid"), Set.of("drive.readonly"));
        assertEquals("google", ex.provider());
        assertEquals("actor1", ex.actorId());
        assertEquals(Set.of("drive.readonly"), ex.requiredScopes());
        assertEquals(Set.of("openid"), ex.grantedScopes());
        assertEquals(Set.of("drive.readonly"), ex.missingScopes());
    }

    @Test
    void serviceConnectionStatusValues() {
        assertEquals(3, ServiceConnectionStatus.values().length);
        assertNotNull(ServiceConnectionStatus.valueOf("CONNECTED"));
        assertNotNull(ServiceConnectionStatus.valueOf("PARTIAL"));
        assertNotNull(ServiceConnectionStatus.valueOf("DISCONNECTED"));
    }

    @Test
    void scopeRegistryDefaultRegisteredProviders() {
        ScopeRegistry registry = new ScopeRegistry() {
            @Override public void register(String p, Set<String> s, Class<?> c) {}
            @Override public Set<String> requiredScopes(String p) { return Set.of(); }
            @Override public Set<String> requiredScopes(String p, Class<?> c) { return Set.of(); }
            @Override public boolean satisfies(String p, Set<String> s) { return true; }
            @Override public Set<String> missingScopes(String p, Set<String> s) { return Set.of(); }
        };
        assertTrue(registry.registeredProviders().isEmpty());
    }

    @Test
    void serviceConnectionProviderDisconnectDefaultThrows() {
        ServiceConnectionProvider provider = new ServiceConnectionProvider() {
            @Override public ServiceConnection getConnection(String a, String p, String t) { return null; }
            @Override public java.util.List<ServiceConnection> listConnections(String a, String t) { return java.util.List.of(); }
            @Override public ServiceAccessToken getAccessToken(String a, String p, String t) { return null; }
            @Override public Set<String> missingScopes(String a, String p, String t) { return Set.of(); }
        };
        assertThrows(UnsupportedOperationException.class,
            () -> provider.disconnect("actor1", "google", "tenant1"));
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mvn --batch-mode test -pl platform-api -Dtest=ServiceConnectionTest`
Expected: FAIL — classes do not exist

- [ ] **Step 3: Create ServiceConnectionStatus enum**

```java
package io.casehub.platform.api.authn;

public enum ServiceConnectionStatus {
    CONNECTED,
    PARTIAL,
    DISCONNECTED
}
```

- [ ] **Step 4: Create ServiceAccessToken record**

```java
package io.casehub.platform.api.authn;

import java.time.Instant;
import java.util.Set;

public record ServiceAccessToken(
    String accessToken,
    Instant expiresAt,
    Set<String> grantedScopes
) {}
```

- [ ] **Step 5: Create ServiceConnection record**

```java
package io.casehub.platform.api.authn;

import java.time.Instant;
import java.util.Set;

public record ServiceConnection(
    String actorId,
    String provider,
    String tenancyId,
    ServiceConnectionStatus status,
    Set<String> grantedScopes,
    Set<String> missingScopes,
    Instant connectedAt
) {}
```

- [ ] **Step 6: Create ServiceConnectionException**

```java
package io.casehub.platform.api.authn;

import java.util.Set;

public class ServiceConnectionException extends RuntimeException {
    private final String provider;
    private final String actorId;
    private final Set<String> requiredScopes;
    private final Set<String> grantedScopes;
    private final Set<String> missingScopes;

    public ServiceConnectionException(String message, String provider, String actorId,
                                       Set<String> requiredScopes, Set<String> grantedScopes,
                                       Set<String> missingScopes) {
        super(message);
        this.provider = provider;
        this.actorId = actorId;
        this.requiredScopes = requiredScopes != null ? Set.copyOf(requiredScopes) : Set.of();
        this.grantedScopes = grantedScopes != null ? Set.copyOf(grantedScopes) : Set.of();
        this.missingScopes = missingScopes != null ? Set.copyOf(missingScopes) : Set.of();
    }

    public String provider() { return provider; }
    public String actorId() { return actorId; }
    public Set<String> requiredScopes() { return requiredScopes; }
    public Set<String> grantedScopes() { return grantedScopes; }
    public Set<String> missingScopes() { return missingScopes; }
}
```

- [ ] **Step 7: Create ServiceConnectionProvider SPI**

```java
package io.casehub.platform.api.authn;

import java.util.List;
import java.util.Set;

public interface ServiceConnectionProvider {

    ServiceConnection getConnection(String actorId, String provider, String tenancyId);

    List<ServiceConnection> listConnections(String actorId, String tenancyId);

    ServiceAccessToken getAccessToken(String actorId, String provider, String tenancyId);

    default void disconnect(String actorId, String provider, String tenancyId) {
        throw new UnsupportedOperationException("disconnect not supported");
    }

    Set<String> missingScopes(String actorId, String provider, String tenancyId);
}
```

- [ ] **Step 8: Add registeredProviders() default to ScopeRegistry**

Add to `ScopeRegistry.java` after line 10:

```java
default Set<String> registeredProviders() {
    return Set.of();
}
```

- [ ] **Step 9: Run tests to verify they pass**

Run: `mvn --batch-mode test -pl platform-api -Dtest=ServiceConnectionTest`
Expected: PASS (all 6 tests)

- [ ] **Step 10: Commit**

```bash
git add platform-api/src/main/java/io/casehub/platform/api/authn/ServiceConnectionProvider.java \
       platform-api/src/main/java/io/casehub/platform/api/authn/ServiceConnection.java \
       platform-api/src/main/java/io/casehub/platform/api/authn/ServiceConnectionStatus.java \
       platform-api/src/main/java/io/casehub/platform/api/authn/ServiceAccessToken.java \
       platform-api/src/main/java/io/casehub/platform/api/authn/ServiceConnectionException.java \
       platform-api/src/main/java/io/casehub/platform/api/authn/ScopeRegistry.java \
       platform-api/src/test/java/io/casehub/platform/api/authn/ServiceConnectionTest.java
git commit -m "feat(#530): add ServiceConnectionProvider SPI and supporting types"
```

### Task 2: NoOp default + ScopeRegistryCore.registeredProviders()

**Files:**
- Create: `platform/src/main/java/io/casehub/platform/authn/NoOpServiceConnectionProvider.java`
- Modify: `authn-core/src/main/java/io/casehub/platform/authn/ScopeRegistryCore.java:10-62` — add `registeredProviders()` override
- Test: `platform/src/test/java/io/casehub/platform/authn/NoOpServiceConnectionProviderTest.java`
- Test: `authn-core/src/test/java/io/casehub/platform/authn/ScopeRegistryCoreTest.java` — add test for `registeredProviders()`

**Interfaces:**
- Consumes: `ServiceConnectionProvider` (SPI from Task 1), `ServiceConnectionStatus`, `ServiceConnection`, `ServiceAccessToken`, `ServiceConnectionException`
- Produces: `NoOpServiceConnectionProvider` (Quarkus `@DefaultBean` no-op), `ScopeRegistryCore.registeredProviders()` (returns key set of internal map)

- [ ] **Step 1: Write test for NoOpServiceConnectionProvider**

```java
package io.casehub.platform.authn;

import io.casehub.platform.api.authn.ServiceConnectionException;
import io.casehub.platform.api.authn.ServiceConnectionStatus;
import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.*;

class NoOpServiceConnectionProviderTest {

    private final NoOpServiceConnectionProvider provider = new NoOpServiceConnectionProvider();

    @Test
    void getConnectionReturnsDisconnected() {
        var conn = provider.getConnection("actor1", "google", "tenant1");
        assertEquals(ServiceConnectionStatus.DISCONNECTED, conn.status());
        assertEquals("actor1", conn.actorId());
        assertEquals("google", conn.provider());
        assertTrue(conn.grantedScopes().isEmpty());
        assertTrue(conn.missingScopes().isEmpty());
        assertNull(conn.connectedAt());
    }

    @Test
    void listConnectionsReturnsEmpty() {
        assertTrue(provider.listConnections("actor1", "tenant1").isEmpty());
    }

    @Test
    void getAccessTokenThrows() {
        assertThrows(ServiceConnectionException.class,
            () -> provider.getAccessToken("actor1", "google", "tenant1"));
    }

    @Test
    void disconnectNoOps() {
        assertDoesNotThrow(() -> provider.disconnect("actor1", "google", "tenant1"));
    }

    @Test
    void missingScopesReturnsEmpty() {
        assertTrue(provider.missingScopes("actor1", "google", "tenant1").isEmpty());
    }
}
```

- [ ] **Step 2: Write test for ScopeRegistryCore.registeredProviders()**

Add to existing `ScopeRegistryCoreTest.java`:

```java
@Test
void registeredProvidersReturnsEmptyWhenNoneRegistered() {
    assertTrue(registry.registeredProviders().isEmpty());
}

@Test
void registeredProvidersReturnsRegisteredKeys() {
    registry.register("google", Set.of("drive"), Object.class);
    registry.register("github", Set.of("repo"), Object.class);
    assertEquals(Set.of("google", "github"), registry.registeredProviders());
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `mvn --batch-mode test -pl platform -Dtest=NoOpServiceConnectionProviderTest`
Run: `mvn --batch-mode test -pl authn-core -Dtest=ScopeRegistryCoreTest#registeredProviders*`
Expected: FAIL

- [ ] **Step 4: Implement NoOpServiceConnectionProvider**

```java
package io.casehub.platform.authn;

import io.casehub.platform.api.authn.ServiceAccessToken;
import io.casehub.platform.api.authn.ServiceConnection;
import io.casehub.platform.api.authn.ServiceConnectionException;
import io.casehub.platform.api.authn.ServiceConnectionProvider;
import io.casehub.platform.api.authn.ServiceConnectionStatus;
import io.quarkus.arc.DefaultBean;
import jakarta.enterprise.context.ApplicationScoped;

import java.util.List;
import java.util.Set;

@DefaultBean
@ApplicationScoped
public class NoOpServiceConnectionProvider implements ServiceConnectionProvider {

    @Override
    public ServiceConnection getConnection(String actorId, String provider, String tenancyId) {
        return new ServiceConnection(actorId, provider, tenancyId,
            ServiceConnectionStatus.DISCONNECTED, Set.of(), Set.of(), null);
    }

    @Override
    public List<ServiceConnection> listConnections(String actorId, String tenancyId) {
        return List.of();
    }

    @Override
    public ServiceAccessToken getAccessToken(String actorId, String provider, String tenancyId) {
        throw new ServiceConnectionException("No service connection provider configured",
            provider, actorId, Set.of(), Set.of(), Set.of());
    }

    @Override
    public void disconnect(String actorId, String provider, String tenancyId) {
        // overrides SPI default throw — safe no-op
    }

    @Override
    public Set<String> missingScopes(String actorId, String provider, String tenancyId) {
        return Set.of();
    }
}
```

- [ ] **Step 5: Implement ScopeRegistryCore.registeredProviders()**

Add to `ScopeRegistryCore.java` after the `missingScopes()` method:

```java
@Override
public Set<String> registeredProviders() {
    return Set.copyOf(registrations.keySet());
}
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `mvn --batch-mode test -pl platform -Dtest=NoOpServiceConnectionProviderTest`
Run: `mvn --batch-mode test -pl authn-core -Dtest=ScopeRegistryCoreTest`
Expected: PASS

- [ ] **Step 7: Commit**

```bash
git add platform/src/main/java/io/casehub/platform/authn/NoOpServiceConnectionProvider.java \
       platform/src/test/java/io/casehub/platform/authn/NoOpServiceConnectionProviderTest.java \
       authn-core/src/main/java/io/casehub/platform/authn/ScopeRegistryCore.java \
       authn-core/src/test/java/io/casehub/platform/authn/ScopeRegistryCoreTest.java
git commit -m "feat(#530): add NoOpServiceConnectionProvider @DefaultBean and ScopeRegistry.registeredProviders()"
```

---

## Batch 2: Core implementation — ServiceConnectionProviderCore + ScopeMergingLoginCustomizer

After this batch: the core POJO implementation works and is unit-tested. No framework wiring yet.

### Task 3: ServiceConnectionProviderCore implementation

**Files:**
- Create: `authn-social-core/src/main/java/io/casehub/platform/authn/social/ServiceConnectionProviderCore.java`
- Test: `authn-social-core/src/test/java/io/casehub/platform/authn/social/ServiceConnectionProviderCoreTest.java`

**Interfaces:**
- Consumes: `ServiceConnectionProvider` (SPI), `OAuthTokenStore` (SPI), `OAuthTokenManagerCore`, `ScopeRegistry` (SPI), `OAuthTokenRecord`, `ServiceConnection`, `ServiceAccessToken`, `ServiceConnectionException`, `ServiceConnectionStatus`
- Produces: `ServiceConnectionProviderCore` (POJO implementing `ServiceConnectionProvider`)

- [ ] **Step 1: Write failing tests**

```java
package io.casehub.platform.authn.social;

import io.casehub.platform.api.authn.OAuthTokenRecord;
import io.casehub.platform.api.authn.OAuthTokenStore;
import io.casehub.platform.api.authn.ScopeRegistry;
import io.casehub.platform.api.authn.ServiceConnectionException;
import io.casehub.platform.api.authn.ServiceConnectionStatus;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import java.time.Instant;
import java.util.List;
import java.util.Optional;
import java.util.Set;

import static org.junit.jupiter.api.Assertions.*;

class ServiceConnectionProviderCoreTest {

    private InMemoryOAuthTokenStore tokenStore;
    private StubScopeRegistry scopeRegistry;
    private StubTokenManager tokenManager;
    private ServiceConnectionProviderCore provider;

    @BeforeEach
    void setUp() {
        tokenStore = new InMemoryOAuthTokenStore();
        scopeRegistry = new StubScopeRegistry();
        tokenManager = new StubTokenManager(tokenStore);
        provider = new ServiceConnectionProviderCore(tokenStore, tokenManager, scopeRegistry);
    }

    @Test
    void getConnectionReturnsDisconnectedWhenNoToken() {
        scopeRegistry.register("google", Set.of("drive"), Object.class);
        var conn = provider.getConnection("actor1", "google", "tenant1");
        assertEquals(ServiceConnectionStatus.DISCONNECTED, conn.status());
        assertEquals(Set.of("drive"), conn.missingScopes());
    }

    @Test
    void getConnectionReturnsConnectedWhenAllScopesSatisfied() {
        scopeRegistry.register("google", Set.of("drive"), Object.class);
        tokenStore.store(new OAuthTokenRecord("actor1", "tenant1", "google",
            "token", "refresh", Set.of("openid", "drive"),
            Instant.now().plusSeconds(3600), Instant.now()));
        var conn = provider.getConnection("actor1", "google", "tenant1");
        assertEquals(ServiceConnectionStatus.CONNECTED, conn.status());
        assertTrue(conn.missingScopes().isEmpty());
    }

    @Test
    void getConnectionReturnsPartialWhenSomeScopes() {
        scopeRegistry.register("google", Set.of("drive", "calendar"), Object.class);
        tokenStore.store(new OAuthTokenRecord("actor1", "tenant1", "google",
            "token", "refresh", Set.of("openid", "drive"),
            Instant.now().plusSeconds(3600), Instant.now()));
        var conn = provider.getConnection("actor1", "google", "tenant1");
        assertEquals(ServiceConnectionStatus.PARTIAL, conn.status());
        assertEquals(Set.of("calendar"), conn.missingScopes());
    }

    @Test
    void getAccessTokenReturnsValidToken() {
        tokenStore.store(new OAuthTokenRecord("actor1", "tenant1", "google",
            "token123", "refresh", Set.of("drive"),
            Instant.now().plusSeconds(3600), Instant.now()));
        var accessToken = provider.getAccessToken("actor1", "google", "tenant1");
        assertEquals("token123", accessToken.accessToken());
    }

    @Test
    void getAccessTokenThrowsWhenNoConnection() {
        scopeRegistry.register("google", Set.of("drive"), Object.class);
        var ex = assertThrows(ServiceConnectionException.class,
            () -> provider.getAccessToken("actor1", "google", "tenant1"));
        assertEquals("google", ex.provider());
        assertEquals(Set.of("drive"), ex.requiredScopes());
    }

    @Test
    void disconnectDelegatesToTokenManager() {
        tokenStore.store(new OAuthTokenRecord("actor1", "tenant1", "google",
            "token", "refresh", Set.of("drive"),
            Instant.now().plusSeconds(3600), Instant.now()));
        provider.disconnect("actor1", "google", "tenant1");
        assertTrue(tokenStore.findByActorId("actor1", "google", "tenant1").isEmpty());
    }

    @Test
    void listConnectionsIncludesDisconnectedProviders() {
        scopeRegistry.register("google", Set.of("drive"), Object.class);
        scopeRegistry.register("github", Set.of("repo"), Object.class);
        tokenStore.store(new OAuthTokenRecord("actor1", "tenant1", "google",
            "token", "refresh", Set.of("openid", "drive"),
            Instant.now().plusSeconds(3600), Instant.now()));
        var connections = provider.listConnections("actor1", "tenant1");
        assertEquals(2, connections.size());
        var google = connections.stream().filter(c -> c.provider().equals("google")).findFirst().orElseThrow();
        var github = connections.stream().filter(c -> c.provider().equals("github")).findFirst().orElseThrow();
        assertEquals(ServiceConnectionStatus.CONNECTED, google.status());
        assertEquals(ServiceConnectionStatus.DISCONNECTED, github.status());
    }

    @Test
    void missingScopesReturnsCorrectSet() {
        scopeRegistry.register("google", Set.of("drive", "calendar"), Object.class);
        tokenStore.store(new OAuthTokenRecord("actor1", "tenant1", "google",
            "token", "refresh", Set.of("drive"),
            Instant.now().plusSeconds(3600), Instant.now()));
        assertEquals(Set.of("calendar"), provider.missingScopes("actor1", "google", "tenant1"));
    }

    // --- Test doubles ---

    private static class InMemoryOAuthTokenStore implements OAuthTokenStore {
        private final java.util.concurrent.ConcurrentHashMap<String, OAuthTokenRecord> store = new java.util.concurrent.ConcurrentHashMap<>();
        private String key(String actorId, String provider, String tenancyId) { return actorId + ":" + provider + ":" + tenancyId; }

        @Override public void store(OAuthTokenRecord record) { store.put(key(record.actorId(), record.provider(), record.tenancyId()), record); }
        @Override public Optional<OAuthTokenRecord> findByActorId(String a, String p, String t) { return Optional.ofNullable(store.get(key(a, p, t))); }
        @Override public List<OAuthTokenRecord> findAllByActorId(String a, String t) { return store.values().stream().filter(r -> r.actorId().equals(a) && r.tenancyId().equals(t)).toList(); }
        @Override public void delete(String a, String p, String t) { store.remove(key(a, p, t)); }
        @Override public void updateTokens(String a, String p, String t, String at, String rt, Instant e) {}
        @Override public void updateScopes(String a, String p, String t, Set<String> s) {}
    }

    private static class StubScopeRegistry implements ScopeRegistry {
        private final java.util.concurrent.ConcurrentHashMap<String, Set<String>> registrations = new java.util.concurrent.ConcurrentHashMap<>();
        @Override public void register(String p, Set<String> s, Class<?> c) { registrations.merge(p, s, (a, b) -> { var merged = new java.util.HashSet<>(a); merged.addAll(b); return Set.copyOf(merged); }); }
        @Override public Set<String> requiredScopes(String p) { return registrations.getOrDefault(p, Set.of()); }
        @Override public Set<String> requiredScopes(String p, Class<?> c) { return requiredScopes(p); }
        @Override public boolean satisfies(String p, Set<String> g) { return g.containsAll(requiredScopes(p)); }
        @Override public Set<String> missingScopes(String p, Set<String> g) { var m = new java.util.HashSet<>(requiredScopes(p)); m.removeAll(g); return Set.copyOf(m); }
        @Override public Set<String> registeredProviders() { return Set.copyOf(registrations.keySet()); }
    }

    private static class StubTokenManager extends OAuthTokenManagerCore {
        private final OAuthTokenStore store;
        StubTokenManager(OAuthTokenStore store) { super(store, r -> { throw new UnsupportedOperationException(); }, new io.casehub.platform.api.authn.AuthenticationEventListener() {}); this.store = store; }
        @Override public Optional<OAuthTokenRecord> getValidToken(String a, String p, String t) { return store.findByActorId(a, p, t); }
        @Override public void revoke(String a, String p, String t) { store.delete(a, p, t); }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn --batch-mode test -pl authn-social-core -Dtest=ServiceConnectionProviderCoreTest`
Expected: FAIL — `ServiceConnectionProviderCore` does not exist

- [ ] **Step 3: Implement ServiceConnectionProviderCore**

```java
package io.casehub.platform.authn.social;

import io.casehub.platform.api.authn.OAuthTokenRecord;
import io.casehub.platform.api.authn.OAuthTokenStore;
import io.casehub.platform.api.authn.ScopeRegistry;
import io.casehub.platform.api.authn.ServiceAccessToken;
import io.casehub.platform.api.authn.ServiceConnection;
import io.casehub.platform.api.authn.ServiceConnectionException;
import io.casehub.platform.api.authn.ServiceConnectionProvider;
import io.casehub.platform.api.authn.ServiceConnectionStatus;

import java.util.ArrayList;
import java.util.List;
import java.util.Set;
import java.util.stream.Collectors;

public class ServiceConnectionProviderCore implements ServiceConnectionProvider {

    private final OAuthTokenStore tokenStore;
    private final OAuthTokenManagerCore tokenManager;
    private final ScopeRegistry scopeRegistry;

    public ServiceConnectionProviderCore(OAuthTokenStore tokenStore,
                                          OAuthTokenManagerCore tokenManager,
                                          ScopeRegistry scopeRegistry) {
        this.tokenStore = tokenStore;
        this.tokenManager = tokenManager;
        this.scopeRegistry = scopeRegistry;
    }

    @Override
    public ServiceConnection getConnection(String actorId, String provider, String tenancyId) {
        var record = tokenStore.findByActorId(actorId, provider, tenancyId);
        if (record.isEmpty()) {
            return new ServiceConnection(actorId, provider, tenancyId,
                ServiceConnectionStatus.DISCONNECTED, Set.of(),
                scopeRegistry.requiredScopes(provider), null);
        }
        var token = record.get();
        var missing = scopeRegistry.missingScopes(provider, token.grantedScopes());
        var status = missing.isEmpty() ? ServiceConnectionStatus.CONNECTED : ServiceConnectionStatus.PARTIAL;
        return new ServiceConnection(actorId, provider, tenancyId,
            status, token.grantedScopes(), missing, token.createdAt());
    }

    @Override
    public ServiceAccessToken getAccessToken(String actorId, String provider, String tenancyId) {
        var token = tokenManager.getValidToken(actorId, provider, tenancyId);
        if (token.isEmpty()) {
            var required = scopeRegistry.requiredScopes(provider);
            throw new ServiceConnectionException("No connection for provider: " + provider,
                provider, actorId, required, Set.of(), required);
        }
        var record = token.get();
        return new ServiceAccessToken(record.accessToken(), record.expiresAt(), record.grantedScopes());
    }

    @Override
    public List<ServiceConnection> listConnections(String actorId, String tenancyId) {
        var tokenRecords = tokenStore.findAllByActorId(actorId, tenancyId);
        var providersWithTokens = tokenRecords.stream()
            .map(OAuthTokenRecord::provider)
            .collect(Collectors.toSet());

        var connections = new ArrayList<ServiceConnection>();
        for (var record : tokenRecords) {
            connections.add(getConnection(actorId, record.provider(), tenancyId));
        }
        for (var provider : scopeRegistry.registeredProviders()) {
            if (!providersWithTokens.contains(provider)) {
                connections.add(getConnection(actorId, provider, tenancyId));
            }
        }
        return List.copyOf(connections);
    }

    @Override
    public void disconnect(String actorId, String provider, String tenancyId) {
        tokenManager.revoke(actorId, provider, tenancyId);
    }

    @Override
    public Set<String> missingScopes(String actorId, String provider, String tenancyId) {
        return getConnection(actorId, provider, tenancyId).missingScopes();
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mvn --batch-mode test -pl authn-social-core -Dtest=ServiceConnectionProviderCoreTest`
Expected: PASS (all 8 tests)

- [ ] **Step 5: Commit**

```bash
git add authn-social-core/src/main/java/io/casehub/platform/authn/social/ServiceConnectionProviderCore.java \
       authn-social-core/src/test/java/io/casehub/platform/authn/social/ServiceConnectionProviderCoreTest.java
git commit -m "feat(#530): implement ServiceConnectionProviderCore — derived view over OAuth stores"
```

### Task 4: ScopeMergingLoginCustomizer + AuthenticationRouterCore integration

**Files:**
- Create: `../../authn-core/src/main/java/io/casehub/platform/authn/ScopeMergingLoginCustomizer.java`
- Modify: `authn-core/src/main/java/io/casehub/platform/authn/AuthenticationRouterCore.java:24-97` — add customizer to constructor + call in `initiate()`
- Test: `../../authn-core/src/test/java/io/casehub/platform/authn/ScopeMergingLoginCustomizerTest.java`
- Test: `authn-core/src/test/java/io/casehub/platform/authn/AuthenticationRouterCoreTest.java` — add test for scope merging

**Interfaces:**
- Consumes: `ScopeRegistry` (SPI), `AuthenticationContext` (record)
- Produces: `ScopeMergingLoginCustomizer` (POJO: `customize(context, provider)` → `AuthenticationContext`), modified `AuthenticationRouterCore` constructor (adds optional `ScopeMergingLoginCustomizer`)

- [ ] **Step 1: Write failing tests for ScopeMergingLoginCustomizer**

```java
package io.casehub.platform.authn.social;

import io.casehub.platform.api.authn.AuthenticationContext;
import io.casehub.platform.api.authn.ScopeRegistry;
import org.junit.jupiter.api.Test;

import java.util.Map;
import java.util.Optional;
import java.util.Set;

import static org.junit.jupiter.api.Assertions.*;

class ScopeMergingLoginCustomizerTest {

    @Test
    void mergesScopesWhenEnabled() {
        var registry = stubRegistry(Set.of("drive.readonly"));
        var customizer = new ScopeMergingLoginCustomizer(registry, true);
        var context = new AuthenticationContext("google", "tenant1", "https://app.example.com", Optional.empty(), Map.of());
        var result = customizer.customize(context, "google");
        @SuppressWarnings("unchecked")
        var scopes = (Set<String>) result.hints().get("additionalScopes");
        assertEquals(Set.of("drive.readonly"), scopes);
    }

    @Test
    void preservesExistingHints() {
        var registry = stubRegistry(Set.of("drive"));
        var customizer = new ScopeMergingLoginCustomizer(registry, true);
        var context = new AuthenticationContext("google", "tenant1", "https://app.example.com",
            Optional.empty(), Map.of("existingKey", "existingValue"));
        var result = customizer.customize(context, "google");
        assertEquals("existingValue", result.hints().get("existingKey"));
        assertNotNull(result.hints().get("additionalScopes"));
    }

    @Test
    void returnsUnmodifiedContextWhenDisabled() {
        var registry = stubRegistry(Set.of("drive"));
        var customizer = new ScopeMergingLoginCustomizer(registry, false);
        var context = new AuthenticationContext("google", "tenant1", "https://app.example.com", Optional.empty(), Map.of());
        var result = customizer.customize(context, "google");
        assertSame(context, result);
    }

    @Test
    void returnsUnmodifiedContextWhenNoScopes() {
        var registry = stubRegistry(Set.of());
        var customizer = new ScopeMergingLoginCustomizer(registry, true);
        var context = new AuthenticationContext("google", "tenant1", "https://app.example.com", Optional.empty(), Map.of());
        var result = customizer.customize(context, "google");
        assertSame(context, result);
    }

    private ScopeRegistry stubRegistry(Set<String> scopes) {
        return new ScopeRegistry() {
            @Override public void register(String p, Set<String> s, Class<?> c) {}
            @Override public Set<String> requiredScopes(String p) { return scopes; }
            @Override public Set<String> requiredScopes(String p, Class<?> c) { return scopes; }
            @Override public boolean satisfies(String p, Set<String> g) { return g.containsAll(scopes); }
            @Override public Set<String> missingScopes(String p, Set<String> g) { var m = new java.util.HashSet<>(scopes); m.removeAll(g); return Set.copyOf(m); }
            @Override public Set<String> registeredProviders() { return scopes.isEmpty() ? Set.of() : Set.of("google"); }
        };
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn --batch-mode test -pl authn-social-core -Dtest=ScopeMergingLoginCustomizerTest`
Expected: FAIL

- [ ] **Step 3: Implement ScopeMergingLoginCustomizer**

```java
package io.casehub.platform.authn.social;

import io.casehub.platform.api.authn.AuthenticationContext;
import io.casehub.platform.api.authn.ScopeRegistry;

import java.util.HashMap;

public class ScopeMergingLoginCustomizer {

    private final ScopeRegistry scopeRegistry;
    private final boolean enabled;

    public ScopeMergingLoginCustomizer(ScopeRegistry scopeRegistry, boolean enabled) {
        this.scopeRegistry = scopeRegistry;
        this.enabled = enabled;
    }

    public AuthenticationContext customize(AuthenticationContext context, String provider) {
        if (!enabled) return context;
        var serviceScopes = scopeRegistry.requiredScopes(provider);
        if (serviceScopes.isEmpty()) return context;
        var hints = new HashMap<>(context.hints());
        hints.put("additionalScopes", serviceScopes);
        return new AuthenticationContext(context.method(), context.tenancyId(),
            context.origin(), context.existingPrincipal(), hints);
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mvn --batch-mode test -pl authn-social-core -Dtest=ScopeMergingLoginCustomizerTest`
Expected: PASS (all 4 tests)

- [ ] **Step 5: Modify AuthenticationRouterCore to accept optional customizer**

Add a second constructor that accepts `ScopeMergingLoginCustomizer`. Modify `initiate()` to call `customizer.customize()` before delegating to the provider. Keep the existing constructor for backwards compatibility:

```java
// Add field after eventListener declaration (line 30):
private final ScopeMergingLoginCustomizer scopeMergingCustomizer;

// Add second constructor after existing constructor (line 39):
public AuthenticationRouterCore(List<AuthenticationProvider> providers,
                                ChallengeStore challengeStore,
                                AuthenticationEventListener eventListener,
                                ScopeMergingLoginCustomizer scopeMergingCustomizer) {
    this.providers      = providers.stream()
                                   .collect(Collectors.toUnmodifiableMap(AuthenticationProvider::method, p -> p));
    this.challengeStore = challengeStore;
    this.eventListener  = eventListener;
    this.scopeMergingCustomizer = scopeMergingCustomizer;
}

// Modify existing constructor to set customizer to null:
// Add after line 37: this.scopeMergingCustomizer = null;

// Modify initiate() — add scope merge before provider delegation (line 43):
@Override
public ChallengeResponse initiate(AuthenticationContext context) {
    var provider = resolveProvider(context.method());
    var effectiveContext = scopeMergingCustomizer != null
        ? scopeMergingCustomizer.customize(context, context.method())
        : context;
    var response = provider.initiate(effectiveContext);
    var record = new ChallengeRecord(
            response.challengeId(), context.method(), context.tenancyId(),
            null, Instant.now(), response.expiresAt());
    challengeStore.store(record);
    return response;
}
```

- [ ] **Step 6: Run all authn-core tests to verify no regressions**

Run: `mvn --batch-mode test -pl authn-core`
Expected: PASS

- [ ] **Step 7: Commit**

```bash
git add authn-social-core/src/main/java/io/casehub/platform/authn/social/ScopeMergingLoginCustomizer.java \
       authn-social-core/src/test/java/io/casehub/platform/authn/social/ScopeMergingLoginCustomizerTest.java \
       authn-core/src/main/java/io/casehub/platform/authn/AuthenticationRouterCore.java
git commit -m "feat(#530): add ScopeMergingLoginCustomizer + integrate into AuthenticationRouterCore"
```

---

## Batch 3: Framework wiring + configuration + follow-up issues

After this batch: full end-to-end wiring in both Quarkus and Spring. Config property available. Connectors follow-up issues filed.

### Task 5: Quarkus + Spring wiring and configuration

**Files:**
- Modify: `authn/src/main/java/io/casehub/platform/authn/quarkus/AuthnConfig.java:11-44` — add `mergeServiceScopes()` with `@WithDefault("true")`
- Modify: `authn/src/main/java/io/casehub/platform/authn/quarkus/AuthnBeans.java:34-167` — add `@Produces` for `ServiceConnectionProviderCore` and `ScopeMergingLoginCustomizer`, update `AuthenticationRouterCore` producer to pass customizer
- Modify: `authn-spring/src/main/java/io/casehub/platform/authn/spring/AuthnSpringProperties.java:9-77` — add `mergeServiceScopes` field with default `true`
- Modify: `authn-spring/src/main/java/io/casehub/platform/authn/spring/AuthnSpringAutoConfiguration.java:35-225` — add `@Bean` for `ServiceConnectionProviderCore` and `ScopeMergingLoginCustomizer`, update `AuthenticationRouterCore` bean to pass customizer
- Test: `authn/src/test/java/io/casehub/platform/authn/quarkus/AuthnBeansTest.java` — verify new beans are produced (if test exists, add to it)

**Interfaces:**
- Consumes: `ServiceConnectionProviderCore` (Task 3), `ScopeMergingLoginCustomizer` (Task 4), `OAuthTokenStore`, `OAuthTokenManagerCore`, `ScopeRegistry`, `AuthnConfig`, `AuthnSpringProperties`
- Produces: CDI/Spring beans for `ServiceConnectionProviderCore` and `ScopeMergingLoginCustomizer`

- [ ] **Step 1: Add `mergeServiceScopes()` to AuthnConfig**

Add after `refreshTokenTtlSeconds()` (line 17):

```java
@WithDefault("true")
boolean mergeServiceScopes();
```

- [ ] **Step 2: Add `mergeServiceScopes` to AuthnSpringProperties**

Add field after `social` (line 14):

```java
private boolean mergeServiceScopes = true;

public boolean isMergeServiceScopes() { return mergeServiceScopes; }
public void setMergeServiceScopes(boolean mergeServiceScopes) { this.mergeServiceScopes = mergeServiceScopes; }
```

- [ ] **Step 3: Add @Produces methods to AuthnBeans**

Add after `incrementalConsentHandlerCore` producer (line 164):

```java
@Produces
@ApplicationScoped
public ScopeMergingLoginCustomizer scopeMergingLoginCustomizer(
        io.casehub.platform.authn.ScopeRegistryCore scopeRegistry,
        AuthnConfig config) {
    return new ScopeMergingLoginCustomizer(scopeRegistry, config.mergeServiceScopes());
}

@Produces
@ApplicationScoped
public ServiceConnectionProviderCore serviceConnectionProviderCore(
        OAuthTokenStore tokenStore,
        OAuthTokenManagerCore tokenManager,
        io.casehub.platform.authn.ScopeRegistryCore scopeRegistry) {
    return new ServiceConnectionProviderCore(tokenStore, tokenManager, scopeRegistry);
}
```

Add necessary imports:
```java
import io.casehub.platform.authn.social.ScopeMergingLoginCustomizer;
import io.casehub.platform.authn.social.ServiceConnectionProviderCore;
```

- [ ] **Step 4: Update AuthnBeans AuthenticationRouterCore producer to pass customizer**

Modify the `authenticationRouterCore` producer (line 120-127) to inject and pass `ScopeMergingLoginCustomizer`:

```java
@Produces
@ApplicationScoped
public AuthenticationRouterCore authenticationRouterCore(
        List<AuthenticationProvider> providers,
        ChallengeStore challengeStore,
        AuthenticationEventListener eventListener,
        ScopeMergingLoginCustomizer scopeMergingCustomizer) {
    return new AuthenticationRouterCore(providers, challengeStore, eventListener, scopeMergingCustomizer);
}
```

- [ ] **Step 5: Add @Bean methods to AuthnSpringAutoConfiguration**

Add after `incrementalConsentHandlerCore` bean (line 222):

```java
@Bean
@ConditionalOnMissingBean
public io.casehub.platform.authn.social.ScopeMergingLoginCustomizer scopeMergingLoginCustomizer(
        io.casehub.platform.authn.ScopeRegistryCore scopeRegistry,
        AuthnSpringProperties props) {
    return new io.casehub.platform.authn.social.ScopeMergingLoginCustomizer(
        scopeRegistry, props.isMergeServiceScopes());
}

@Bean
@ConditionalOnMissingBean
public io.casehub.platform.authn.social.ServiceConnectionProviderCore serviceConnectionProviderCore(
        OAuthTokenStore tokenStore,
        OAuthTokenManagerCore tokenManager,
        io.casehub.platform.authn.ScopeRegistryCore scopeRegistry) {
    return new io.casehub.platform.authn.social.ServiceConnectionProviderCore(
        tokenStore, tokenManager, scopeRegistry);
}
```

- [ ] **Step 6: Update Spring AuthenticationRouterCore bean to pass customizer**

Modify the `authenticationRouterCore` bean (line 173-179):

```java
@Bean
@ConditionalOnMissingBean
public AuthenticationRouterCore authenticationRouterCore(
        List<AuthenticationProvider> providers,
        ChallengeStore challengeStore,
        AuthenticationEventListener eventListener,
        io.casehub.platform.authn.social.ScopeMergingLoginCustomizer scopeMergingCustomizer) {
    return new AuthenticationRouterCore(providers, challengeStore, eventListener, scopeMergingCustomizer);
}
```

- [ ] **Step 7: Build the full project to verify compilation**

Run: `mvn --batch-mode install -DskipTests`
Expected: BUILD SUCCESS

- [ ] **Step 8: Run all authn tests**

Run: `mvn --batch-mode test -pl authn,authn-core,authn-social-core,authn-spring`
Expected: PASS

- [ ] **Step 9: Commit**

```bash
git add authn/src/main/java/io/casehub/platform/authn/quarkus/AuthnConfig.java \
       authn/src/main/java/io/casehub/platform/authn/quarkus/AuthnBeans.java \
       authn-spring/src/main/java/io/casehub/platform/authn/spring/AuthnSpringProperties.java \
       authn-spring/src/main/java/io/casehub/platform/authn/spring/AuthnSpringAutoConfiguration.java
git commit -m "feat(#530): wire ServiceConnectionProvider + ScopeMergingLoginCustomizer in Quarkus and Spring"
```

### Task 6: Spring default bean + spring-integration-test + follow-up issues

**Files:**
- Modify: `platform-spring/` — add `@Bean @ConditionalOnMissingBean NoOpServiceConnectionProvider` (check existing pattern)
- Modify: `spring-integration-test/` — verify `ServiceConnectionProvider` bean is available in composition gate (if applicable)
- No file: file 3 GitHub issues in `casehubio/connectors`

**Interfaces:**
- Consumes: `NoOpServiceConnectionProvider` (Task 2)
- Produces: Spring default bean, connectors follow-up issues

- [ ] **Step 1: Add Spring default bean for NoOpServiceConnectionProvider**

Check the existing Spring default bean pattern in `platform-spring/` and add a `@Bean @ConditionalOnMissingBean` producing `NoOpServiceConnectionProvider`. Follow the pattern used by other platform-api SPIs.

- [ ] **Step 2: Run spring-integration-test**

Run: `mvn --batch-mode test -pl spring-integration-test`
Expected: PASS

- [ ] **Step 3: File follow-up issues in connectors repo**

```bash
gh issue create --repo casehubio/connectors --title "ConnectionPlatform SPI — pluggable service connection abstraction" --body "Define the connectors-side abstraction for platform service connections (Google Drive, Calendar, etc.). Depends on ServiceConnectionProvider SPI from platform#530.

Scale: M, Complexity: Med"

gh issue create --repo casehubio/connectors --title "Google service connection — register scopes and consume ServiceConnectionProvider" --body "Register Google API scopes (Drive, Calendar) at startup via ScopeRegistry. Use ServiceConnectionProvider.getAccessToken() for Google API calls. Observe SocialLoginCompleted for connection bootstrap notifications. Depends on platform#530 and ConnectionPlatform SPI.

Scale: S, Complexity: Med"

gh issue create --repo casehubio/connectors --title "Connection status UI — surface service connections in connectors dashboard" --body "Show connection status (Connected/Partial/Disconnected) in the connectors UI. Trigger incremental consent for PARTIAL connections. Uses ServiceConnectionProvider.listConnections() and ServiceConnectionProvider.getConnection(). Depends on platform#530 and Google service connection issue.

Scale: S, Complexity: Low"
```

- [ ] **Step 4: Update CLAUDE.md module table**

Add entries for the new types to the `platform-api` package structure in CLAUDE.md under `.authn`:

```
ServiceConnectionProvider (SPI: getConnection/listConnections/getAccessToken/disconnect/missingScopes),
ServiceConnection (record: actorId, provider, tenancyId, status, grantedScopes, missingScopes, connectedAt),
ServiceConnectionStatus (enum: CONNECTED/PARTIAL/DISCONNECTED),
ServiceAccessToken (record: accessToken, expiresAt, grantedScopes),
ServiceConnectionException (RuntimeException: provider, actorId, requiredScopes, grantedScopes, missingScopes)
```

- [ ] **Step 5: Full build verification**

Run: `mvn --batch-mode install`
Expected: BUILD SUCCESS with all tests passing

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat(#530): complete service connection wiring — Spring defaults, CLAUDE.md, follow-up issues filed"
```

---

## References

- [2026-10-07-social-login-service-connection-design.md] — design spec this plan implements
- `platform-api/src/main/java/io/casehub/platform/api/authn/ScopeRegistry.java` — SPI to extend with `registeredProviders()`
- `authn-core/src/main/java/io/casehub/platform/authn/AuthenticationRouterCore.java` — integration point for customizer
- `authn-core/src/main/java/io/casehub/platform/authn/ScopeRegistryCore.java` — concrete implementation
- `authn/src/main/java/io/casehub/platform/authn/quarkus/AuthnBeans.java` — Quarkus bean producers
- `authn/src/main/java/io/casehub/platform/authn/quarkus/AuthnConfig.java` — Quarkus config interface
- `authn-spring/src/main/java/io/casehub/platform/authn/spring/AuthnSpringAutoConfiguration.java` — Spring auto-config
- `authn-spring/src/main/java/io/casehub/platform/authn/spring/AuthnSpringProperties.java` — Spring config properties
- `platform/src/main/java/io/casehub/platform/authn/NoOpOAuthTokenStore.java` — NoOp pattern reference
- [GitHub #530] — focal issue
- [GitHub #525] — parent epic
