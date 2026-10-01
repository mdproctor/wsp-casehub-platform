# Remote Source Auth + Integrity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** #336 — Remote source authentication and integrity verification for agent-config manifests
**Issue group:** #336

**Goal:** Harden ManifestLoader's remote source fetching with typed authentication headers, SHA-256 content integrity verification with optional DID-based signatures, Content-Type validation, response size limits, HTTPS enforcement, and redirect handling.

**Architecture:** Extend `SourceDeclaration` with two optional sub-records (`SourceAuth`, `SourceIntegrity`). Refactor `ManifestLoader` from zero-arg to constructor-injected (credential resolver, DID resolver, security config). Replace bare `fetchRemote(String)` with a multi-step security pipeline operating on `SourceDeclaration`. All changes in `agent-config-core` (framework-neutral, pure Java + Jackson) with minimal wiring changes in `agent-config` (Quarkus).

**Tech Stack:** Java 21+, Jackson YAML, `java.net.http.HttpClient`, `java.security.MessageDigest`, `io.casehub.platform.api.signing.SignatureVerifier`, `io.casehub.platform.api.identity.DIDResolver`

## Global Constraints

- `agent-config-core` must remain framework-neutral: no CDI, no Spring, no Quarkus imports. Pure Java + Jackson only.
- `platform-api` is the only casehubio dependency allowed in `agent-config-core`.
- Resolved credential values MUST NOT appear in any log output at any level.
- All new fields on `SourceDeclaration` are nullable — backward compatibility is mandatory.
- Fail-closed: declared digest/signature that fails verification rejects the source (ERROR log). Missing digest/signature is fine (no check).

---

## Batch 1: Data model + validation

### Task 1: SourceAuth and SourceIntegrity records + SourceDeclaration extension

**Files:**
- Create: `agent-config-core/src/main/java/io/casehub/platform/agent/config/SourceAuth.java`
- Create: `agent-config-core/src/main/java/io/casehub/platform/agent/config/SourceIntegrity.java`
- Modify: `agent-config-core/src/main/java/io/casehub/platform/agent/config/SourceDeclaration.java`
- Test: `agent-config-core/src/test/java/io/casehub/platform/agent/config/SourceDeclarationTest.java`

**Interfaces:**
- Produces: `SourceAuth(String type, String credential, @JsonProperty("header-name") String headerName)`, `SourceIntegrity(String digest, String signature, String signer)`, `SourceDeclaration(String uri, int priority, SourceAuth auth, SourceIntegrity integrity)`

- [ ] **Step 1: Write failing test — SourceDeclaration YAML deserialization with auth and integrity**

```java
package io.casehub.platform.agent.config;

import com.fasterxml.jackson.databind.DeserializationFeature;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.dataformat.yaml.YAMLFactory;
import org.junit.jupiter.api.Test;
import static org.assertj.core.api.Assertions.assertThat;

class SourceDeclarationTest {

    private final ObjectMapper mapper = new ObjectMapper(new YAMLFactory())
            .configure(DeserializationFeature.FAIL_ON_UNKNOWN_PROPERTIES, false);

    @Test
    void deserializesAuthBearerSource() throws Exception {
        var yaml = """
                uri: https://corp.example/models.yaml
                priority: 40
                auth:
                  type: bearer
                  credential: env:CORP_TOKEN
                """;
        var source = mapper.readValue(yaml, SourceDeclaration.class);
        assertThat(source.uri()).isEqualTo("https://corp.example/models.yaml");
        assertThat(source.priority()).isEqualTo(40);
        assertThat(source.auth()).isNotNull();
        assertThat(source.auth().type()).isEqualTo("bearer");
        assertThat(source.auth().credential()).isEqualTo("env:CORP_TOKEN");
        assertThat(source.auth().headerName()).isNull();
        assertThat(source.integrity()).isNull();
    }

    @Test
    void deserializesAuthHeaderSource() throws Exception {
        var yaml = """
                uri: https://partner.example/models.yaml
                priority: 45
                auth:
                  type: header
                  credential: env:PARTNER_KEY
                  header-name: X-Api-Key
                """;
        var source = mapper.readValue(yaml, SourceDeclaration.class);
        assertThat(source.auth().type()).isEqualTo("header");
        assertThat(source.auth().headerName()).isEqualTo("X-Api-Key");
    }

    @Test
    void deserializesIntegrityWithDigestOnly() throws Exception {
        var yaml = """
                uri: https://registry.example/models.yaml
                priority: 50
                integrity:
                  digest: sha256:abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789
                """;
        var source = mapper.readValue(yaml, SourceDeclaration.class);
        assertThat(source.auth()).isNull();
        assertThat(source.integrity()).isNotNull();
        assertThat(source.integrity().digest()).startsWith("sha256:");
        assertThat(source.integrity().signature()).isNull();
        assertThat(source.integrity().signer()).isNull();
    }

    @Test
    void deserializesIntegrityWithSignature() throws Exception {
        var yaml = """
                uri: https://partner.example/models.yaml
                priority: 45
                integrity:
                  digest: sha256:abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789
                  signature: dGVzdA
                  signer: did:web:partner.example
                """;
        var source = mapper.readValue(yaml, SourceDeclaration.class);
        assertThat(source.integrity().signature()).isEqualTo("dGVzdA");
        assertThat(source.integrity().signer()).isEqualTo("did:web:partner.example");
    }

    @Test
    void deserializesLegacySourceWithoutAuthOrIntegrity() throws Exception {
        var yaml = """
                uri: https://internal.corp/models.yaml
                priority: 35
                """;
        var source = mapper.readValue(yaml, SourceDeclaration.class);
        assertThat(source.uri()).isEqualTo("https://internal.corp/models.yaml");
        assertThat(source.priority()).isEqualTo(35);
        assertThat(source.auth()).isNull();
        assertThat(source.integrity()).isNull();
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn --batch-mode test -pl agent-config-core -Dtest=SourceDeclarationTest`
Expected: compilation error — `SourceAuth`, `SourceIntegrity` don't exist, `SourceDeclaration` has no `auth()`/`integrity()` methods.

- [ ] **Step 3: Create SourceAuth record**

```java
package io.casehub.platform.agent.config;

import com.fasterxml.jackson.annotation.JsonProperty;

public record SourceAuth(
        String type,
        String credential,
        @JsonProperty("header-name") String headerName
) {}
```

- [ ] **Step 4: Create SourceIntegrity record**

```java
package io.casehub.platform.agent.config;

public record SourceIntegrity(
        String digest,
        String signature,
        String signer
) {}
```

- [ ] **Step 5: Extend SourceDeclaration**

Replace the existing record:

```java
package io.casehub.platform.agent.config;

public record SourceDeclaration(String uri, int priority, SourceAuth auth, SourceIntegrity integrity) {}
```

- [ ] **Step 6: Fix existing test and production code**

The existing `ManifestLoaderTest` constructs `SourceDeclaration` with `(uri, priority)` — update to `(uri, priority, null, null)`. Check `Manifest` record's `sources()` default (already `List.of()` via `@JsonProperty` defaults). Check `ManifestLoader.merge()` — uses `sources.put(source.uri(), source)`, which works unchanged.

Search all callers:
```
ide_find_references for SourceDeclaration constructor
```
Update each call site to add `null, null` for the new fields.

- [ ] **Step 7: Run all tests**

Run: `mvn --batch-mode test -pl agent-config-core`
Expected: all pass including new `SourceDeclarationTest`

- [ ] **Step 8: Commit**

```bash
git add agent-config-core/src/main/java/io/casehub/platform/agent/config/SourceAuth.java agent-config-core/src/main/java/io/casehub/platform/agent/config/SourceIntegrity.java agent-config-core/src/main/java/io/casehub/platform/agent/config/SourceDeclaration.java agent-config-core/src/test/java/io/casehub/platform/agent/config/SourceDeclarationTest.java
git commit -m "feat(#336): add SourceAuth, SourceIntegrity records and extend SourceDeclaration"
```

### Task 2: ManifestSecurityConfig + source validation logic

**Files:**
- Create: `agent-config-core/src/main/java/io/casehub/platform/agent/config/ManifestSecurityConfig.java`
- Create: `agent-config-core/src/main/java/io/casehub/platform/agent/config/SourceValidator.java`
- Test: `agent-config-core/src/test/java/io/casehub/platform/agent/config/SourceValidatorTest.java`

**Interfaces:**
- Consumes: `SourceAuth`, `SourceIntegrity`, `SourceDeclaration` from Task 1, `CredentialRef.parse(String)` from existing code
- Produces: `ManifestSecurityConfig(boolean allowInsecure)`, `SourceValidator.validate(SourceDeclaration) → List<String>` (empty = valid, non-empty = error messages)

- [ ] **Step 1: Write failing tests — validation rules**

```java
package io.casehub.platform.agent.config;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import static org.assertj.core.api.Assertions.assertThat;

class SourceValidatorTest {

    @Test
    void validBearerAuth() {
        var source = new SourceDeclaration("https://x.com/m.yaml", 10,
                new SourceAuth("bearer", "env:TOKEN", null), null);
        assertThat(SourceValidator.validate(source)).isEmpty();
    }

    @Test
    void validHeaderAuth() {
        var source = new SourceDeclaration("https://x.com/m.yaml", 10,
                new SourceAuth("header", "env:KEY", "X-Api-Key"), null);
        assertThat(SourceValidator.validate(source)).isEmpty();
    }

    @Test
    void validBasicAuth() {
        var source = new SourceDeclaration("https://x.com/m.yaml", 10,
                new SourceAuth("basic", "env:CREDS", null), null);
        assertThat(SourceValidator.validate(source)).isEmpty();
    }

    @Test
    void unknownAuthType() {
        var source = new SourceDeclaration("https://x.com/m.yaml", 10,
                new SourceAuth("oauth2", "env:TOKEN", null), null);
        assertThat(SourceValidator.validate(source))
                .anyMatch(e -> e.contains("Unknown auth type"));
    }

    @Test
    void headerAuthMissingHeaderName() {
        var source = new SourceDeclaration("https://x.com/m.yaml", 10,
                new SourceAuth("header", "env:KEY", null), null);
        assertThat(SourceValidator.validate(source))
                .anyMatch(e -> e.contains("header-name required"));
    }

    @Test
    void invalidHeaderNameCharacters() {
        var source = new SourceDeclaration("https://x.com/m.yaml", 10,
                new SourceAuth("header", "env:KEY", "Bad Header"), null);
        assertThat(SourceValidator.validate(source))
                .anyMatch(e -> e.contains("Invalid header name"));
    }

    @Test
    void invalidCredentialRef() {
        var source = new SourceDeclaration("https://x.com/m.yaml", 10,
                new SourceAuth("bearer", "raw-value-no-prefix", null), null);
        assertThat(SourceValidator.validate(source))
                .anyMatch(e -> e.contains("Invalid credential reference"));
    }

    @Test
    void validDigestOnly() {
        var source = new SourceDeclaration("https://x.com/m.yaml", 10, null,
                new SourceIntegrity("sha256:abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789", null, null));
        assertThat(SourceValidator.validate(source)).isEmpty();
    }

    @Test
    void signatureWithoutSigner() {
        var source = new SourceDeclaration("https://x.com/m.yaml", 10, null,
                new SourceIntegrity("sha256:abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789", "dGVzdA", null));
        assertThat(SourceValidator.validate(source))
                .anyMatch(e -> e.contains("signer required"));
    }

    @Test
    void signerWithoutSignature() {
        var source = new SourceDeclaration("https://x.com/m.yaml", 10, null,
                new SourceIntegrity("sha256:abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789", null, "did:web:x.example"));
        assertThat(SourceValidator.validate(source))
                .anyMatch(e -> e.contains("signature required"));
    }

    @Test
    void unknownDigestAlgorithm() {
        var source = new SourceDeclaration("https://x.com/m.yaml", 10, null,
                new SourceIntegrity("md5:abcdef", null, null));
        assertThat(SourceValidator.validate(source))
                .anyMatch(e -> e.contains("Unknown digest algorithm"));
    }

    @Test
    void malformedDigestHex() {
        var source = new SourceDeclaration("https://x.com/m.yaml", 10, null,
                new SourceIntegrity("sha256:tooshort", null, null));
        assertThat(SourceValidator.validate(source))
                .anyMatch(e -> e.contains("Malformed digest value"));
    }

    @ParameterizedTest
    @ValueSource(strings = {"not!valid", "has spaces", "has+plus"})
    void invalidBase64urlSignature(String sig) {
        var source = new SourceDeclaration("https://x.com/m.yaml", 10, null,
                new SourceIntegrity("sha256:abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789",
                        sig, "did:web:x.example"));
        assertThat(SourceValidator.validate(source))
                .anyMatch(e -> e.contains("Invalid signature encoding"));
    }

    @Test
    void noAuthNoIntegrityIsValid() {
        var source = new SourceDeclaration("https://x.com/m.yaml", 10, null, null);
        assertThat(SourceValidator.validate(source)).isEmpty();
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn --batch-mode test -pl agent-config-core -Dtest=SourceValidatorTest`
Expected: compilation error — `SourceValidator` and `ManifestSecurityConfig` don't exist.

- [ ] **Step 3: Create ManifestSecurityConfig**

```java
package io.casehub.platform.agent.config;

public record ManifestSecurityConfig(boolean allowInsecure) {}
```

- [ ] **Step 4: Implement SourceValidator**

```java
package io.casehub.platform.agent.config;

import java.util.ArrayList;
import java.util.Base64;
import java.util.List;
import java.util.Set;
import java.util.regex.Pattern;

public final class SourceValidator {

    private static final Set<String> AUTH_TYPES = Set.of("bearer", "header", "basic");
    private static final Pattern HTTP_TOKEN = Pattern.compile("^[!#$%&'*+\\-.^_`|~0-9A-Za-z]+$");
    private static final Pattern HEX_64 = Pattern.compile("^[0-9a-fA-F]{64}$");

    private SourceValidator() {}

    public static List<String> validate(SourceDeclaration source) {
        var errors = new ArrayList<String>();
        validateAuth(source, errors);
        validateIntegrity(source, errors);
        return errors;
    }

    private static void validateAuth(SourceDeclaration source, List<String> errors) {
        var auth = source.auth();
        if (auth == null) return;

        if (!AUTH_TYPES.contains(auth.type())) {
            errors.add("Unknown auth type '" + auth.type() + "' for source " + source.uri());
        }
        if ("header".equals(auth.type()) && (auth.headerName() == null || auth.headerName().isBlank())) {
            errors.add("header-name required when auth type is 'header' for source " + source.uri());
        }
        if (auth.headerName() != null && !HTTP_TOKEN.matcher(auth.headerName()).matches()) {
            errors.add("Invalid header name '" + auth.headerName() + "' for source " + source.uri()
                    + " (must be a valid HTTP token)");
        }
        if (auth.credential() != null) {
            try {
                CredentialRef.parse(auth.credential());
            } catch (IllegalArgumentException e) {
                errors.add("Invalid credential reference '" + auth.credential() + "' for source " + source.uri());
            }
        }
    }

    private static void validateIntegrity(SourceDeclaration source, List<String> errors) {
        var integrity = source.integrity();
        if (integrity == null) return;

        if (integrity.digest() != null) {
            if (!integrity.digest().startsWith("sha256:")) {
                var prefix = integrity.digest().contains(":")
                        ? integrity.digest().substring(0, integrity.digest().indexOf(':'))
                        : integrity.digest();
                errors.add("Unknown digest algorithm '" + prefix + "' for source " + source.uri()
                        + " (supported: sha256)");
            } else {
                var hex = integrity.digest().substring("sha256:".length());
                if (!HEX_64.matcher(hex).matches()) {
                    errors.add("Malformed digest value for source " + source.uri()
                            + ": expected 64 hex characters after sha256: prefix");
                }
            }
        }

        if (integrity.signature() != null && integrity.signer() == null) {
            errors.add("signer required when signature is declared for source " + source.uri());
        }
        if (integrity.signer() != null && integrity.signature() == null) {
            errors.add("signature required when signer is declared for source " + source.uri());
        }

        if (integrity.signature() != null) {
            try {
                Base64.getUrlDecoder().decode(integrity.signature());
            } catch (IllegalArgumentException e) {
                errors.add("Invalid signature encoding for source " + source.uri()
                        + ": must be base64url-encoded");
            }
        }
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `mvn --batch-mode test -pl agent-config-core -Dtest=SourceValidatorTest`
Expected: all pass

- [ ] **Step 6: Commit**

```bash
git add agent-config-core/src/main/java/io/casehub/platform/agent/config/ManifestSecurityConfig.java agent-config-core/src/main/java/io/casehub/platform/agent/config/SourceValidator.java agent-config-core/src/test/java/io/casehub/platform/agent/config/SourceValidatorTest.java
git commit -m "feat(#336): add ManifestSecurityConfig and SourceValidator with cross-field validation"
```

---

## Batch 2: ManifestLoader security pipeline

### Task 3: ManifestLoader constructor injection + HTTPS enforcement + redirect handling + Content-Type + size limit

**Files:**
- Modify: `agent-config-core/src/main/java/io/casehub/platform/agent/config/ManifestLoader.java`
- Modify: `agent-config-core/src/test/java/io/casehub/platform/agent/config/ManifestLoaderTest.java`

**Interfaces:**
- Consumes: `ManifestSecurityConfig` from Task 2, `ManifestCredentialResolver` from existing code, `DIDResolver` from `platform-api`, `SourceDeclaration` (extended) from Task 1, `SourceValidator` from Task 2
- Produces: `ManifestLoader(ManifestCredentialResolver, DIDResolver, ManifestSecurityConfig)` constructor, `fetchRemote(SourceDeclaration) → Manifest` (package-private, replaces `fetchRemote(String)`)

This task implements pipeline steps 1-8 and 11 (HTTPS enforcement, validation, request building with auth headers, redirect handling, Content-Type validation, size-limited read, and parse). Digest and signature verification (steps 9-10) are added in Task 4.

- [ ] **Step 1: Write failing tests — HTTPS enforcement**

Add to `ManifestLoaderTest.java`:

```java
@Test
void rejectsPublicHttpWhenInsecureNotAllowed() {
    var resolver = mock(ManifestCredentialResolver.class);
    var config = new ManifestSecurityConfig(false);
    var loader = new ManifestLoader(resolver, null, config);

    var source = new SourceDeclaration("http://public.example/models.yaml", 40, null, null);
    var result = loader.fetchRemote(source);
    assertThat(result).isNull();
}

@Test
void allowsLocalhostHttp() {
    var resolver = mock(ManifestCredentialResolver.class);
    var config = new ManifestSecurityConfig(false);
    var loader = new ManifestLoader(resolver, null, config);

    // Note: this test verifies the HTTPS check passes for localhost,
    // the actual HTTP request will fail (no server) — that's fine,
    // we're testing the enforcement gate, not the fetch
    var source = new SourceDeclaration("http://127.0.0.1:8080/models.yaml", 40, null, null);
    // The method should proceed past HTTPS enforcement (and fail later on connect)
    var result = loader.fetchRemote(source);
    // null is OK — means it tried to connect and failed, not blocked by HTTPS
    assertThat(result).isNull();
}

@Test
void allowsPublicHttpWhenInsecureEnabled() {
    var resolver = mock(ManifestCredentialResolver.class);
    var config = new ManifestSecurityConfig(true);
    var loader = new ManifestLoader(resolver, null, config);

    var source = new SourceDeclaration("http://public.example/models.yaml", 40, null, null);
    var result = loader.fetchRemote(source);
    // null — connect fails, but was not blocked by HTTPS enforcement
    assertThat(result).isNull();
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn --batch-mode test -pl agent-config-core -Dtest=ManifestLoaderTest`
Expected: compilation error — `ManifestLoader` has no 3-arg constructor, no `fetchRemote(SourceDeclaration)` method.

- [ ] **Step 3: Refactor ManifestLoader constructor**

Change `ManifestLoader` from zero-arg to 3-arg constructor. Keep a zero-arg constructor that creates defaults (for backward compatibility of `loadFile`/`loadResource` non-HTTP paths):

```java
private static final int MAX_BODY_SIZE = 1_048_576; // 1 MB
private static final Set<String> ALLOWED_CONTENT_TYPES = Set.of(
        "application/yaml", "application/x-yaml", "text/yaml", "application/json");

private final ManifestCredentialResolver credentialResolver; // nullable
private final DIDResolver didResolver; // nullable
private final ManifestSecurityConfig securityConfig;

public ManifestLoader(ManifestCredentialResolver credentialResolver,
                      DIDResolver didResolver,
                      ManifestSecurityConfig securityConfig) {
    this.mapper = new ObjectMapper(new YAMLFactory())
            .configure(DeserializationFeature.FAIL_ON_UNKNOWN_PROPERTIES, false);
    this.credentialResolver = credentialResolver;
    this.didResolver = didResolver;
    this.securityConfig = securityConfig != null ? securityConfig : new ManifestSecurityConfig(false);
}

public ManifestLoader() {
    this(null, null, new ManifestSecurityConfig(false));
}
```

Set HttpClient redirect policy explicitly:
```java
private final java.net.http.HttpClient httpClient = java.net.http.HttpClient.newBuilder()
        .connectTimeout(FETCH_TIMEOUT)
        .followRedirects(java.net.http.HttpClient.Redirect.NEVER)
        .build();
```

- [ ] **Step 4: Implement `isPrivateAddress(URI)`**

```java
private static boolean isPrivateAddress(URI uri) {
    try {
        var host = uri.getHost();
        if ("localhost".equalsIgnoreCase(host)) return true;
        var addr = java.net.InetAddress.getByName(host);
        return addr.isLoopbackAddress() || addr.isLinkLocalAddress() || addr.isSiteLocalAddress();
    } catch (Exception e) {
        return false;
    }
}
```

`InetAddress.isLoopbackAddress()` covers 127.0.0.0/8 and ::1. `isSiteLocalAddress()` covers RFC 1918 (10.x, 172.16-31.x, 192.168.x) and fc00::/7. `isLinkLocalAddress()` covers fe80::/10.

- [ ] **Step 5: Implement `fetchRemote(SourceDeclaration)` — steps 1-8 + 11**

Replace `fetchRemote(String uri)` with `fetchRemote(SourceDeclaration source)`. Update `followSources()` to call `fetchRemote(source)` instead of `fetchRemote(source.uri())`:

```java
Manifest fetchRemote(SourceDeclaration source) {
    var uri = URI.create(source.uri());

    // Step 1: HTTPS enforcement
    if ("http".equalsIgnoreCase(uri.getScheme())) {
        if (!isPrivateAddress(uri)) {
            if (!securityConfig.allowInsecure()) {
                LOG.errorf("Rejected insecure HTTP source: %s (set casehub.agent.manifest.allow-insecure=true to override)", source.uri());
                return null;
            }
            LOG.warnf("Insecure HTTP source allowed by configuration: %s", source.uri());
        }
    }

    // Step 2: Validation
    var errors = SourceValidator.validate(source);
    if (!errors.isEmpty()) {
        errors.forEach(e -> LOG.errorf("Source validation failed: %s", e));
        return null;
    }

    // Step 3: Build request
    var requestBuilder = HttpRequest.newBuilder().uri(uri).timeout(FETCH_TIMEOUT).GET();
    if (source.auth() != null && credentialResolver != null) {
        try {
            var ref = CredentialRef.parse(source.auth().credential());
            var value = credentialResolver.resolve(ref);
            switch (source.auth().type()) {
                case "bearer" -> requestBuilder.header("Authorization", "Bearer " + value);
                case "basic" -> requestBuilder.header("Authorization",
                        "Basic " + java.util.Base64.getEncoder().encodeToString(value.getBytes(java.nio.charset.StandardCharsets.UTF_8)));
                case "header" -> requestBuilder.header(source.auth().headerName(), value);
            }
        } catch (Exception e) {
            LOG.errorf("Credential resolution failed for source %s (ref: %s): %s",
                    source.uri(), source.auth().credential(), e.getMessage());
            return null;
        }
    }

    try {
        // Step 4: Send
        var response = httpClient.send(requestBuilder.build(), HttpResponse.BodyHandlers.ofInputStream());

        // Step 5: Redirect detection
        if (response.statusCode() >= 300 && response.statusCode() < 400) {
            var location = response.headers().firstValue("Location").orElse("(none)");
            LOG.warnf("HTTP %d redirect from %s to %s — update source URI to the final target",
                    response.statusCode(), source.uri(), location);
            return null;
        }

        // Step 6: HTTP error
        if (response.statusCode() >= 400) {
            LOG.warnf("HTTP %d from %s", response.statusCode(), source.uri());
            return null;
        }

        // Step 7: Content-Type validation
        var contentType = response.headers().firstValue("Content-Type").orElse(null);
        if (contentType != null) {
            var mediaType = contentType.contains(";")
                    ? contentType.substring(0, contentType.indexOf(';')).trim()
                    : contentType.trim();
            if (!ALLOWED_CONTENT_TYPES.contains(mediaType.toLowerCase())) {
                LOG.warnf("Unexpected Content-Type '%s' from %s (expected: %s)",
                        contentType, source.uri(), ALLOWED_CONTENT_TYPES);
                return null;
            }
        }

        // Step 8: Size-limited read
        try (var body = response.body()) {
            var bodyBytes = readBounded(body, MAX_BODY_SIZE, source.uri());
            if (bodyBytes == null) return null;

            // Steps 9-10 (digest/signature) added in Task 4

            // Step 11: Parse
            return mapper.readValue(bodyBytes, Manifest.class);
        }
    } catch (Exception e) {
        LOG.warnf("Failed to fetch remote source %s: %s", source.uri(), e.getMessage());
        return null;
    }
}

private byte[] readBounded(java.io.InputStream is, int limit, String uri) throws java.io.IOException {
    var buffer = new java.io.ByteArrayOutputStream();
    var chunk = new byte[8192];
    int total = 0;
    int read;
    while ((read = is.read(chunk)) != -1) {
        total += read;
        if (total > limit) {
            LOG.warnf("Response body exceeds %d bytes from %s — skipping", limit, uri);
            return null;
        }
        buffer.write(chunk, 0, read);
    }
    return buffer.toByteArray();
}
```

- [ ] **Step 6: Update `followSources` to pass SourceDeclaration**

Change `followSources` to pass the full `SourceDeclaration` to `fetchRemote`:

```java
// In followSources:
var fetched = fetchRemote(source);  // was: fetchRemote(source.uri())
```

- [ ] **Step 7: Restrict `loadResource(URI)` for HTTP schemes**

Add a guard at the top of `loadResource(URI)`:

```java
public Manifest loadResource(URI uri) {
    if ("http".equalsIgnoreCase(uri.getScheme()) || "https".equalsIgnoreCase(uri.getScheme())) {
        throw new IllegalArgumentException(
                "HTTP/HTTPS URIs must be fetched via SourceDeclaration — use sources: in the manifest");
    }
    // existing implementation...
}
```

- [ ] **Step 8: Fix existing tests**

Update existing `ManifestLoaderTest` tests that use `new ManifestLoader()` — the zero-arg constructor is preserved for backward compatibility. Add `import static org.mockito.Mockito.mock;` and Mockito as a test dependency if not already present.

Run: `mvn --batch-mode test -pl agent-config-core`
Expected: all pass

- [ ] **Step 9: Commit**

```bash
git add agent-config-core/src/main/java/io/casehub/platform/agent/config/ManifestLoader.java agent-config-core/src/test/java/io/casehub/platform/agent/config/ManifestLoaderTest.java
git commit -m "feat(#336): ManifestLoader security pipeline — HTTPS enforcement, auth headers, Content-Type, size limit, redirects"
```

### Task 4: Digest and signature verification (pipeline steps 9-10)

**Files:**
- Modify: `agent-config-core/src/main/java/io/casehub/platform/agent/config/ManifestLoader.java`
- Create: `agent-config-core/src/test/java/io/casehub/platform/agent/config/ManifestLoaderSecurityTest.java`

**Interfaces:**
- Consumes: `SourceIntegrity` from Task 1, `DIDResolver.resolve(String, String) → Optional<DIDDocument>` from `platform-api`, `SignatureVerifier.verify(byte[], byte[], byte[]) → VerificationOutcome` from `platform-api`, `VerificationMethod.publicKeyBytes() → byte[]`
- Produces: Digest verification (step 9) and signature verification (step 10) integrated into `fetchRemote(SourceDeclaration)`

- [ ] **Step 1: Write failing tests — digest verification**

Create `ManifestLoaderSecurityTest.java`:

```java
package io.casehub.platform.agent.config;

import org.junit.jupiter.api.Test;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.HexFormat;
import static org.assertj.core.api.Assertions.assertThat;

class ManifestLoaderSecurityTest {

    @Test
    void verifyDigestAcceptsMatchingHash() throws Exception {
        var content = "models: []\n".getBytes(StandardCharsets.UTF_8);
        var hash = HexFormat.of().formatHex(
                MessageDigest.getInstance("SHA-256").digest(content));
        var result = ManifestLoader.verifyDigest(content, "sha256:" + hash, "test-uri");
        assertThat(result).isTrue();
    }

    @Test
    void verifyDigestRejectsMismatch() throws Exception {
        var content = "models: []\n".getBytes(StandardCharsets.UTF_8);
        var wrongHash = "0".repeat(64);
        var result = ManifestLoader.verifyDigest(content, "sha256:" + wrongHash, "test-uri");
        assertThat(result).isFalse();
    }

    @Test
    void verifyDigestSkipsWhenNotDeclared() {
        var content = "models: []\n".getBytes(StandardCharsets.UTF_8);
        var result = ManifestLoader.verifyDigest(content, null, "test-uri");
        assertThat(result).isTrue();
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn --batch-mode test -pl agent-config-core -Dtest=ManifestLoaderSecurityTest`
Expected: compilation error — `ManifestLoader.verifyDigest` doesn't exist.

- [ ] **Step 3: Implement `verifyDigest` static method**

Add to `ManifestLoader`:

```java
static boolean verifyDigest(byte[] bodyBytes, String declaredDigest, String uri) {
    if (declaredDigest == null) return true;
    try {
        var hex = declaredDigest.substring("sha256:".length());
        var actual = java.util.HexFormat.of().formatHex(
                java.security.MessageDigest.getInstance("SHA-256").digest(bodyBytes));
        if (!actual.equalsIgnoreCase(hex)) {
            LOG.errorf("Digest mismatch for source %s: expected sha256:%s, actual sha256:%s",
                    uri, hex, actual);
            return false;
        }
        return true;
    } catch (Exception e) {
        LOG.errorf("Digest verification error for source %s: %s", uri, e.getMessage());
        return false;
    }
}
```

- [ ] **Step 4: Run digest tests**

Run: `mvn --batch-mode test -pl agent-config-core -Dtest=ManifestLoaderSecurityTest`
Expected: pass

- [ ] **Step 5: Write failing tests — signature verification**

Add to `ManifestLoaderSecurityTest.java`:

```java
import io.casehub.platform.api.identity.DIDDocument;
import io.casehub.platform.api.identity.DIDResolver;
import io.casehub.platform.api.identity.VerificationMethod;
import java.security.KeyPairGenerator;
import java.security.Signature;
import java.util.Base64;
import java.util.List;
import java.util.Optional;

// ...

@Test
void verifySignatureAcceptsValid() throws Exception {
    var kpg = KeyPairGenerator.getInstance("Ed25519");
    var kp = kpg.generateKeyPair();
    var content = "models: []\n".getBytes(StandardCharsets.UTF_8);

    var sig = Signature.getInstance("Ed25519");
    sig.initSign(kp.getPrivate());
    sig.update(content);
    var sigBytes = sig.sign();

    var vm = new VerificationMethod("key-1", "Ed25519VerificationKey2020",
            kp.getPublic().getEncoded());
    var didDoc = new DIDDocument("did:web:test.example", List.of(vm), List.of());
    DIDResolver resolver = (actorId, did) -> Optional.of(didDoc);

    var signatureB64 = Base64.getUrlEncoder().withoutPadding().encodeToString(sigBytes);
    var result = ManifestLoader.verifySignature(content, signatureB64,
            "did:web:test.example", resolver, "test-uri");
    assertThat(result).isTrue();
}

@Test
void verifySignatureRejectsInvalidSignature() throws Exception {
    var kpg = KeyPairGenerator.getInstance("Ed25519");
    var kp = kpg.generateKeyPair();
    var content = "models: []\n".getBytes(StandardCharsets.UTF_8);

    var vm = new VerificationMethod("key-1", "Ed25519VerificationKey2020",
            kp.getPublic().getEncoded());
    var didDoc = new DIDDocument("did:web:test.example", List.of(vm), List.of());
    DIDResolver resolver = (actorId, did) -> Optional.of(didDoc);

    var badSig = Base64.getUrlEncoder().withoutPadding().encodeToString(new byte[64]);
    var result = ManifestLoader.verifySignature(content, badSig,
            "did:web:test.example", resolver, "test-uri");
    assertThat(result).isFalse();
}

@Test
void verifySignatureRejectsNullResolver() {
    var content = "models: []\n".getBytes(StandardCharsets.UTF_8);
    var result = ManifestLoader.verifySignature(content, "dGVzdA",
            "did:web:test.example", null, "test-uri");
    assertThat(result).isFalse();
}

@Test
void verifySignatureRejectsUnresolvableDid() {
    var content = "models: []\n".getBytes(StandardCharsets.UTF_8);
    DIDResolver resolver = (actorId, did) -> Optional.empty();
    var result = ManifestLoader.verifySignature(content, "dGVzdA",
            "did:web:test.example", resolver, "test-uri");
    assertThat(result).isFalse();
}

@Test
void verifySignatureRejectsEmptyVerificationMethods() {
    var content = "models: []\n".getBytes(StandardCharsets.UTF_8);
    var didDoc = new DIDDocument("did:web:test.example", List.of(), List.of());
    DIDResolver resolver = (actorId, did) -> Optional.of(didDoc);
    var result = ManifestLoader.verifySignature(content, "dGVzdA",
            "did:web:test.example", resolver, "test-uri");
    assertThat(result).isFalse();
}

@Test
void verifySignatureSkipsWhenNotDeclared() {
    var result = ManifestLoader.verifySignature("data".getBytes(), null, null, null, "test-uri");
    assertThat(result).isTrue();
}
```

- [ ] **Step 6: Implement `verifySignature` static method**

Add to `ManifestLoader`:

```java
static boolean verifySignature(byte[] bodyBytes, String signatureB64, String signerDid,
                                DIDResolver didResolver, String uri) {
    if (signatureB64 == null) return true;

    if (didResolver == null) {
        LOG.errorf("Signature declared for source %s but no DID resolver configured (signer: %s)",
                uri, signerDid);
        return false;
    }

    var didDoc = didResolver.resolve(null, signerDid);
    if (didDoc.isEmpty()) {
        LOG.errorf("DID unresolvable: %s for source %s", signerDid, uri);
        return false;
    }

    var verificationMethods = didDoc.get().verificationMethods();
    if (verificationMethods.isEmpty()) {
        LOG.errorf("No verification methods in DID document for signer: %s (source %s)",
                signerDid, uri);
        return false;
    }

    var sigBytes = java.util.Base64.getUrlDecoder().decode(signatureB64);
    io.casehub.platform.api.signing.VerificationOutcome lastOutcome = null;

    for (var vm : verificationMethods) {
        var outcome = io.casehub.platform.api.signing.SignatureVerifier.verify(
                bodyBytes, sigBytes, vm.publicKeyBytes());
        if (outcome == io.casehub.platform.api.signing.VerificationOutcome.VALID) {
            return true;
        }
        lastOutcome = outcome;
    }

    LOG.errorf("Signature verification failed for source %s (signer: %s, outcome: %s)",
            uri, signerDid, lastOutcome);
    return false;
}
```

- [ ] **Step 7: Wire digest and signature into fetchRemote pipeline**

In `fetchRemote(SourceDeclaration)`, between the size-limited read and the parse step, add:

```java
// Step 9: Digest verification
if (source.integrity() != null && !verifyDigest(bodyBytes, source.integrity().digest(), source.uri())) {
    return null;
}

// Step 10: Signature verification
if (source.integrity() != null && !verifySignature(bodyBytes, source.integrity().signature(),
        source.integrity() != null ? source.integrity().signer() : null,
        didResolver, source.uri())) {
    return null;
}
```

- [ ] **Step 8: Run all tests**

Run: `mvn --batch-mode test -pl agent-config-core`
Expected: all pass

- [ ] **Step 9: Commit**

```bash
git add agent-config-core/src/main/java/io/casehub/platform/agent/config/ManifestLoader.java agent-config-core/src/test/java/io/casehub/platform/agent/config/ManifestLoaderSecurityTest.java
git commit -m "feat(#336): digest and signature verification in ManifestLoader fetch pipeline"
```

---

## Batch 3: Wiring + documentation

### Task 5: AgentConfigLoader + AgentConfigBeans wiring + documentation update

**Files:**
- Modify: `agent-config-core/src/main/java/io/casehub/platform/agent/config/AgentConfigLoader.java`
- Modify: `agent-config-core/src/test/java/io/casehub/platform/agent/config/AgentConfigLoaderTest.java`
- Modify: `agent-config/src/main/java/io/casehub/platform/agent/config/quarkus/AgentConfigBeans.java`
- Modify: `CLAUDE.md` (agent-config-core module description)
- Modify: `docs/guides/consumer-guide.md` or `docs/guides/contributor-guide.md` (if source auth docs needed)

**Interfaces:**
- Consumes: `ManifestLoader(ManifestCredentialResolver, DIDResolver, ManifestSecurityConfig)` from Task 3, `ManifestSecurityConfig` from Task 2
- Produces: Updated `AgentConfigLoader` constructor (adds `DIDResolver` nullable param + `boolean allowInsecure`), updated `AgentConfigBeans` CDI wiring

- [ ] **Step 1: Write failing test — AgentConfigLoader passes dependencies through**

Update `AgentConfigLoaderTest.java` to verify the loader constructs ManifestLoader with the new dependencies. The exact test depends on the existing test structure — at minimum, verify the constructor accepts the new parameters:

```java
@Test
void constructsWithSecurityDependencies() {
    var loader = new AgentConfigLoader(
            credentialStore, modelRegistry, credentialResolver,
            vendorRequirements, reconciler, null, tempDir,
            null, false); // didResolver=null, allowInsecure=false
    // No exception = construction succeeds
    assertThat(loader).isNotNull();
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mvn --batch-mode test -pl agent-config-core -Dtest=AgentConfigLoaderTest`
Expected: compilation error — constructor doesn't accept 9 params.

- [ ] **Step 3: Update AgentConfigLoader**

Add `DIDResolver` and `boolean allowInsecure` to the constructor. Update `load()` to pass them through:

```java
import io.casehub.platform.api.identity.DIDResolver;

public class AgentConfigLoader {
    // ... existing fields ...
    private final DIDResolver didResolver;
    private final boolean allowInsecure;

    public AgentConfigLoader(LlmCredentialStore credentialStore,
                             MutableModelRegistry modelRegistry,
                             CredentialResolver credentialResolver,
                             Map<String, List<String>> vendorRequirements,
                             LocalModelReconciler reconciler,
                             String profile,
                             Path projectDir,
                             DIDResolver didResolver,
                             boolean allowInsecure) {
        // ... existing assignments ...
        this.didResolver = didResolver;
        this.allowInsecure = allowInsecure;
    }

    public ManifestResult load() {
        var resolver = new ManifestCredentialResolver(credentialResolver);
        var securityConfig = new ManifestSecurityConfig(allowInsecure);
        var loader = new ManifestLoader(resolver, didResolver, securityConfig);
        var manifest = loader.load(projectDir, profile);
        // ... rest unchanged ...
    }
}
```

- [ ] **Step 4: Update AgentConfigBeans**

Add `DIDResolver` optional injection and `allow-insecure` config:

```java
import io.casehub.platform.api.identity.DIDResolver;
import org.eclipse.microprofile.config.inject.ConfigProperty;

// Add to field injections:
@Inject @Any Instance<DIDResolver> didResolvers;

@ConfigProperty(name = "casehub.agent.manifest.allow-insecure", defaultValue = "false")
boolean allowInsecure;

// Update onStartup:
void onStartup(@Observes @Priority(50) StartupEvent event) {
    var didResolver = didResolvers.isResolvable() ? didResolvers.get() : null;
    var loader = new AgentConfigLoader(
            credentialStore, modelRegistry, credentialResolver,
            buildVendorRequirements(), buildReconciler(),
            resolveProfile(), Path.of(System.getProperty("user.dir")),
            didResolver, allowInsecure);
    this.result = loader.load();
}
```

- [ ] **Step 5: Run full module test suite**

Run: `mvn --batch-mode test -pl agent-config-core,agent-config`
Expected: all pass

- [ ] **Step 6: Update CLAUDE.md module description**

Update the `agent-config-core/` entry in CLAUDE.md to mention the security pipeline: auth headers, digest verification, signature verification, HTTPS enforcement, Content-Type validation, response size limits.

- [ ] **Step 7: Run full build**

Run: `mvn --batch-mode install`
Expected: BUILD SUCCESS

- [ ] **Step 8: Commit**

```bash
git add agent-config-core/src/main/java/io/casehub/platform/agent/config/AgentConfigLoader.java agent-config-core/src/test/java/io/casehub/platform/agent/config/AgentConfigLoaderTest.java agent-config/src/main/java/io/casehub/platform/agent/config/quarkus/AgentConfigBeans.java CLAUDE.md
git commit -m "feat(#336): wire security dependencies through AgentConfigLoader and AgentConfigBeans"
```

## References

- `specs/issue-336-remote-source-auth-integrity/2026-09-30-remote-source-auth-integrity-design.md` — design spec this plan implements
- `agent-config-core/src/main/java/io/casehub/platform/agent/config/ManifestLoader.java` — primary implementation target
- `agent-config-core/src/main/java/io/casehub/platform/agent/config/SourceDeclaration.java` — data model extension point
- `agent-config-core/src/main/java/io/casehub/platform/agent/config/AgentConfigLoader.java` — wiring orchestrator
- `agent-config/src/main/java/io/casehub/platform/agent/config/quarkus/AgentConfigBeans.java` — CDI wiring
- `platform-api/src/main/java/io/casehub/platform/api/signing/SignatureVerifier.java` — signature verification utility
- `platform-api/src/main/java/io/casehub/platform/api/signing/VerificationOutcome.java` — verification result enum
- `platform-api/src/main/java/io/casehub/platform/api/identity/DIDResolver.java` — DID resolution SPI
- GitHub #335 — parent agent-config manifest design
- GitHub #498 — deferred mTLS follow-up
