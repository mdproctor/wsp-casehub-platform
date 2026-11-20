# Spring REST Controllers for Authn Endpoints — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** #916 — Spring REST controllers for authn endpoints
**Issue group:** #916

**Goal:** Generate Spring MVC REST controllers for three authn domains
(connections, webauthn, social-auth) by extracting framework-neutral
core POJOs with `@McpDomain` and running the graphql-spring-generator.

**Architecture:** Extract the business logic from three CDI endpoint
classes (`ConnectionEndpoint`, `WebAuthnEndpoint`, `SocialAuthEndpoint`)
into constructor-injected POJOs in `authn-core`. The CDI endpoints are
then deleted — `AuthnBeans` produces the core POJOs as CDI beans, and
the existing graphql-generator APT picks them up from authn-core's
Jandex index to generate JAX-RS resources. The graphql-spring-generator
is added to `authn-spring` to generate Spring MVC controllers from the
same core POJOs.

**Tech Stack:** Java 21, Maven, graphql-spring-generator plugin,
platform-api SPIs, Jandex

## Global Constraints

- `authn-core` must remain zero-CDI, zero-Spring — pure Java + platform-api only
- All SPI types used by the endpoint POJOs (`ServiceConnectionProvider`,
  `IncrementalConsentHandler`, `ScopeRegistry`, `WebAuthnCredentialStore`,
  `AuthenticationRouter`) are already in platform-api — no new dependencies
- Generated Spring controllers must match the URL pattern of the generated
  Quarkus JAX-RS resources (`/api/connections`, `/api/webauthn`, `/api/social-auth`)
- No `quarkus:build` goal on `authn-spring`

---

## Batch 1: Extract core POJOs and migrate tests

### Task 1: Create ConnectionEndpointCore in authn-core

**Files:**
- Create: `authn-core/src/main/java/io/casehub/platform/authn/ConnectionEndpointCore.java`
- Create: `authn-core/src/test/java/io/casehub/platform/authn/ConnectionEndpointCoreTest.java`

**Interfaces:**
- Consumes: `ServiceConnectionProvider`, `IncrementalConsentHandler`,
  `ScopeRegistry` from `io.casehub.platform.api.authn`
- Produces: `ConnectionEndpointCore` — constructor-injected POJO with
  `@McpDomain("connections")`, same method signatures as current
  `ConnectionEndpoint`

- [ ] **Step 1: Write the failing test**

Create `ConnectionEndpointCoreTest.java` in authn-core. Port all 5 tests
from `authn/ConnectionEndpointTest.java`, replacing reflection-based
field injection with direct constructor injection:

```java
package io.casehub.platform.authn;

import io.casehub.platform.api.authn.ConsentRequest;
import io.casehub.platform.api.authn.IncrementalConsentHandler;
import io.casehub.platform.api.authn.ScopeRegistry;
import io.casehub.platform.api.authn.ServiceAccessToken;
import io.casehub.platform.api.authn.ServiceConnection;
import io.casehub.platform.api.authn.ServiceConnectionProvider;
import io.casehub.platform.api.authn.ServiceConnectionStatus;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import java.time.Instant;
import java.util.List;
import java.util.Optional;
import java.util.Set;

import static org.assertj.core.api.Assertions.assertThat;

class ConnectionEndpointCoreTest {

    private ConnectionEndpointCore endpoint;
    private StubConnectionProvider connectionProvider;
    private StubConsentHandler consentHandler;
    private StubScopeRegistry scopeRegistry;

    @BeforeEach
    void setUp() {
        connectionProvider = new StubConnectionProvider();
        consentHandler = new StubConsentHandler();
        scopeRegistry = new StubScopeRegistry();
        endpoint = new ConnectionEndpointCore(connectionProvider, consentHandler, scopeRegistry);
    }

    @Test
    void listConnectionsDelegatesToProvider() {
        connectionProvider.connections = List.of(
                new ServiceConnection("user-1", "google", "tenant-1",
                        ServiceConnectionStatus.CONNECTED,
                        Set.of("email", "calendar"), Set.of(), Instant.now()));

        var result = endpoint.listConnections("user-1", "tenant-1");

        assertThat(result).hasSize(1);
        assertThat(result.get(0).provider()).isEqualTo("google");
    }

    @Test
    void getConnectionDelegatesToProvider() {
        connectionProvider.singleConnection = new ServiceConnection(
                "user-1", "github", "tenant-1",
                ServiceConnectionStatus.PARTIAL,
                Set.of("repo"), Set.of("admin:org"), Instant.now());

        var result = endpoint.getConnection("github", "user-1", "tenant-1");

        assertThat(result.provider()).isEqualTo("github");
        assertThat(result.missingScopes()).containsExactly("admin:org");
    }

    @Test
    void requestConsentDelegatesToHandler() {
        consentHandler.response = new ConsentRequest(
                "https://accounts.google.com/o/oauth2/auth?scope=calendar",
                "google", Set.of("calendar"), "state-123");

        var result = endpoint.requestConsent("google", Set.of("calendar"), "user-1", "tenant-1");

        assertThat(result.provider()).isEqualTo("google");
        assertThat(result.requestedScopes()).containsExactly("calendar");
    }

    @Test
    void disconnectDelegatesToProvider() {
        endpoint.disconnect("github", "user-1", "tenant-1");

        assertThat(connectionProvider.disconnectedProvider).isEqualTo("github");
        assertThat(connectionProvider.disconnectedActor).isEqualTo("user-1");
    }

    @Test
    void listProvidersDelegatesToScopeRegistry() {
        scopeRegistry.providers = Set.of("google", "github", "apple");

        var result = endpoint.listProviders();

        assertThat(result).containsExactlyInAnyOrder("google", "github", "apple");
    }

    // --- stubs ---

    private static class StubConnectionProvider implements ServiceConnectionProvider {
        List<ServiceConnection> connections = List.of();
        ServiceConnection singleConnection;
        String disconnectedProvider;
        String disconnectedActor;

        @Override public ServiceConnection getConnection(String actorId, String provider, String tenancyId) { return singleConnection; }
        @Override public List<ServiceConnection> listConnections(String actorId, String tenancyId) { return connections; }
        @Override public ServiceAccessToken getAccessToken(String actorId, String provider, String tenancyId) { throw new UnsupportedOperationException(); }
        @Override public void disconnect(String actorId, String provider, String tenancyId) { disconnectedActor = actorId; disconnectedProvider = provider; }
        @Override public Set<String> missingScopes(String actorId, String provider, String tenancyId) { return Set.of(); }
    }

    private static class StubConsentHandler implements IncrementalConsentHandler {
        ConsentRequest response;
        @Override public ConsentRequest requestAdditionalScopes(String actorId, String provider, String tenancyId, Set<String> missingScopes) { return response; }
    }

    private static class StubScopeRegistry implements ScopeRegistry {
        Set<String> providers = Set.of();
        @Override public void register(String provider, Set<String> scopes, Class<?> consumer) {}
        @Override public Set<String> requiredScopes(String provider) { return Set.of(); }
        @Override public Set<String> requiredScopes(String provider, Class<?> consumer) { return Set.of(); }
        @Override public boolean satisfies(String provider, Set<String> grantedScopes) { return true; }
        @Override public Set<String> missingScopes(String provider, Set<String> grantedScopes) { return Set.of(); }
        @Override public Set<String> registeredProviders() { return providers; }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mvn test -pl authn-core -Dtest=ConnectionEndpointCoreTest -DfailIfNoTests=false --batch-mode`
Expected: compilation failure — `ConnectionEndpointCore` does not exist yet.

- [ ] **Step 3: Implement ConnectionEndpointCore**

Create `authn-core/src/main/java/io/casehub/platform/authn/ConnectionEndpointCore.java`:

```java
package io.casehub.platform.authn;

import io.casehub.platform.api.authn.ConsentRequest;
import io.casehub.platform.api.authn.IncrementalConsentHandler;
import io.casehub.platform.api.authn.ScopeRegistry;
import io.casehub.platform.api.authn.ServiceConnection;
import io.casehub.platform.api.authn.ServiceConnectionProvider;
import io.casehub.platform.api.mcp.ContextParam;
import io.casehub.platform.api.mcp.HttpMethod;
import io.casehub.platform.api.mcp.McpDomain;
import io.casehub.platform.api.mcp.PathParam;
import io.casehub.platform.api.mcp.PlatformMutation;
import io.casehub.platform.api.mcp.PlatformQuery;
import io.casehub.platform.api.mcp.RestMethod;

import java.util.List;
import java.util.Set;

@McpDomain("connections")
public class ConnectionEndpointCore {

    private final ServiceConnectionProvider connectionProvider;
    private final IncrementalConsentHandler consentHandler;
    private final ScopeRegistry scopeRegistry;

    public ConnectionEndpointCore(ServiceConnectionProvider connectionProvider,
                                  IncrementalConsentHandler consentHandler,
                                  ScopeRegistry scopeRegistry) {
        this.connectionProvider = connectionProvider;
        this.consentHandler = consentHandler;
        this.scopeRegistry = scopeRegistry;
    }

    @PlatformQuery("List all service connections for the current user")
    public List<ServiceConnection> listConnections(
            @ContextParam("actorId") String actorId,
            @ContextParam("tenancyId") String tenancyId) {
        return connectionProvider.listConnections(actorId, tenancyId);
    }

    @PlatformQuery("Get a specific service connection by provider")
    public ServiceConnection getConnection(
            @PathParam String provider,
            @ContextParam("actorId") String actorId,
            @ContextParam("tenancyId") String tenancyId) {
        return connectionProvider.getConnection(actorId, provider, tenancyId);
    }

    @PlatformMutation("Request additional OAuth scopes for a provider")
    public ConsentRequest requestConsent(
            @PathParam String provider,
            Set<String> scopes,
            @ContextParam("actorId") String actorId,
            @ContextParam("tenancyId") String tenancyId) {
        return consentHandler.requestAdditionalScopes(actorId, provider, tenancyId, scopes);
    }

    @PlatformMutation("Disconnect a service connection")
    @RestMethod(HttpMethod.DELETE)
    public void disconnect(
            @PathParam String provider,
            @ContextParam("actorId") String actorId,
            @ContextParam("tenancyId") String tenancyId) {
        connectionProvider.disconnect(actorId, provider, tenancyId);
    }

    @PlatformQuery("List all registered OAuth providers")
    public Set<String> listProviders() {
        return scopeRegistry.registeredProviders();
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mvn test -pl authn-core -Dtest=ConnectionEndpointCoreTest --batch-mode`
Expected: 5 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add authn-core/src/main/java/io/casehub/platform/authn/ConnectionEndpointCore.java
git add authn-core/src/test/java/io/casehub/platform/authn/ConnectionEndpointCoreTest.java
git commit -m "feat(#916): extract ConnectionEndpointCore to authn-core

Constructor-injected POJO with @McpDomain('connections'). Same logic
as the CDI ConnectionEndpoint but framework-neutral."
```

### Task 2: Create WebAuthnEndpointCore in authn-core

**Files:**
- Create: `authn-core/src/main/java/io/casehub/platform/authn/WebAuthnEndpointCore.java`
- Create: `authn-core/src/test/java/io/casehub/platform/authn/WebAuthnEndpointCoreTest.java`

**Interfaces:**
- Consumes: `WebAuthnCredentialStore`, `AuthenticationRouter` from
  `io.casehub.platform.api.authn`; `PrincipalId` from
  `io.casehub.platform.api.identity`
- Produces: `WebAuthnEndpointCore` — constructor-injected POJO with
  `@McpDomain("webauthn")`

- [ ] **Step 1: Write the failing test**

Create `WebAuthnEndpointCoreTest.java` in authn-core. Port all 5 tests
from `authn/WebAuthnEndpointTest.java`, replacing reflection with
constructor injection. Include the ownership check test:

```java
package io.casehub.platform.authn;

import io.casehub.platform.api.authn.AuthenticationContext;
import io.casehub.platform.api.authn.AuthenticationResult;
import io.casehub.platform.api.authn.AuthenticationRouter;
import io.casehub.platform.api.authn.ChallengeResponse;
import io.casehub.platform.api.authn.WebAuthnCredential;
import io.casehub.platform.api.authn.WebAuthnCredentialStore;
import io.casehub.platform.api.identity.PrincipalId;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import java.time.Instant;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Set;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class WebAuthnEndpointCoreTest {

    private WebAuthnEndpointCore endpoint;
    private StubCredentialStore credentialStore;
    private RecordingAuthRouter authRouter;

    @BeforeEach
    void setUp() {
        credentialStore = new StubCredentialStore();
        authRouter = new RecordingAuthRouter();
        endpoint = new WebAuthnEndpointCore(credentialStore, authRouter);
    }

    @Test
    void listCredentialsDelegatesToStore() {
        credentialStore.credentials = List.of(
                new WebAuthnCredential("cred-1", "user-1", "tenant-1",
                        new byte[]{1, 2, 3}, 0, Set.of("usb"), null,
                        "My YubiKey", Instant.now(), null, true));

        var result = endpoint.listCredentials("user-1", "tenant-1");

        assertThat(result).hasSize(1);
        assertThat(result.get(0).displayName()).isEqualTo("My YubiKey");
    }

    @Test
    void deleteCredentialDelegatesToStore() {
        credentialStore.credentials = List.of(
                new WebAuthnCredential("cred-1", "user-1", "tenant-1",
                        new byte[]{1, 2, 3}, 0, Set.of("usb"), null,
                        "My YubiKey", Instant.now(), null, true));

        endpoint.deleteCredential("cred-1", "user-1", "tenant-1");

        assertThat(credentialStore.deletedId).isEqualTo("cred-1");
    }

    @Test
    void deleteCredentialRejectsNonOwner() {
        credentialStore.credentials = List.of(
                new WebAuthnCredential("cred-1", "user-1", "tenant-1",
                        new byte[]{1, 2, 3}, 0, Set.of("usb"), null,
                        "My YubiKey", Instant.now(), null, true));

        assertThatThrownBy(() -> endpoint.deleteCredential("cred-1", "other-user", "tenant-1"))
                .isInstanceOf(SecurityException.class);
    }

    @Test
    void registerOptionsInitiatesWebAuthnFlow() {
        authRouter.challengeResponse = new SimpleChallengeResponse(
                "challenge-123", Instant.now().plusSeconds(300));

        var result = endpoint.registerOptions("https://example.com", "user-1", "tenant-1");

        assertThat(result.challengeId()).isEqualTo("challenge-123");
        assertThat(authRouter.lastContext.method()).isEqualTo("webauthn");
        assertThat(authRouter.lastContext.existingPrincipal())
                .isPresent()
                .get().isEqualTo(PrincipalId.human("user-1"));
    }

    @Test
    void registerCompleteVerifiesAttestation() {
        authRouter.verifyResult = new AuthenticationResult(
                PrincipalId.human("user-1"), "tenant-1",
                Set.of(), "webauthn", Map.of());

        var result = endpoint.registerComplete("challenge-123",
                Map.of("id", "cred-1"), "tenant-1");

        assertThat(result.principal()).isEqualTo(PrincipalId.human("user-1"));
        assertThat(authRouter.lastVerifyMethod).isEqualTo("webauthn");
    }

    // --- stubs ---

    private record SimpleChallengeResponse(String challengeId, Instant expiresAt) implements ChallengeResponse {}

    private static class StubCredentialStore implements WebAuthnCredentialStore {
        List<WebAuthnCredential> credentials = List.of();
        String deletedId;

        @Override public void store(WebAuthnCredential credential) {}
        @Override public Optional<WebAuthnCredential> findByCredentialId(String credentialId) {
            return credentials.stream().filter(c -> c.credentialId().equals(credentialId)).findFirst();
        }
        @Override public List<WebAuthnCredential> findByActorId(String actorId, String tenancyId) { return credentials; }
        @Override public void updateAfterAuthentication(String credentialId, long newSignCount, Instant lastUsedAt) {}
        @Override public void delete(String credentialId) { deletedId = credentialId; }
    }

    private static class RecordingAuthRouter implements AuthenticationRouter {
        ChallengeResponse challengeResponse;
        AuthenticationResult verifyResult;
        AuthenticationContext lastContext;
        String lastVerifyMethod;

        @Override public ChallengeResponse initiate(AuthenticationContext context) { lastContext = context; return challengeResponse; }
        @Override public AuthenticationResult verify(String method, String challengeId, Map<String, Object> data) { lastVerifyMethod = method; return verifyResult; }
        @Override public Set<String> availableMethods() { return Set.of("webauthn"); }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mvn test -pl authn-core -Dtest=WebAuthnEndpointCoreTest -DfailIfNoTests=false --batch-mode`
Expected: compilation failure.

- [ ] **Step 3: Implement WebAuthnEndpointCore**

Create `authn-core/src/main/java/io/casehub/platform/authn/WebAuthnEndpointCore.java`:

```java
package io.casehub.platform.authn;

import io.casehub.platform.api.authn.AuthenticationContext;
import io.casehub.platform.api.authn.AuthenticationResult;
import io.casehub.platform.api.authn.AuthenticationRouter;
import io.casehub.platform.api.authn.ChallengeResponse;
import io.casehub.platform.api.authn.WebAuthnCredential;
import io.casehub.platform.api.authn.WebAuthnCredentialStore;
import io.casehub.platform.api.identity.PrincipalId;
import io.casehub.platform.api.mcp.ContextParam;
import io.casehub.platform.api.mcp.HttpMethod;
import io.casehub.platform.api.mcp.McpDomain;
import io.casehub.platform.api.mcp.PathParam;
import io.casehub.platform.api.mcp.PlatformMutation;
import io.casehub.platform.api.mcp.PlatformQuery;
import io.casehub.platform.api.mcp.RestMethod;

import java.util.List;
import java.util.Map;
import java.util.Optional;

@McpDomain("webauthn")
public class WebAuthnEndpointCore {

    private final WebAuthnCredentialStore credentialStore;
    private final AuthenticationRouter authenticationRouter;

    public WebAuthnEndpointCore(WebAuthnCredentialStore credentialStore,
                                AuthenticationRouter authenticationRouter) {
        this.credentialStore = credentialStore;
        this.authenticationRouter = authenticationRouter;
    }

    @PlatformQuery("List WebAuthn credentials for the current user")
    public List<WebAuthnCredential> listCredentials(
            @ContextParam("actorId") String actorId,
            @ContextParam("tenancyId") String tenancyId) {
        return credentialStore.findByActorId(actorId, tenancyId);
    }

    @PlatformMutation("Delete a WebAuthn credential")
    @RestMethod(HttpMethod.DELETE)
    public void deleteCredential(
            @PathParam String credentialId,
            @ContextParam("actorId") String actorId,
            @ContextParam("tenancyId") String tenancyId) {
        credentialStore.findByCredentialId(credentialId)
                       .filter(c -> c.actorId().equals(actorId) && c.tenancyId().equals(tenancyId))
                       .ifPresentOrElse(
                               c -> credentialStore.delete(credentialId),
                               () -> { throw new SecurityException(
                                       "Credential not found or not owned by current user"); });
    }

    @PlatformMutation("Generate WebAuthn registration options")
    public ChallengeResponse registerOptions(
            String origin,
            @ContextParam("actorId") String actorId,
            @ContextParam("tenancyId") String tenancyId) {
        return authenticationRouter.initiate(new AuthenticationContext(
                "webauthn", tenancyId, origin,
                Optional.of(PrincipalId.human(actorId)),
                Map.of()));
    }

    @PlatformMutation("Complete WebAuthn registration")
    public AuthenticationResult registerComplete(
            String challengeId,
            Map<String, Object> attestation,
            @ContextParam("tenancyId") String tenancyId) {
        return authenticationRouter.verify("webauthn", challengeId, attestation);
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mvn test -pl authn-core -Dtest=WebAuthnEndpointCoreTest --batch-mode`
Expected: 5 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add authn-core/src/main/java/io/casehub/platform/authn/WebAuthnEndpointCore.java
git add authn-core/src/test/java/io/casehub/platform/authn/WebAuthnEndpointCoreTest.java
git commit -m "feat(#916): extract WebAuthnEndpointCore to authn-core

Constructor-injected POJO with @McpDomain('webauthn'). Includes
ownership check on deleteCredential."
```

### Task 3: Create SocialAuthEndpointCore in authn-core

**Files:**
- Create: `authn-core/src/main/java/io/casehub/platform/authn/SocialAuthEndpointCore.java`
- Create: `authn-core/src/test/java/io/casehub/platform/authn/SocialAuthEndpointCoreTest.java`

**Interfaces:**
- Consumes: `AuthenticationRouter` from `io.casehub.platform.api.authn`
- Produces: `SocialAuthEndpointCore` — constructor-injected POJO with
  `@McpDomain("social-auth")`

- [ ] **Step 1: Write the failing test**

Create `SocialAuthEndpointCoreTest.java` in authn-core. Port all 3 tests
from `authn/SocialAuthEndpointTest.java`:

```java
package io.casehub.platform.authn;

import io.casehub.platform.api.authn.AuthenticationContext;
import io.casehub.platform.api.authn.AuthenticationResult;
import io.casehub.platform.api.authn.AuthenticationRouter;
import io.casehub.platform.api.authn.ChallengeResponse;
import io.casehub.platform.api.identity.PrincipalId;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import java.time.Instant;
import java.util.Map;
import java.util.Set;

import static org.assertj.core.api.Assertions.assertThat;

class SocialAuthEndpointCoreTest {

    private SocialAuthEndpointCore endpoint;
    private RecordingAuthRouter authRouter;

    @BeforeEach
    void setUp() {
        authRouter = new RecordingAuthRouter();
        endpoint = new SocialAuthEndpointCore(authRouter);
    }

    @Test
    void authorizeInitiatesOAuthFlow() {
        authRouter.challengeResponse = new SimpleChallengeResponse(
                "challenge-456", Instant.now().plusSeconds(600));

        var result = endpoint.authorize("google", "https://app.example.com", "tenant-1");

        assertThat(result.challengeId()).isEqualTo("challenge-456");
        assertThat(authRouter.lastContext.method()).isEqualTo("google");
        assertThat(authRouter.lastContext.tenancyId()).isEqualTo("tenant-1");
        assertThat(authRouter.lastContext.existingPrincipal()).isEmpty();
    }

    @Test
    void callbackVerifiesOAuthCode() {
        authRouter.verifyResult = new AuthenticationResult(
                PrincipalId.human("user-1"), "tenant-1",
                Set.of("users"), "google", Map.of());

        var result = endpoint.callback("google", "auth-code-xyz", "state-abc", "tenant-1");

        assertThat(result.principal()).isEqualTo(PrincipalId.human("user-1"));
        assertThat(authRouter.lastVerifyMethod).isEqualTo("google");
        assertThat(authRouter.lastVerifyData).containsEntry("code", "auth-code-xyz");
    }

    @Test
    void authorizeWithDifferentProviders() {
        authRouter.challengeResponse = new SimpleChallengeResponse(
                "gh-challenge", Instant.now().plusSeconds(600));

        endpoint.authorize("github", "https://app.example.com", "tenant-1");
        assertThat(authRouter.lastContext.method()).isEqualTo("github");

        endpoint.authorize("apple", "https://app.example.com", "tenant-1");
        assertThat(authRouter.lastContext.method()).isEqualTo("apple");
    }

    // --- stubs ---

    private record SimpleChallengeResponse(String challengeId, Instant expiresAt) implements ChallengeResponse {}

    private static class RecordingAuthRouter implements AuthenticationRouter {
        ChallengeResponse challengeResponse;
        AuthenticationResult verifyResult;
        AuthenticationContext lastContext;
        String lastVerifyMethod;
        Map<String, Object> lastVerifyData;

        @Override public ChallengeResponse initiate(AuthenticationContext context) { lastContext = context; return challengeResponse; }
        @Override public AuthenticationResult verify(String method, String challengeId, Map<String, Object> data) {
            lastVerifyMethod = method; lastVerifyData = data; return verifyResult;
        }
        @Override public Set<String> availableMethods() { return Set.of("google", "github", "apple"); }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mvn test -pl authn-core -Dtest=SocialAuthEndpointCoreTest -DfailIfNoTests=false --batch-mode`
Expected: compilation failure.

- [ ] **Step 3: Implement SocialAuthEndpointCore**

Create `authn-core/src/main/java/io/casehub/platform/authn/SocialAuthEndpointCore.java`:

```java
package io.casehub.platform.authn;

import io.casehub.platform.api.authn.AuthenticationContext;
import io.casehub.platform.api.authn.AuthenticationResult;
import io.casehub.platform.api.authn.AuthenticationRouter;
import io.casehub.platform.api.authn.ChallengeResponse;
import io.casehub.platform.api.mcp.ContextParam;
import io.casehub.platform.api.mcp.McpDomain;
import io.casehub.platform.api.mcp.PathParam;
import io.casehub.platform.api.mcp.PlatformMutation;

import java.util.Map;
import java.util.Optional;

@McpDomain("social-auth")
public class SocialAuthEndpointCore {

    private final AuthenticationRouter authenticationRouter;

    public SocialAuthEndpointCore(AuthenticationRouter authenticationRouter) {
        this.authenticationRouter = authenticationRouter;
    }

    @PlatformMutation("Initiate OAuth authorization flow for a social provider")
    public ChallengeResponse authorize(
            @PathParam String provider,
            String origin,
            @ContextParam("tenancyId") String tenancyId) {
        return authenticationRouter.initiate(new AuthenticationContext(
                provider, tenancyId, origin,
                Optional.empty(),
                Map.of()));
    }

    @PlatformMutation("Complete OAuth callback for a social provider")
    public AuthenticationResult callback(
            @PathParam String provider,
            String code,
            String state,
            @ContextParam("tenancyId") String tenancyId) {
        return authenticationRouter.verify(provider, state, Map.of("code", code));
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mvn test -pl authn-core -Dtest=SocialAuthEndpointCoreTest --batch-mode`
Expected: 3 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add authn-core/src/main/java/io/casehub/platform/authn/SocialAuthEndpointCore.java
git add authn-core/src/test/java/io/casehub/platform/authn/SocialAuthEndpointCoreTest.java
git commit -m "feat(#916): extract SocialAuthEndpointCore to authn-core

Constructor-injected POJO with @McpDomain('social-auth'). OAuth
authorize and callback flows."
```

---

## Batch 2: Wire CDI and Spring, delete old endpoints

### Task 4: Wire core POJOs in AuthnBeans and delete CDI endpoints

**Files:**
- Modify: `authn/src/main/java/io/casehub/platform/authn/quarkus/AuthnBeans.java`
  — add 3 `@Produces` methods for core POJOs
- Delete: `authn/src/main/java/io/casehub/platform/authn/quarkus/ConnectionEndpoint.java`
- Delete: `authn/src/main/java/io/casehub/platform/authn/quarkus/WebAuthnEndpoint.java`
- Delete: `authn/src/main/java/io/casehub/platform/authn/quarkus/SocialAuthEndpoint.java`
- Delete: `authn/src/test/java/io/casehub/platform/authn/ConnectionEndpointTest.java`
- Delete: `authn/src/test/java/io/casehub/platform/authn/WebAuthnEndpointTest.java`
- Delete: `authn/src/test/java/io/casehub/platform/authn/SocialAuthEndpointTest.java`

**Interfaces:**
- Consumes: `ConnectionEndpointCore`, `WebAuthnEndpointCore`,
  `SocialAuthEndpointCore` from authn-core
- Produces: CDI beans of the three core POJOs (consumed by generated
  JAX-RS resources)

- [ ] **Step 1: Add @Produces methods to AuthnBeans**

Add three methods at the end of `AuthnBeans.java`:

```java
@Produces
@ApplicationScoped
public ConnectionEndpointCore connectionEndpointCore(
        io.casehub.platform.authn.social.ServiceConnectionProviderCore connectionProvider,
        io.casehub.platform.authn.social.IncrementalConsentHandlerCore consentHandler,
        io.casehub.platform.authn.ScopeRegistryCore scopeRegistry) {
    return new ConnectionEndpointCore(connectionProvider, consentHandler, scopeRegistry);
}

@Produces
@ApplicationScoped
public WebAuthnEndpointCore webAuthnEndpointCore(
        WebAuthnCredentialStore credentialStore,
        AuthenticationRouterCore authenticationRouter) {
    return new WebAuthnEndpointCore(credentialStore, authenticationRouter);
}

@Produces
@ApplicationScoped
public SocialAuthEndpointCore socialAuthEndpointCore(
        AuthenticationRouterCore authenticationRouter) {
    return new SocialAuthEndpointCore(authenticationRouter);
}
```

Add required imports for `ConnectionEndpointCore`, `WebAuthnEndpointCore`,
`SocialAuthEndpointCore`.

- [ ] **Step 2: Delete CDI endpoint classes and their tests**

Use `ide_refactor_safe_delete` for each CDI endpoint class:
- `ConnectionEndpoint`
- `WebAuthnEndpoint`
- `SocialAuthEndpoint`

Delete the test files:
- `authn/src/test/java/io/casehub/platform/authn/ConnectionEndpointTest.java`
- `authn/src/test/java/io/casehub/platform/authn/WebAuthnEndpointTest.java`
- `authn/src/test/java/io/casehub/platform/authn/SocialAuthEndpointTest.java`

(The E2E test `ServiceConnectionE2ETest.java` does NOT reference the
endpoint classes — it stays.)

- [ ] **Step 3: Rebuild authn module to verify APT regeneration**

Run: `mvn compile -pl authn-core,authn --batch-mode`

Verify the generated JAX-RS resources now inject core POJOs. Check:
`authn/target/generated-sources/annotations/io/casehub/platform/authn/quarkus/rest/`
should contain `ConnectionsResource.java`, `WebauthnResource.java`,
`SocialAuthResource.java` — now injecting `ConnectionEndpointCore` etc.
instead of the deleted CDI endpoint classes.

- [ ] **Step 4: Run all authn tests**

Run: `mvn test -pl authn-core,authn --batch-mode`
Expected: all tests pass (core tests + E2E test).

- [ ] **Step 5: Commit**

```bash
git add authn/src/main/java/io/casehub/platform/authn/quarkus/AuthnBeans.java
git rm authn/src/main/java/io/casehub/platform/authn/quarkus/ConnectionEndpoint.java
git rm authn/src/main/java/io/casehub/platform/authn/quarkus/WebAuthnEndpoint.java
git rm authn/src/main/java/io/casehub/platform/authn/quarkus/SocialAuthEndpoint.java
git rm authn/src/test/java/io/casehub/platform/authn/ConnectionEndpointTest.java
git rm authn/src/test/java/io/casehub/platform/authn/WebAuthnEndpointTest.java
git rm authn/src/test/java/io/casehub/platform/authn/SocialAuthEndpointTest.java
git commit -m "refactor(#916): wire core POJOs in AuthnBeans, delete CDI endpoints

AuthnBeans now @Produces the three endpoint core POJOs. The APT
regenerates JAX-RS resources injecting the core types. Tests migrated
to authn-core in previous commits."
```

### Task 5: Configure graphql-spring-generator and wire Spring beans

**Files:**
- Modify: `authn-spring/pom.xml` — add graphql-spring-generator plugin
  + spring-webmvc dependency
- Modify: `authn-spring/src/main/java/io/casehub/platform/authn/spring/AuthnSpringAutoConfiguration.java`
  — add 3 `@Bean` methods for core POJOs

**Interfaces:**
- Consumes: `ConnectionEndpointCore`, `WebAuthnEndpointCore`,
  `SocialAuthEndpointCore` from authn-core
- Produces: Spring beans of the three core POJOs + generated Spring MVC
  REST controllers

- [ ] **Step 1: Add spring-webmvc dependency and graphql-spring-generator plugin to authn-spring/pom.xml**

Add dependency after `spring-boot-autoconfigure`:

```xml
<dependency>
    <groupId>org.springframework</groupId>
    <artifactId>spring-webmvc</artifactId>
</dependency>
```

Add plugin inside `<build><plugins>`:

```xml
<build>
    <plugins>
        <plugin>
            <groupId>io.casehub</groupId>
            <artifactId>casehub-platform-graphql-spring-generator</artifactId>
            <version>${project.version}</version>
            <executions>
                <execution>
                    <id>generate</id>
                    <goals><goal>generate</goal></goals>
                    <configuration>
                        <quarkusModules>
                            <quarkusModule>${project.basedir}/../authn-core</quarkusModule>
                        </quarkusModules>
                    </configuration>
                </execution>
                <execution>
                    <id>verify-drift</id>
                    <goals><goal>verify</goal></goals>
                    <phase>verify</phase>
                    <configuration>
                        <quarkusModules>
                            <quarkusModule>${project.basedir}/../authn-core</quarkusModule>
                        </quarkusModules>
                    </configuration>
                </execution>
            </executions>
        </plugin>
    </plugins>
</build>
```

- [ ] **Step 2: Add @Bean methods to AuthnSpringAutoConfiguration**

Add three methods at the end of `AuthnSpringAutoConfiguration.java`:

```java
@Bean
@ConditionalOnMissingBean
public ConnectionEndpointCore connectionEndpointCore(
        io.casehub.platform.authn.social.ServiceConnectionProviderCore connectionProvider,
        io.casehub.platform.authn.social.IncrementalConsentHandlerCore consentHandler,
        io.casehub.platform.authn.ScopeRegistryCore scopeRegistry) {
    return new ConnectionEndpointCore(connectionProvider, consentHandler, scopeRegistry);
}

@Bean
@ConditionalOnMissingBean
public WebAuthnEndpointCore webAuthnEndpointCore(
        io.casehub.platform.api.authn.WebAuthnCredentialStore credentialStore,
        AuthenticationRouterCore authenticationRouter) {
    return new WebAuthnEndpointCore(credentialStore, authenticationRouter);
}

@Bean
@ConditionalOnMissingBean
public SocialAuthEndpointCore socialAuthEndpointCore(
        AuthenticationRouterCore authenticationRouter) {
    return new SocialAuthEndpointCore(authenticationRouter);
}
```

Add required imports for `ConnectionEndpointCore`, `WebAuthnEndpointCore`,
`SocialAuthEndpointCore`.

- [ ] **Step 3: Build authn-spring and verify generation**

Run: `mvn compile -pl authn-core,authn-spring --batch-mode`

Verify generated files exist in
`authn-spring/target/generated-sources/graphql-spring-generator/`.
Expect 6 files (3 GraphQL controllers + 3 REST controllers):
- `ConnectionsGraphqlController.java`
- `ConnectionsRestController.java`
- `WebauthnGraphqlController.java`
- `WebauthnRestController.java`
- `SocialAuthGraphqlController.java`
- `SocialAuthRestController.java`

- [ ] **Step 4: Run full build for authn module family**

Run: `mvn test -pl authn-core,authn,authn-spring --batch-mode`
Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add authn-spring/pom.xml
git add authn-spring/src/main/java/io/casehub/platform/authn/spring/AuthnSpringAutoConfiguration.java
git commit -m "feat(#916): add graphql-spring-generator and Spring bean wiring

Configures graphql-spring-generator in authn-spring scanning authn-core.
Generates Spring MVC REST controllers for connections, webauthn, and
social-auth domains. Adds @Bean producers for the three endpoint core
POJOs. Refs #916"
```

---

## Batch 3: Full build verification and CLAUDE.md update

### Task 6: Full build verification and CLAUDE.md update

**Files:**
- Verify: full Maven build passes
- Modify: `CLAUDE.md` — update authn and authn-spring module descriptions

- [ ] **Step 1: Run full build**

Run: `mvn --batch-mode install`
Expected: BUILD SUCCESS. All tests pass across the entire project.

- [ ] **Step 2: Update CLAUDE.md module descriptions**

Update the `authn-core/` description to mention the three endpoint core
POJOs. Update the `authn-spring/` description to mention the
graphql-spring-generator and generated REST controllers.

In the `authn/` description, note that REST endpoints are now generated
from core POJOs in authn-core (not from CDI endpoint classes).

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md
git commit -m "docs(#916): update module descriptions for authn core extraction

Reflects endpoint core POJOs in authn-core and graphql-spring-generator
in authn-spring."
```

---

## References

- [ConnectionEndpoint.java] — original CDI endpoint (authn/src/main/java)
- [WebAuthnEndpoint.java] — original CDI endpoint (authn/src/main/java)
- [SocialAuthEndpoint.java] — original CDI endpoint (authn/src/main/java)
- [AuthnBeans.java] — CDI producer class (authn/src/main/java)
- [AuthnSpringAutoConfiguration.java] — Spring auto-config (authn-spring)
- [platform-spring/pom.xml] — graphql-spring-generator config pattern
- [AclRestController.java] — generated Spring REST controller example
- [GitHub #916] — focal issue
