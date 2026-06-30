# ScimDIDResolver Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement composite DID resolution with SCIM-backed DIDDocument synthesis, per reviewed spec `docs/superpowers/specs/2026-06-29-scim-did-resolver-design.md`.

**Architecture:** Change `DIDResolver.resolve(String did)` to `resolve(String actorId, String did)`. Replace `@Alternative` single-resolver CDI pattern with `@DIDMethod` qualifier + `CompositeDIDResolver` that iterates resolvers by `@Priority`. Add `ScimAgentLookup` as shared SCIM client, `ScimDIDResolver` as SCIM-backed resolver. Move `NoOpDIDResolver` to `platform/` module.

**Tech Stack:** Java 21, Quarkus (ARC CDI), java.net.http.HttpClient, java.security.cert.CertificateFactory, WireMock (tests)

## Global Constraints

- `platform-api/` must remain zero-dependency — no Quarkus, no JPA. `@DIDMethod` uses only `jakarta.inject` annotations (already present).
- All identity SPI implementations live in `identity/` module — library JAR, no quarkus:build goal.
- `@DefaultBean` mocks belong in `platform/` module per convention. `NoOpDIDResolver` moves there.
- Use IntelliJ MCP for all renames, moves, and reference lookups — never bash grep.
- TDD: write failing test first, then implement. Every task ends with green tests.
- Protocols: `persistence-backend-cdi-priority.md`, `module-tier-structure.md`, `spi-signature-change-all-impls-same-commit.md`, `no-workarounds-fix-the-design.md`, `platform-spi-contract.md`.

---

### Task 1: DIDResolver SPI change + @DIDMethod qualifier + annotation migration

**Atomic refactoring.** The method signature change must update all implementations, callers, and tests in one commit. Existing behavior is preserved — actorId is added but ignored by current resolvers.

**Files:**
- Modify: `platform-api/src/main/java/io/casehub/platform/api/identity/DIDResolver.java`
- Create: `platform-api/src/main/java/io/casehub/platform/api/identity/DIDMethod.java`
- Move: `identity/.../NoOpDIDResolver.java` → `platform/src/main/java/io/casehub/platform/identity/NoOpDIDResolver.java`
- Modify: `identity/.../WebDIDResolver.java` — `@Alternative` → `@DIDMethod @Priority(100)`, add actorId param
- Modify: `identity/.../KeyDIDResolver.java` — `@Alternative` → `@DIDMethod @Priority(100)`, add actorId param
- Modify: `identity/.../JwtVCValidator.java` — resolve(null, issuerDid), update lambda constructors
- Modify: `identity/.../AgentIdentityVerificationService.java` — resolve(actorId, actorDid)
- Modify: `identity/src/test/.../JwtVCValidatorTest.java` — update lambda signatures

**Interfaces:**
- Produces: `DIDResolver.resolve(String actorId, String did)` — all downstream tasks depend on this signature
- Produces: `@DIDMethod` qualifier — used by Task 2 (CompositeDIDResolver) and Task 4 (ScimDIDResolver)

- [ ] **Step 1: Change DIDResolver interface**

Use IntelliJ to change the method signature — adds `actorId` parameter and updates all implementations and callers automatically.

```java
// platform-api/.../DIDResolver.java — full replacement
package io.casehub.platform.api.identity;

import java.util.Optional;

/**
 * Resolves a DID URI to a DID document.
 *
 * <p>Return empty when the DID is unresolvable — for example when the method is
 * unsupported, the network is unreachable, or the document does not exist.
 * Implementations MUST NOT throw — return empty for any failure case.
 *
 * <p>Implementations are CDI beans annotated with {@code @DIDMethod}.
 * The composite resolver iterates all {@code @DIDMethod} resolvers
 * in {@code @Priority} order, returning the first non-empty result.
 *
 * @param actorId the actor that claims this DID, or {@code null} when the actor is
 *                unknown (e.g., resolving a credential issuer's DID for VC validation)
 * @param did     the DID URI to resolve (e.g. {@code "did:web:example.com:agents:tarkus"})
 */
public interface DIDResolver {

    Optional<DIDDocument> resolve(String actorId, String did);
}
```

- [ ] **Step 2: Create @DIDMethod qualifier**

```java
// platform-api/.../DIDMethod.java
package io.casehub.platform.api.identity;

import jakarta.inject.Qualifier;
import java.lang.annotation.Retention;
import java.lang.annotation.RetentionPolicy;
import java.lang.annotation.Target;
import static java.lang.annotation.ElementType.*;

/**
 * CDI qualifier for individual DID method resolvers.
 *
 * <p>Beans annotated {@code @DIDMethod} are discovered by the composite
 * resolver and iterated in {@code @Priority} order. Consumer code injects
 * the unqualified {@code DIDResolver} to get the composite.
 */
@Qualifier
@Retention(RetentionPolicy.RUNTIME)
@Target({TYPE, METHOD, FIELD, PARAMETER})
public @interface DIDMethod {}
```

- [ ] **Step 3: Move NoOpDIDResolver to platform/ module**

Use IntelliJ `ide_move_file` to move `identity/.../NoOpDIDResolver.java` to `platform/src/main/java/io/casehub/platform/identity/`. IntelliJ updates imports and references. Verify the new package is `io.casehub.platform.identity`. Update the method signature to include actorId.

```java
// platform/.../identity/NoOpDIDResolver.java
package io.casehub.platform.identity;

import io.casehub.platform.api.identity.DIDDocument;
import io.casehub.platform.api.identity.DIDResolver;
import io.quarkus.arc.DefaultBean;
import jakarta.enterprise.context.ApplicationScoped;

import java.util.Optional;

/** Default no-op. Resolves nothing — DID verification is skipped. */
@ApplicationScoped
@DefaultBean
public class NoOpDIDResolver implements DIDResolver {
    @Override
    public Optional<DIDDocument> resolve(final String actorId, final String did) {
        return Optional.empty();
    }
}
```

- [ ] **Step 4: Update WebDIDResolver annotations and signature**

Change `@Alternative` to `@DIDMethod @Priority(100)`. Add actorId parameter (ignored).

```java
// Key changes in WebDIDResolver.java
import io.casehub.platform.api.identity.DIDMethod;
import jakarta.annotation.Priority;
// Remove: import jakarta.enterprise.inject.Alternative;

@ApplicationScoped
@DIDMethod
@Priority(100)
public class WebDIDResolver implements DIDResolver {
    // ...
    @Override
    public Optional<DIDDocument> resolve(final String actorId, final String did) {
        // existing body unchanged — actorId ignored
    }
}
```

- [ ] **Step 5: Update KeyDIDResolver annotations and signature**

Same pattern as WebDIDResolver.

```java
import io.casehub.platform.api.identity.DIDMethod;
import jakarta.annotation.Priority;

@ApplicationScoped
@DIDMethod
@Priority(100)
public class KeyDIDResolver implements DIDResolver {
    @Override
    public Optional<DIDDocument> resolve(final String actorId, final String did) {
        // existing body unchanged
    }
}
```

- [ ] **Step 6: Update JwtVCValidator**

Three changes: (a) update no-arg constructor lambda, (b) update `resolverReturning` lambda, (c) pass `null` as actorId at the resolve call site.

```java
// Line 50 — no-arg constructor
this.resolver = (actorId, did) -> Optional.empty();

// Line 131 — loadAndValidate
final Optional<DIDDocument> issuerDoc = resolver.resolve(null, issuerDid);
```

- [ ] **Step 7: Update AgentIdentityVerificationService**

```java
// Line 46
final var docOpt = resolver.resolve(actorId, actorDid);
```

- [ ] **Step 8: Update JwtVCValidatorTest lambdas**

```java
// Line 73-75 — resolverReturning helper
private DIDResolver resolverReturning(final DIDDocument doc) {
    return (actorId, did) -> ISSUER_DID.equals(did)
            ? Optional.ofNullable(doc) : Optional.empty();
}

// Line 95 — unconfigured_actor_returns_empty
final var validator = createValidator(Map.of(), (actorId, did) -> Optional.empty());

// Line 159 — unknown_issuer_returns_ISSUER_UNKNOWN
(actorId, did) -> Optional.empty());
```

- [ ] **Step 9: Build and run all tests**

Run: `mvn --batch-mode test -pl platform-api,platform,identity`
Expected: All existing tests pass. No compilation errors.

- [ ] **Step 10: Commit**

```
feat(platform#85): DIDResolver SPI — add actorId parameter, @DIDMethod qualifier, composite-ready annotations

Breaking: resolve(String did) → resolve(String actorId, String did).
WebDIDResolver/KeyDIDResolver: @Alternative → @DIDMethod @Priority(100).
NoOpDIDResolver moved to platform/ module per @DefaultBean convention.
JwtVCValidator passes null actorId for issuer DID resolution.
```

---

### Task 2: CompositeDIDResolver

**Files:**
- Create: `identity/src/main/java/io/casehub/platform/identity/CompositeDIDResolver.java`
- Create: `identity/src/test/java/io/casehub/platform/identity/CompositeDIDResolverTest.java`

**Interfaces:**
- Consumes: `DIDResolver.resolve(String actorId, String did)` from Task 1
- Consumes: `@DIDMethod` qualifier from Task 1
- Produces: `CompositeDIDResolver` — unqualified `DIDResolver` bean that iterates `@DIDMethod` resolvers

- [ ] **Step 1: Write failing tests**

```java
package io.casehub.platform.identity;

import io.casehub.platform.api.identity.DIDDocument;
import io.casehub.platform.api.identity.DIDResolver;
import io.casehub.platform.api.identity.VerificationMethod;
import org.junit.jupiter.api.Test;

import java.util.List;
import java.util.Optional;

import static org.junit.jupiter.api.Assertions.*;

class CompositeDIDResolverTest {

    private static final String ACTOR = "claude:reviewer@v1";
    private static final String DID = "did:web:example.com:agents:reviewer";

    private static DIDDocument doc(String id) {
        return new DIDDocument(id, List.of(), List.of());
    }

    @Test
    void empty_resolvers_returns_empty() {
        var composite = new CompositeDIDResolver(List.of());
        assertTrue(composite.resolve(ACTOR, DID).isEmpty());
    }

    @Test
    void delegates_to_single_resolver() {
        DIDResolver r = (actorId, did) -> Optional.of(doc(did));
        var composite = new CompositeDIDResolver(List.of(r));
        var result = composite.resolve(ACTOR, DID);
        assertTrue(result.isPresent());
        assertEquals(DID, result.get().id());
    }

    @Test
    void returns_first_non_empty_result() {
        DIDResolver empty = (actorId, did) -> Optional.empty();
        DIDResolver found = (actorId, did) -> Optional.of(doc("found"));
        DIDResolver never = (actorId, did) -> { fail("Should not be called"); return Optional.empty(); };

        var composite = new CompositeDIDResolver(List.of(empty, found, never));
        assertEquals("found", composite.resolve(ACTOR, DID).orElseThrow().id());
    }

    @Test
    void catches_exception_and_continues() {
        DIDResolver throwing = (actorId, did) -> { throw new RuntimeException("SCIM down"); };
        DIDResolver fallback = (actorId, did) -> Optional.of(doc("fallback"));

        var composite = new CompositeDIDResolver(List.of(throwing, fallback));
        assertEquals("fallback", composite.resolve(ACTOR, DID).orElseThrow().id());
    }

    @Test
    void all_throw_returns_empty() {
        DIDResolver t1 = (actorId, did) -> { throw new RuntimeException("fail 1"); };
        DIDResolver t2 = (actorId, did) -> { throw new RuntimeException("fail 2"); };

        var composite = new CompositeDIDResolver(List.of(t1, t2));
        assertTrue(composite.resolve(ACTOR, DID).isEmpty());
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn --batch-mode test -pl identity -Dtest=CompositeDIDResolverTest`
Expected: FAIL — `CompositeDIDResolver` class not found.

- [ ] **Step 3: Implement CompositeDIDResolver**

```java
package io.casehub.platform.identity;

import io.casehub.platform.api.identity.DIDDocument;
import io.casehub.platform.api.identity.DIDMethod;
import io.casehub.platform.api.identity.DIDResolver;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.enterprise.inject.Any;
import jakarta.enterprise.inject.Instance;
import jakarta.inject.Inject;
import org.jboss.logging.Logger;

import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;
import java.util.Optional;

/**
 * Composite DID resolver — iterates {@code @DIDMethod}-qualified resolvers
 * in {@code @Priority} order, returning the first non-empty result.
 *
 * <p>Consumers inject the unqualified {@code DIDResolver} and get this bean
 * (beats {@code NoOpDIDResolver @DefaultBean}).
 */
@ApplicationScoped
public class CompositeDIDResolver implements DIDResolver {

    private static final Logger LOG = Logger.getLogger(CompositeDIDResolver.class);

    private final List<DIDResolver> resolvers;

    @Inject
    public CompositeDIDResolver(@DIDMethod Instance<DIDResolver> methodResolvers) {
        this(toSortedList(methodResolvers));
    }

    CompositeDIDResolver(List<DIDResolver> resolvers) {
        this.resolvers = resolvers;
    }

    @Override
    public Optional<DIDDocument> resolve(final String actorId, final String did) {
        for (final DIDResolver r : resolvers) {
            try {
                final Optional<DIDDocument> result = r.resolve(actorId, did);
                if (result.isPresent()) return result;
            } catch (final Exception e) {
                LOG.warnf("Resolver %s failed for DID %s: %s",
                        r.getClass().getSimpleName(), did, e.getMessage());
            }
        }
        return Optional.empty();
    }

    private static List<DIDResolver> toSortedList(Instance<DIDResolver> instance) {
        var list = new ArrayList<DIDResolver>();
        instance.forEach(list::add);
        list.sort(Comparator.comparingInt(CompositeDIDResolver::priorityOf));
        return List.copyOf(list);
    }

    private static int priorityOf(DIDResolver resolver) {
        var priority = resolver.getClass().getAnnotation(jakarta.annotation.Priority.class);
        return priority != null ? priority.value() : Integer.MAX_VALUE;
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mvn --batch-mode test -pl identity -Dtest=CompositeDIDResolverTest`
Expected: All 5 tests PASS.

- [ ] **Step 5: Commit**

```
feat(platform#85): CompositeDIDResolver — priority-ordered multi-resolver pipeline
```

---

### Task 3: ScimAgentLookup + ScimActorDIDProvider refactor

Extract shared SCIM HTTP client into `ScimAgentLookup`. Enhance `ScimAgentResource` with certificate data. Refactor `ScimActorDIDProvider` to delegate.

**Files:**
- Modify: `identity/.../ScimAgentResource.java` — add `derCertificates`
- Create: `identity/.../ScimAgentLookup.java` — shared SCIM client + cache
- Modify: `identity/.../ScimActorDIDProvider.java` — delegate to ScimAgentLookup
- Create: `identity/src/test/.../ScimAgentLookupTest.java`
- Modify: `identity/src/test/.../ScimActorDIDProviderValidationTest.java`

**Interfaces:**
- Consumes: `AbstractCachingIdentityProvider<ScimAgentResource>` (existing)
- Produces: `ScimAgentLookup.get(String actorId) → Optional<ScimAgentResource>` — used by Task 4
- Produces: `ScimAgentLookup.isConfigured() → boolean` — used by Task 4
- Produces: `ScimAgentResource(String did, List<byte[]> derCertificates)` — used by Task 4

- [ ] **Step 1: Enhance ScimAgentResource**

```java
package io.casehub.platform.identity;

import java.util.List;

/**
 * Cached result of a SCIM2 agent lookup.
 *
 * <p>Contains the DID string and DER-encoded X.509 certificates from SCIM
 * {@code x509Certificates[].value}. Certificates carry the agent's public
 * key material — extract via {@code CertificateFactory.getInstance("X.509")}.
 */
public record ScimAgentResource(String did, List<byte[]> derCertificates) {
    public ScimAgentResource {
        derCertificates = derCertificates == null ? List.of() : List.copyOf(derCertificates);
    }
}
```

- [ ] **Step 2: Write ScimAgentLookup tests**

```java
package io.casehub.platform.identity;

import org.junit.jupiter.api.Test;

import java.time.Duration;
import java.util.List;
import java.util.Optional;

import static org.junit.jupiter.api.Assertions.*;

class ScimAgentLookupTest {

    @Test
    void unconfigured_returns_empty() {
        var lookup = ScimAgentLookup.unconfigured();
        assertFalse(lookup.isConfigured());
        assertTrue(lookup.get("claude:reviewer@v1").isEmpty());
    }

    @Test
    void isConfigured_true_when_endpoint_set() {
        var lookup = new ScimAgentLookup(
                "https://scim.example.com", "token", 5000, Duration.ofMinutes(5), true);
        assertTrue(lookup.isConfigured());
    }

    @Test
    void validate_throws_when_endpoint_blank() {
        var lookup = new ScimAgentLookup("", "token", 5000, Duration.ofMinutes(5), true);
        assertThrows(IllegalArgumentException.class, lookup::validate);
    }

    @Test
    void validate_throws_when_http_with_requireHttps() {
        var lookup = new ScimAgentLookup(
                "http://scim.example.com", "token", 5000, Duration.ofMinutes(5), true);
        var ex = assertThrows(IllegalArgumentException.class, lookup::validate);
        assertTrue(ex.getMessage().contains("HTTPS"));
    }

    @Test
    void validate_allows_http_when_requireHttps_false() {
        var lookup = new ScimAgentLookup(
                "http://localhost:8080", "token", 5000, Duration.ofMinutes(5), false);
        assertDoesNotThrow(lookup::validate);
    }

    @Test
    void validate_throws_when_authToken_blank() {
        var lookup = new ScimAgentLookup(
                "https://scim.example.com", "", 5000, Duration.ofMinutes(5), true);
        var ex = assertThrows(IllegalArgumentException.class, lookup::validate);
        assertTrue(ex.getMessage().contains("auth-token"));
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `mvn --batch-mode test -pl identity -Dtest=ScimAgentLookupTest`
Expected: FAIL — `ScimAgentLookup` class not found.

- [ ] **Step 4: Implement ScimAgentLookup**

Extract the SCIM HTTP client logic from `ScimActorDIDProvider` into `ScimAgentLookup`. The lookup caches `ScimAgentResource` (now with `derCertificates`) by actorId. Same SCIM query, same error handling, same caching — just in a dedicated bean.

```java
package io.casehub.platform.identity;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import io.casehub.platform.identity.config.IdentityConfig;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;
import org.jboss.logging.Logger;

import java.net.URI;
import java.net.URLEncoder;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.util.ArrayList;
import java.util.Base64;
import java.util.List;
import java.util.Optional;

@ApplicationScoped
public class ScimAgentLookup extends AbstractCachingIdentityProvider<ScimAgentResource> {

    private static final Logger LOG = Logger.getLogger(ScimAgentLookup.class);
    private static final ObjectMapper MAPPER = new ObjectMapper();
    private static final String EXTENSION_KEY =
            "urn:ietf:params:scim:schemas:extension:casehub:2.0:Agent";

    private final String scimEndpoint;
    private final String authToken;
    private final int timeoutMs;
    private final boolean requireHttps;
    private final HttpClient httpClient;

    @Inject
    public ScimAgentLookup(final IdentityConfig config) {
        this(config.scim().endpoint().orElse(""),
             config.scim().authToken().orElse(""),
             config.scim().timeoutMs(),
             Duration.ofMinutes(config.scim().cacheTtlMinutes()),
             config.scim().requireHttps());
    }

    public ScimAgentLookup(final String endpoint, final String authToken,
                            final int timeoutMs, final Duration cacheTtl,
                            final boolean requireHttps) {
        super(cacheTtl);
        this.scimEndpoint = endpoint;
        this.authToken = authToken;
        this.timeoutMs = timeoutMs;
        this.requireHttps = requireHttps;
        this.httpClient = HttpClient.newBuilder()
                .connectTimeout(Duration.ofMillis(timeoutMs)).build();
    }

    protected ScimAgentLookup() {
        super(Duration.ZERO);
        this.scimEndpoint = null;
        this.authToken = null;
        this.timeoutMs = 0;
        this.requireHttps = true;
        this.httpClient = null;
    }

    static ScimAgentLookup unconfigured() {
        return new ScimAgentLookup("", "", 5000, Duration.ofMinutes(5), true);
    }

    public boolean isConfigured() {
        return scimEndpoint != null && !scimEndpoint.isBlank();
    }

    public void validate() {
        if (!isConfigured()) {
            throw new IllegalArgumentException(
                    "casehub.identity.scim.endpoint must be configured");
        }
        if (requireHttps && !scimEndpoint.startsWith("https://")) {
            throw new IllegalArgumentException(
                    "casehub.identity.scim.endpoint must use HTTPS, got: " + scimEndpoint);
        }
        if (authToken == null || authToken.isBlank()) {
            throw new IllegalArgumentException(
                    "casehub.identity.scim.auth-token must not be blank when endpoint is configured");
        }
    }

    @Override
    protected Optional<ScimAgentResource> loadContext(final String actorId) {
        if (!isConfigured()) return Optional.empty();

        final String encodedActorId = URLEncoder.encode(actorId, StandardCharsets.UTF_8)
                .replace("+", "%20");
        final String url = scimEndpoint + "/scim/v2/Agents?filter=externalId%20eq%20%22"
                + encodedActorId + "%22";

        final HttpRequest request = HttpRequest.newBuilder()
                .uri(URI.create(url))
                .timeout(Duration.ofMillis(timeoutMs))
                .header("Authorization", "Bearer " + authToken)
                .header("Accept", "application/json")
                .GET().build();

        final HttpResponse<String> response;
        try {
            response = httpClient.send(request, HttpResponse.BodyHandlers.ofString());
        } catch (final Exception e) {
            LOG.warnf("SCIM request failed for actorId %s: %s", actorId, e.getMessage());
            throw new IllegalStateException("SCIM request failed for actorId: " + actorId, e);
        }

        return switch (response.statusCode()) {
            case 200 -> parseResponse(actorId, response.body());
            case 401 -> {
                LOG.warnf("SCIM authentication failed (HTTP 401) for actorId: %s", actorId);
                throw new IllegalStateException(
                        "SCIM authentication failed (HTTP 401) for actorId: " + actorId);
            }
            case 404 -> {
                LOG.warnf("SCIM endpoint returned 404 — possible misconfiguration: %s", scimEndpoint);
                throw new IllegalStateException(
                        "SCIM endpoint returned 404 — possible misconfiguration: " + scimEndpoint);
            }
            default -> {
                LOG.warnf("SCIM returned unexpected status %d for actorId %s",
                        response.statusCode(), actorId);
                throw new IllegalStateException(
                        "SCIM returned unexpected status " + response.statusCode()
                        + " for actorId: " + actorId);
            }
        };
    }

    private Optional<ScimAgentResource> parseResponse(final String actorId, final String body) {
        try {
            final JsonNode root = MAPPER.readTree(body);
            if (root.path("totalResults").asInt(0) == 0) return Optional.empty();
            if (root.path("totalResults").asInt(0) > 1) {
                LOG.warnf("SCIM returned %d results for externalId %s — using first",
                        root.path("totalResults").asInt(), actorId);
            }
            final JsonNode resource = root.path("Resources").get(0);
            final JsonNode extension = resource.path(EXTENSION_KEY);
            final String did = extension.path("did").asText(null);
            if (did == null || did.isBlank()) {
                throw new IllegalStateException(
                        "SCIM resource for actorId " + actorId + " is missing required 'did' field");
            }

            final List<byte[]> certs = new ArrayList<>();
            final JsonNode certArray = resource.path("x509Certificates");
            if (certArray.isArray()) {
                for (final JsonNode certNode : certArray) {
                    final String value = certNode.path("value").asText(null);
                    if (value != null && !value.isBlank()) {
                        certs.add(Base64.getDecoder().decode(value));
                    }
                }
            }

            return Optional.of(new ScimAgentResource(did, certs));
        } catch (final IllegalStateException e) {
            throw e;
        } catch (final Exception e) {
            LOG.warnf("Failed to parse SCIM response for actorId %s: %s", actorId, e.getMessage());
            throw new IllegalStateException("Failed to parse SCIM response for actorId: " + actorId, e);
        }
    }
}
```

- [ ] **Step 5: Run ScimAgentLookup tests**

Run: `mvn --batch-mode test -pl identity -Dtest=ScimAgentLookupTest`
Expected: All 6 tests PASS.

- [ ] **Step 6: Refactor ScimActorDIDProvider to delegate to ScimAgentLookup**

Replace the HTTP client, parsing, and caching logic with delegation. Keep `@Alternative` (ActorDIDProvider uses a different CDI pattern than DIDResolver — only one provider per deployment).

```java
package io.casehub.platform.identity;

import io.casehub.platform.api.identity.ActorDIDProvider;
import jakarta.annotation.PostConstruct;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.enterprise.inject.Alternative;
import jakarta.inject.Inject;

import java.util.Optional;

@ApplicationScoped
@Alternative
public class ScimActorDIDProvider implements ActorDIDProvider {

    private final ScimAgentLookup lookup;

    @Inject
    public ScimActorDIDProvider(final ScimAgentLookup lookup) {
        this.lookup = lookup;
    }

    protected ScimActorDIDProvider() {
        this.lookup = null;
    }

    @PostConstruct
    public void validateEndpoint() {
        lookup.validate();
    }

    @Override
    public Optional<String> didFor(final String actorId) {
        return lookup.get(actorId).map(ScimAgentResource::did);
    }

    public void invalidate(final String actorId) {
        lookup.invalidate(actorId);
    }
}
```

- [ ] **Step 7: Update ScimActorDIDProviderValidationTest**

The test constructors change — now takes `ScimAgentLookup` instead of raw parameters. Adapt the test to construct `ScimAgentLookup` first, then wrap with `ScimActorDIDProvider`.

- [ ] **Step 8: Build and run all identity tests**

Run: `mvn --batch-mode test -pl identity`
Expected: All tests pass — existing behavior preserved.

- [ ] **Step 9: Commit**

```
refactor(platform#85): ScimAgentLookup — shared SCIM client for DID provider and resolver
```

---

### Task 4: ScimDIDResolver

**Files:**
- Create: `identity/src/main/java/io/casehub/platform/identity/ScimDIDResolver.java`
- Create: `identity/src/test/java/io/casehub/platform/identity/ScimDIDResolverTest.java`

**Interfaces:**
- Consumes: `ScimAgentLookup.get(String actorId) → Optional<ScimAgentResource>` from Task 3
- Consumes: `ScimAgentLookup.isConfigured() → boolean` from Task 3
- Consumes: `ScimAgentResource(String did, List<byte[]> derCertificates)` from Task 3
- Produces: `ScimDIDResolver` — `@DIDMethod @Priority(1000)` DIDResolver bean

- [ ] **Step 1: Write failing tests**

```java
package io.casehub.platform.identity;

import io.casehub.platform.api.identity.DIDDocument;
import io.casehub.platform.api.identity.VerificationMethod;
import org.junit.jupiter.api.Test;

import java.security.KeyPairGenerator;
import java.security.cert.CertificateFactory;
import java.security.cert.X509Certificate;
import java.io.ByteArrayInputStream;
import java.time.Duration;
import java.util.Base64;
import java.util.List;

import static org.junit.jupiter.api.Assertions.*;

class ScimDIDResolverTest {

    private static final String ACTOR_ID = "claude:reviewer@v1";
    private static final String DID = "did:web:example.com:agents:reviewer";

    private ScimDIDResolver resolver(ScimAgentLookup lookup) {
        return new ScimDIDResolver(lookup);
    }

    @Test
    void returns_empty_when_actorId_is_null() {
        var r = resolver(ScimAgentLookup.unconfigured());
        assertTrue(r.resolve(null, DID).isEmpty());
    }

    @Test
    void returns_empty_when_scim_unconfigured() {
        var r = resolver(ScimAgentLookup.unconfigured());
        assertTrue(r.resolve(ACTOR_ID, DID).isEmpty());
    }

    @Test
    void returns_empty_when_actor_not_in_scim() {
        var lookup = lookupReturning(null);
        var r = resolver(lookup);
        assertTrue(r.resolve(ACTOR_ID, DID).isEmpty());
    }

    @Test
    void returns_empty_on_did_mismatch() {
        var lookup = lookupReturning(new ScimAgentResource("did:web:other.com", List.of()));
        var r = resolver(lookup);
        assertTrue(r.resolve(ACTOR_ID, DID).isEmpty());
    }

    @Test
    void constructs_document_with_alsoKnownAs_containing_actorId() {
        var lookup = lookupReturning(new ScimAgentResource(DID, List.of()));
        var r = resolver(lookup);
        var doc = r.resolve(ACTOR_ID, DID).orElseThrow();
        assertEquals(DID, doc.id());
        assertEquals(List.of(ACTOR_ID), doc.alsoKnownAs());
        assertTrue(doc.verificationMethods().isEmpty());
    }

    @Test
    void extracts_ed25519_raw_key_from_x509_certificate() throws Exception {
        var keyPair = KeyPairGenerator.getInstance("Ed25519").generateKeyPair();
        byte[] derCert = generateSelfSignedCert(keyPair, "Ed25519");

        var lookup = lookupReturning(new ScimAgentResource(DID, List.of(derCert)));
        var r = resolver(lookup);
        var doc = r.resolve(ACTOR_ID, DID).orElseThrow();

        assertEquals(1, doc.verificationMethods().size());
        var vm = doc.verificationMethods().get(0);
        assertEquals("Ed25519VerificationKey2020", vm.type());
        assertEquals(DID + "#scim-key-0", vm.id());
        assertEquals(32, vm.publicKeyBytes().length);

        // Verify raw bytes match — extract raw from SPKI
        byte[] spki = keyPair.getPublic().getEncoded();
        byte[] expectedRaw = new byte[32];
        System.arraycopy(spki, spki.length - 32, expectedRaw, 0, 32);
        assertArrayEquals(expectedRaw, vm.publicKeyBytes());
    }

    @Test
    void catches_exception_and_returns_empty() {
        var lookup = throwingLookup();
        var r = resolver(lookup);
        assertTrue(r.resolve(ACTOR_ID, DID).isEmpty());
    }

    // ── helpers ──

    private ScimAgentLookup lookupReturning(ScimAgentResource resource) {
        return new ScimAgentLookup("https://scim.example.com", "token",
                5000, Duration.ofMinutes(5), true) {
            @Override
            protected java.util.Optional<ScimAgentResource> loadContext(String key) {
                return java.util.Optional.ofNullable(resource);
            }
        };
    }

    private ScimAgentLookup throwingLookup() {
        return new ScimAgentLookup("https://scim.example.com", "token",
                5000, Duration.ofMinutes(5), true) {
            @Override
            protected java.util.Optional<ScimAgentResource> loadContext(String key) {
                throw new IllegalStateException("SCIM down");
            }
        };
    }

    /**
     * Generate a self-signed certificate for testing.
     * Uses sun.security.x509 for simplicity — test-only.
     */
    private byte[] generateSelfSignedCert(java.security.KeyPair keyPair, String algorithm)
            throws Exception {
        // Use keytool-like approach: create a minimal self-signed cert
        // For Ed25519, we need Bouncy Castle or JDK internal APIs
        // Simplest: use the JDK's CertificateBuilder via programmatic X.509
        var gen = new sun.security.x509.CertAndKeyGen(algorithm, algorithm);
        // Alternative: just encode the public key as if it were a DER cert for testing
        // Actually, let's use a simpler approach for unit tests:
        // Create a real X.509 cert using the JDK internal API
        var certGen = new sun.security.x509.X509CertImpl(
                sun.security.x509.X509CertInfo.newBuilder()
                        // This is getting complex — let's use a pre-built test cert instead
        );
        // For the actual implementation, use a test utility that generates certs
        throw new UnsupportedOperationException("Implement with test cert utility");
    }
}
```

Note: The self-signed certificate generation in tests requires a utility. The implementer should use `java.security.cert.CertificateFactory` with a programmatically-generated DER-encoded certificate, or create a test utility that builds self-signed X.509 certs using the JDK's `sun.security.x509` internal APIs or BouncyCastle (test-only dependency).

A simpler alternative for unit tests: skip X.509 certificate generation and test with pre-encoded DER bytes. The `extractRawKeyBytes()` method can be tested directly with known SPKI byte arrays.

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn --batch-mode test -pl identity -Dtest=ScimDIDResolverTest`
Expected: FAIL — `ScimDIDResolver` class not found.

- [ ] **Step 3: Implement ScimDIDResolver**

```java
package io.casehub.platform.identity;

import io.casehub.platform.api.identity.DIDDocument;
import io.casehub.platform.api.identity.DIDMethod;
import io.casehub.platform.api.identity.DIDResolver;
import io.casehub.platform.api.identity.VerificationMethod;
import jakarta.annotation.Priority;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;
import org.jboss.logging.Logger;

import java.io.ByteArrayInputStream;
import java.security.PublicKey;
import java.security.cert.CertificateFactory;
import java.security.cert.X509Certificate;
import java.security.interfaces.ECPublicKey;
import java.util.ArrayList;
import java.util.List;
import java.util.Optional;

@DIDMethod
@ApplicationScoped
@Priority(1000)
public class ScimDIDResolver implements DIDResolver {

    private static final Logger LOG = Logger.getLogger(ScimDIDResolver.class);

    private final ScimAgentLookup lookup;

    @Inject
    public ScimDIDResolver(final ScimAgentLookup lookup) {
        this.lookup = lookup;
    }

    protected ScimDIDResolver() {
        this.lookup = null;
    }

    @Override
    public Optional<DIDDocument> resolve(final String actorId, final String did) {
        if (actorId == null) return Optional.empty();
        if (lookup == null || !lookup.isConfigured()) return Optional.empty();
        try {
            final Optional<ScimAgentResource> agent = lookup.get(actorId);
            if (agent.isEmpty()) return Optional.empty();

            final ScimAgentResource resource = agent.get();
            if (!did.equals(resource.did())) {
                LOG.warnf("ScimDIDResolver: DID mismatch — SCIM has %s, "
                        + "request has %s for actorId %s", resource.did(), did, actorId);
                return Optional.empty();
            }

            final List<VerificationMethod> vms = extractVerificationMethods(resource);
            return Optional.of(new DIDDocument(resource.did(), vms, List.of(actorId)));
        } catch (final Exception e) {
            LOG.warnf("ScimDIDResolver: lookup failed for actorId %s: %s",
                    actorId, e.getMessage());
            return Optional.empty();
        }
    }

    private List<VerificationMethod> extractVerificationMethods(
            final ScimAgentResource resource) {
        final List<VerificationMethod> vms = new ArrayList<>();
        final List<byte[]> certs = resource.derCertificates();
        for (int i = 0; i < certs.size(); i++) {
            extractVerificationMethod(resource.did(), certs.get(i), i)
                    .ifPresent(vms::add);
        }
        return List.copyOf(vms);
    }

    private Optional<VerificationMethod> extractVerificationMethod(
            final String did, final byte[] derBytes, final int index) {
        try {
            final X509Certificate cert = (X509Certificate) CertificateFactory
                    .getInstance("X.509")
                    .generateCertificate(new ByteArrayInputStream(derBytes));

            final byte[] rawKeyBytes = extractRawKeyBytes(cert.getPublicKey());
            if (rawKeyBytes == null) return Optional.empty();

            final String vmType = switch (cert.getPublicKey().getAlgorithm()) {
                case "Ed25519", "EdDSA" -> "Ed25519VerificationKey2020";
                case "EC" -> "EcdsaSecp256r1VerificationKey2019";
                default -> null;
            };
            if (vmType == null) return Optional.empty();

            return Optional.of(new VerificationMethod(
                    did + "#scim-key-" + index, vmType, rawKeyBytes));
        } catch (final Exception e) {
            LOG.warnf("ScimDIDResolver: failed to extract key from certificate %d: %s",
                    index, e.getMessage());
            return Optional.empty();
        }
    }

    static byte[] extractRawKeyBytes(final PublicKey publicKey) {
        final byte[] spki = publicKey.getEncoded();
        return switch (publicKey.getAlgorithm()) {
            case "Ed25519", "EdDSA" -> {
                final byte[] raw = new byte[32];
                System.arraycopy(spki, spki.length - 32, raw, 0, 32);
                yield raw;
            }
            case "EC" -> {
                final ECPublicKey ecKey = (ECPublicKey) publicKey;
                yield buildUncompressedPoint(ecKey);
            }
            default -> {
                LOG.warnf("Unsupported key algorithm for raw extraction: %s",
                        publicKey.getAlgorithm());
                yield null;
            }
        };
    }

    private static byte[] buildUncompressedPoint(final ECPublicKey ecKey) {
        final byte[] x = ecKey.getW().getAffineX().toByteArray();
        final byte[] y = ecKey.getW().getAffineY().toByteArray();
        final int fieldLen = (ecKey.getParams().getCurve().getField().getFieldSize() + 7) / 8;
        final byte[] point = new byte[1 + 2 * fieldLen];
        point[0] = 0x04;
        System.arraycopy(x, Math.max(0, x.length - fieldLen), point, 1 + fieldLen - Math.min(x.length, fieldLen), Math.min(x.length, fieldLen));
        System.arraycopy(y, Math.max(0, y.length - fieldLen), point, 1 + 2 * fieldLen - Math.min(y.length, fieldLen), Math.min(y.length, fieldLen));
        return point;
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mvn --batch-mode test -pl identity -Dtest=ScimDIDResolverTest`
Expected: All tests PASS.

- [ ] **Step 5: Run full identity module tests**

Run: `mvn --batch-mode test -pl identity`
Expected: All tests PASS.

- [ ] **Step 6: Commit**

```
feat(platform#85): ScimDIDResolver — synthetic DIDDocument from SCIM x509Certificates
```

---

### Task 5: Integration verification + cross-repo issue

Full build, coherence check, file the ledger update issue.

**Files:**
- No new files — verification only

- [ ] **Step 1: Full build**

Run: `mvn --batch-mode install`
Expected: All modules compile. All tests pass.

- [ ] **Step 2: Coherence review**

Verify against spec and protocols:
- `DIDResolver.resolve(String actorId, String did)` — matches spec §1 ✓
- `@DIDMethod` qualifier in platform-api — matches spec §2 ✓
- `CompositeDIDResolver @ApplicationScoped` — matches spec §3 ✓
- `WebDIDResolver @DIDMethod @Priority(100)` — matches spec §4 ✓
- `KeyDIDResolver @DIDMethod @Priority(100)` — matches spec §4 ✓
- `ScimAgentLookup @ApplicationScoped` — matches spec §5 ✓
- `ScimDIDResolver @DIDMethod @Priority(1000)` — matches spec §6 ✓
- `NoOpDIDResolver @DefaultBean` in platform/ — matches spec §7 ✓
- JwtVCValidator passes null actorId — matches spec §8 ✓
- AgentIdentityVerificationService passes actorId — matches spec §8 ✓
- Raw key bytes (not SPKI) — matches spec §6 key extraction ✓
- Protocol: `spi-signature-change-all-impls-same-commit` — all in-repo impls updated ✓
- Protocol: `module-tier-structure` — SPI in platform-api (Tier 1), impls in identity (Tier 2) ✓
- Protocol: `persistence-backend-cdi-priority` — NoOp @DefaultBean in platform/ ✓

- [ ] **Step 3: File cross-repo issue for casehub-ledger**

```bash
gh issue create --repo casehubio/ledger \
  --title "chore: update DIDResolver callers for actorId parameter (platform#85)" \
  --body "$(cat <<'EOF'
## Context

casehubio/platform#85 changed `DIDResolver.resolve(String did)` to
`resolve(String actorId, String did)`.

## Changes needed

1. `ActorIdentityValidationEnricher` (line 109):
   `resolver.resolve(entry.actorDid)` → `resolver.resolve(entry.actorId, entry.actorDid)`

2. `IdentityCacheInvalidator`: add `Instance<ScimAgentLookup>` injection for
   shared SCIM cache invalidation on `AgentKeyRotatedEvent`.

3. Test resolvers (`TestDIDResolver`, `InjectableTestDIDResolver`): update
   method signature to include actorId parameter.

Blocks on platform SNAPSHOT publish.
EOF
)" --label "scale: S" --label "complexity: Low"
```

- [ ] **Step 4: Update CLAUDE.md if needed**

Check whether the `identity/` module description needs updating to mention CompositeDIDResolver and ScimDIDResolver. Update the package structure section if ScimAgentLookup or @DIDMethod are cross-cutting types.
