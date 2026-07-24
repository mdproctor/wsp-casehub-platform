# Tier 2 Credential Resolution Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement `CredentialResolver` SPI in `platform-api` and `DefaultCredentialResolver` @DefaultBean in `platform/` to resolve `EndpointDescriptor.credentialRef` to actual secrets via MicroProfile Config.

**Architecture:** Zero-dep SPI interface + keys class in `platform-api` (`io.casehub.platform.api.credentials`). MicroProfile Config-backed `@DefaultBean` in `platform/` (`io.casehub.platform.credentials`). Pull model — consumers inject the resolver and call it explicitly, no coupling to `EndpointRegistry`.

**Tech Stack:** Java 21, Quarkus 3.32.x, MicroProfile Config, SmallRye Config

**Spec:** `specs/issue-103-credential-resolution/2026-06-25-credential-resolution-design.md`

## Global Constraints

- `platform-api` must remain zero-dependency — no Quarkus, no JPA, no casehubio imports. Pure Java only.
- `platform/` contains `@DefaultBean` implementations only — no domain logic.
- Follow established patterns: `EndpointPropertyKeys` for keys class structure, `MockCurrentPrincipal` for @DefaultBean config pattern.
- All constants use kebab-case string values.
- Issue: casehubio/platform#103

---

### Task 1: CredentialPropertyKeys + CredentialResolver SPI in platform-api

**Files:**
- Create: `platform-api/src/main/java/io/casehub/platform/api/credentials/CredentialPropertyKeys.java`
- Create: `platform-api/src/main/java/io/casehub/platform/api/credentials/CredentialResolver.java`
- Test: `platform-api/src/test/java/io/casehub/platform/api/credentials/CredentialPropertyKeysTest.java`

**Interfaces:**
- Consumes: nothing — this is the foundation
- Produces: `CredentialResolver.resolve(String credentialRef) → Map<String, String>`, `CredentialPropertyKeys.USER`, `.PASSWORD`, `.BEARER_TOKEN`, `.API_KEY`, `.EXPIRES_AT`

- [ ] **Step 1: Write the test for CredentialPropertyKeys constants**

```java
package io.casehub.platform.api.credentials;

import org.junit.jupiter.api.Test;

import static org.assertj.core.api.Assertions.assertThat;

class CredentialPropertyKeysTest {

    @Test
    void constants_use_kebab_case() {
        assertThat(CredentialPropertyKeys.USER).isEqualTo("user");
        assertThat(CredentialPropertyKeys.PASSWORD).isEqualTo("password");
        assertThat(CredentialPropertyKeys.BEARER_TOKEN).isEqualTo("bearer-token");
        assertThat(CredentialPropertyKeys.API_KEY).isEqualTo("api-key");
        assertThat(CredentialPropertyKeys.EXPIRES_AT).isEqualTo("expires-at");
    }

    @Test
    void constants_are_distinct() {
        assertThat(java.util.Set.of(
                CredentialPropertyKeys.USER,
                CredentialPropertyKeys.PASSWORD,
                CredentialPropertyKeys.BEARER_TOKEN,
                CredentialPropertyKeys.API_KEY,
                CredentialPropertyKeys.EXPIRES_AT
        )).hasSize(5);
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mvn --batch-mode test -pl platform-api -Dtest=CredentialPropertyKeysTest`
Expected: COMPILATION FAILURE — `CredentialPropertyKeys` does not exist.

- [ ] **Step 3: Create CredentialPropertyKeys**

Create `platform-api/src/main/java/io/casehub/platform/api/credentials/CredentialPropertyKeys.java`:

```java
package io.casehub.platform.api.credentials;

/**
 * Reserved property keys for credential maps returned by {@link CredentialResolver#resolve}.
 *
 * <p>Standard keys use <b>kebab-case</b>. Values mirror Quarkus
 * {@code io.quarkus.credentials.CredentialsProvider} naming for bridge compatibility.
 *
 * <p>These keys are conventions, not enforced constraints. Implementations may
 * return additional custom keys. Consumers should use the constants for standard
 * credential extraction.
 */
public final class CredentialPropertyKeys {

    /** Username for basic auth, SASL, or compound credentials. */
    public static final String USER = "user";

    /** Password for basic auth, SASL, or compound credentials. */
    public static final String PASSWORD = "password";

    /** OAuth/JWT bearer token — the most common HTTP endpoint credential type. */
    public static final String BEARER_TOKEN = "bearer-token";

    /** API key for header-based authentication (e.g. X-Api-Key). */
    public static final String API_KEY = "api-key";

    /** ISO-8601 expiration timestamp for time-limited credentials. */
    public static final String EXPIRES_AT = "expires-at";

    private CredentialPropertyKeys() {}
}
```

- [ ] **Step 4: Create CredentialResolver SPI**

Create `platform-api/src/main/java/io/casehub/platform/api/credentials/CredentialResolver.java`:

```java
package io.casehub.platform.api.credentials;

import java.util.Map;

/**
 * Resolves outbound endpoint credentials by logical reference name.
 *
 * <p>This is for outbound credential resolution (endpoint secrets, API tokens,
 * service passwords) — not to be confused with inbound Verifiable Credential
 * validation in {@code io.casehub.platform.api.identity}.
 *
 * <p>Implementations must be thread-safe — {@code @ApplicationScoped} beans
 * are shared across request threads.
 *
 * @see CredentialPropertyKeys
 */
public interface CredentialResolver {

    /**
     * Resolve the credential properties for the given logical reference.
     *
     * <p>Returns an empty map for null, blank, or unresolvable refs.
     * Never returns null. Never throws for missing credentials — consumers
     * decide whether absence is an error.
     *
     * @param credentialRef the logical credential name
     *        (from {@link io.casehub.platform.api.endpoints.EndpointDescriptor#credentialRef()})
     * @return credential properties keyed by {@link CredentialPropertyKeys} constants,
     *         or empty map if unresolvable
     */
    Map<String, String> resolve(String credentialRef);
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `mvn --batch-mode test -pl platform-api -Dtest=CredentialPropertyKeysTest`
Expected: 2 tests PASS.

- [ ] **Step 6: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add platform-api/src/main/java/io/casehub/platform/api/credentials/CredentialPropertyKeys.java platform-api/src/main/java/io/casehub/platform/api/credentials/CredentialResolver.java platform-api/src/test/java/io/casehub/platform/api/credentials/CredentialPropertyKeysTest.java
git -C /Users/mdproctor/claude/casehub/platform commit -m "feat(platform#103): CredentialResolver SPI + CredentialPropertyKeys in platform-api"
```

---

### Task 2: DefaultCredentialResolver @DefaultBean in platform/

**Files:**
- Create: `platform/src/main/java/io/casehub/platform/credentials/DefaultCredentialResolver.java`
- Test: `platform/src/test/java/io/casehub/platform/credentials/DefaultCredentialResolverTest.java`
- Modify: `platform/src/test/resources/application.properties` — add test credential config

**Interfaces:**
- Consumes: `CredentialResolver` (from Task 1), `CredentialPropertyKeys` (from Task 1), `org.eclipse.microprofile.config.Config`
- Produces: `DefaultCredentialResolver` — `@DefaultBean @ApplicationScoped`, constructor-injected `Config`

- [ ] **Step 1: Write the failing tests**

Create `platform/src/test/java/io/casehub/platform/credentials/DefaultCredentialResolverTest.java`:

```java
package io.casehub.platform.credentials;

import io.casehub.platform.api.credentials.CredentialPropertyKeys;
import io.casehub.platform.api.credentials.CredentialResolver;
import io.quarkus.test.junit.QuarkusTest;
import io.quarkus.test.junit.QuarkusTestProfile;
import io.quarkus.test.junit.TestProfile;
import jakarta.inject.Inject;
import org.junit.jupiter.api.Nested;
import org.junit.jupiter.api.Test;

import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;

class DefaultCredentialResolverTest {

    /**
     * Tests with default config — no credential properties set.
     */
    @QuarkusTest
    @Nested
    class EmptyConfig {

        @Inject CredentialResolver resolver;

        @Test
        void null_ref_returns_empty_map() {
            assertThat(resolver.resolve(null)).isEmpty();
        }

        @Test
        void blank_ref_returns_empty_map() {
            assertThat(resolver.resolve("   ")).isEmpty();
        }

        @Test
        void missing_ref_returns_empty_map() {
            assertThat(resolver.resolve("nonexistent-cred")).isEmpty();
        }
    }

    /**
     * Tests with credential config — simple and compound.
     */
    @QuarkusTest
    @TestProfile(WithCredentials.CredentialsProfile.class)
    @Nested
    class WithCredentials {

        public static class CredentialsProfile implements QuarkusTestProfile {
            @Override
            public Map<String, String> getConfigOverrides() {
                return Map.of(
                    "casehub.credentials.simple-token", "my-secret-token",
                    "casehub.credentials.db-primary.user", "admin",
                    "casehub.credentials.db-primary.password", "s3cret",
                    "casehub.credentials.db-with-expiry.user", "svc",
                    "casehub.credentials.db-with-expiry.password", "pw",
                    "casehub.credentials.db-with-expiry.expires-at", "2026-07-01T00:00:00Z",
                    "casehub.credentials.partial-compound.api-key", "key-only",
                    "casehub.credentials.both-modes", "bare-value",
                    "casehub.credentials.both-modes.user", "compound-user"
                );
            }
        }

        @Inject CredentialResolver resolver;

        @Test
        void simple_ref_returns_bearer_token() {
            Map<String, String> result = resolver.resolve("simple-token");
            assertThat(result).containsExactly(
                    Map.entry(CredentialPropertyKeys.BEARER_TOKEN, "my-secret-token"));
        }

        @Test
        void compound_user_password_returns_both() {
            Map<String, String> result = resolver.resolve("db-primary");
            assertThat(result)
                    .containsEntry(CredentialPropertyKeys.USER, "admin")
                    .containsEntry(CredentialPropertyKeys.PASSWORD, "s3cret")
                    .hasSize(2);
        }

        @Test
        void compound_with_expiry_returns_all_sub_keys() {
            Map<String, String> result = resolver.resolve("db-with-expiry");
            assertThat(result)
                    .containsEntry(CredentialPropertyKeys.USER, "svc")
                    .containsEntry(CredentialPropertyKeys.PASSWORD, "pw")
                    .containsEntry(CredentialPropertyKeys.EXPIRES_AT, "2026-07-01T00:00:00Z")
                    .hasSize(3);
        }

        @Test
        void partial_compound_returns_only_present_sub_keys() {
            Map<String, String> result = resolver.resolve("partial-compound");
            assertThat(result).containsExactly(
                    Map.entry(CredentialPropertyKeys.API_KEY, "key-only"));
        }

        @Test
        void compound_takes_precedence_over_bare_key() {
            Map<String, String> result = resolver.resolve("both-modes");
            assertThat(result)
                    .containsEntry(CredentialPropertyKeys.USER, "compound-user")
                    .doesNotContainKey(CredentialPropertyKeys.BEARER_TOKEN)
                    .hasSize(1);
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn --batch-mode test -pl platform -Dtest=DefaultCredentialResolverTest`
Expected: COMPILATION FAILURE — `DefaultCredentialResolver` does not exist.

- [ ] **Step 3: Create DefaultCredentialResolver**

Create `platform/src/main/java/io/casehub/platform/credentials/DefaultCredentialResolver.java`:

```java
package io.casehub.platform.credentials;

import io.casehub.platform.api.credentials.CredentialPropertyKeys;
import io.casehub.platform.api.credentials.CredentialResolver;
import io.quarkus.arc.DefaultBean;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;
import org.eclipse.microprofile.config.Config;

import java.util.LinkedHashMap;
import java.util.Map;

/**
 * MicroProfile Config-backed credential resolver.
 *
 * <p>Resolves credentials from the {@code casehub.credentials.<ref>} config namespace.
 * Supports two modes:
 * <ul>
 *   <li><b>Compound</b> — sub-keys checked first ({@code casehub.credentials.<ref>.user},
 *       {@code .password}, {@code .bearer-token}, {@code .api-key}, {@code .expires-at}).
 *       If any sub-key is found, returns the compound map.</li>
 *   <li><b>Simple</b> — bare key ({@code casehub.credentials.<ref>}) returned under
 *       {@link CredentialPropertyKeys#BEARER_TOKEN}. Used only when no sub-keys match.</li>
 * </ul>
 *
 * <p>Compound or simple, never both — if sub-keys exist, the bare key is not consulted.
 */
@DefaultBean
@ApplicationScoped
public class DefaultCredentialResolver implements CredentialResolver {

    private final Config config;

    @Inject
    DefaultCredentialResolver(final Config config) {
        this.config = config;
    }

    @Override
    public Map<String, String> resolve(final String credentialRef) {
        if (credentialRef == null || credentialRef.isBlank()) return Map.of();

        final String prefix = "casehub.credentials." + credentialRef;

        final Map<String, String> compound = new LinkedHashMap<>();
        checkSubKey(prefix, CredentialPropertyKeys.USER, compound);
        checkSubKey(prefix, CredentialPropertyKeys.PASSWORD, compound);
        checkSubKey(prefix, CredentialPropertyKeys.BEARER_TOKEN, compound);
        checkSubKey(prefix, CredentialPropertyKeys.API_KEY, compound);
        checkSubKey(prefix, CredentialPropertyKeys.EXPIRES_AT, compound);
        if (!compound.isEmpty()) return Map.copyOf(compound);

        return config.getOptionalValue(prefix, String.class)
                .map(v -> Map.of(CredentialPropertyKeys.BEARER_TOKEN, v))
                .orElse(Map.of());
    }

    private void checkSubKey(final String prefix, final String key, final Map<String, String> target) {
        config.getOptionalValue(prefix + "." + key, String.class)
                .ifPresent(v -> target.put(key, v));
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mvn --batch-mode test -pl platform -Dtest=DefaultCredentialResolverTest`
Expected: 8 tests PASS (3 empty-config + 5 with-credentials).

- [ ] **Step 5: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add platform/src/main/java/io/casehub/platform/credentials/DefaultCredentialResolver.java platform/src/test/java/io/casehub/platform/credentials/DefaultCredentialResolverTest.java
git -C /Users/mdproctor/claude/casehub/platform commit -m "feat(platform#103): DefaultCredentialResolver @DefaultBean — MicroProfile Config with compound sub-key support"
```

---

### Task 3: CDI integration test + MockBeansTest update + CLAUDE.md

**Files:**
- Modify: `platform/src/test/java/io/casehub/platform/mock/MockBeansTest.java` — add resolver injection + default-returns-empty assertion
- Modify: `CLAUDE.md` — update package structure documentation

**Interfaces:**
- Consumes: `CredentialResolver` (from Task 1), `DefaultCredentialResolver` (from Task 2)
- Produces: verified CDI wiring; updated CLAUDE.md

- [ ] **Step 1: Write the CDI wiring test in MockBeansTest**

Add to `platform/src/test/java/io/casehub/platform/mock/MockBeansTest.java`:

Add import:
```java
import io.casehub.platform.api.credentials.CredentialResolver;
```

Add field:
```java
@Inject CredentialResolver credentialResolver;
```

Add test:
```java
@Test
void credentialResolver_defaultBean_returns_empty_for_unconfigured_ref() {
    assertTrue(credentialResolver.resolve("unconfigured-ref").isEmpty());
}
```

- [ ] **Step 2: Run the test**

Run: `mvn --batch-mode test -pl platform -Dtest=MockBeansTest#credentialResolver_defaultBean_returns_empty_for_unconfigured_ref`
Expected: PASS.

- [ ] **Step 3: Update CLAUDE.md package structure**

In the `## Package Structure (platform-api)` section of `CLAUDE.md`, add after the `.actor` entry:

```
  .credentials   — CredentialResolver (SPI: resolve(credentialRef) → Map<String, String>),
                   CredentialPropertyKeys (reserved keys: USER, PASSWORD, BEARER_TOKEN, API_KEY, EXPIRES_AT)
```

- [ ] **Step 4: Run full platform build to verify nothing is broken**

Run: `mvn --batch-mode install -pl platform-api,platform`
Expected: BUILD SUCCESS for both modules.

- [ ] **Step 5: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/platform add platform/src/test/java/io/casehub/platform/mock/MockBeansTest.java CLAUDE.md
git -C /Users/mdproctor/claude/casehub/platform commit -m "feat(platform#103): CDI wiring test + CLAUDE.md package structure update"
```

---

### Task 4: Full build verification + deferred issue filing

**Files:**
- No new files — verification and issue creation only

**Interfaces:**
- Consumes: everything from Tasks 1–3
- Produces: verified green build; GitHub issues for deferred work

- [ ] **Step 1: Full project build**

Run: `mvn --batch-mode install`
Expected: BUILD SUCCESS across all modules. No downstream compilation breakage — the SPI adds new types without modifying existing ones.

- [ ] **Step 2: File deferred issues**

Create GitHub issues for the deferred scope items:

**Issue A — Quarkus CredentialsProvider bridge:**
Title: `feat(credentials): CredentialResolver bridge to Quarkus CredentialsProvider`
Body: `@Alternative @Priority(1)` in new `credentials-quarkus/` module. Delegates `resolve(credentialRef)` to `io.quarkus.credentials.CredentialsProvider.getCredentials(credentialRef)`. Enables Vault/AWS/GCP secret backends without application code changes. Depends on platform#103.

**Issue B — Tier 1.5 migration:**
Title: `refactor(qhorus): migrate slack-channel Tier 1.5 credentials to CredentialResolver`
Body: Replace `config.getValue("casehub.qhorus.slack-channel.credentials." + workspaceId)` in `SlackChannelBackend.resolveToken()` with `CredentialResolver.resolve(workspaceId)`. Depends on platform#103. Filed against `casehubio/qhorus`.

- [ ] **Step 3: Update GitHub issue #103 description**

Update the issue body to reflect the final design — `Map<String, String>` return type, `CredentialPropertyKeys` class, MicroProfile Config @DefaultBean (not env-var). The original description says `resolve(credentialRef) → String` which is outdated.

- [ ] **Step 4: Commit any CLAUDE.md or doc updates from build verification**

Only if Step 1 surfaced something requiring a doc fix.
