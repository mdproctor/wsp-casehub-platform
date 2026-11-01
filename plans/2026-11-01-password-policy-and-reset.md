# Password Policy and Reset Flow — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** #532 — Password authentication provider
**Issue group:** #532

**Goal:** Add password policy enforcement (local rules + HaveIBeenPwned
breach detection) and secure token-based password reset to the existing
registration module.

**Architecture:** New SPIs in `registration-api` (`PasswordPolicy`,
`BreachDetector`, `PasswordResetStore`), implementations in
`registration-core` (`DefaultPasswordPolicy`,
`HaveIBeenPwnedBreachDetector`), persistence mirroring the
`EmailVerificationStore` pattern across `user-inmem-core`, `user-jpa-common`,
`user-jpa`, `user-spring-jpa`. Reset flow added to the existing
`RegistrationService` SPI + `RegistrationServiceCore`.

**Tech Stack:** Java 21, Quarkus CDI, Spring Boot, JPA, Flyway,
`java.net.http.HttpClient` (for HIBP), Argon2id (existing)

## Global Constraints

- `registration-api` must remain zero-dependency (pure Java only)
- `registration-core` depends only on `registration-api` + `argon2-jvm` — `java.net.http.HttpClient` is JDK, not external
- All new SPIs get `@DefaultBean` (Quarkus) and `@ConditionalOnMissingBean` (Spring) defaults
- Follow existing `EmailVerificationStore` / `EmailVerificationToken` pattern exactly for reset tokens
- TDD: write failing test first, implement to pass, commit

---

## Batch 1: Password Policy SPIs and Implementation

### Task 1: Password policy SPIs in registration-api

**Files:**
- Create: `registration-api/src/main/java/io/casehub/platform/registration/PasswordPolicy.java`
- Create: `registration-api/src/main/java/io/casehub/platform/registration/PasswordPolicyResult.java`
- Create: `registration-api/src/main/java/io/casehub/platform/registration/BreachDetector.java`
- Create: `registration-api/src/main/java/io/casehub/platform/registration/PasswordPolicyViolationException.java`

**Interfaces:**
- Consumes: nothing (leaf SPIs)
- Produces: `PasswordPolicy.validate(String) → PasswordPolicyResult`, `BreachDetector.isBreached(String) → boolean`, `PasswordPolicyResult.ok()/.withWarnings(List)/.invalid(List)`, `PasswordPolicyViolationException(List<String> violations)`

- [ ] **Step 1: Create `PasswordPolicy` interface**

```java
package io.casehub.platform.registration;

public interface PasswordPolicy {
    PasswordPolicyResult validate(String password);
}
```

- [ ] **Step 2: Create `PasswordPolicyResult` record**

```java
package io.casehub.platform.registration;

import java.util.List;

public record PasswordPolicyResult(
    boolean valid,
    List<String> violations,
    List<String> warnings
) {
    public static PasswordPolicyResult ok() {
        return new PasswordPolicyResult(true, List.of(), List.of());
    }

    public static PasswordPolicyResult withWarnings(List<String> warnings) {
        return new PasswordPolicyResult(true, List.of(), List.copyOf(warnings));
    }

    public static PasswordPolicyResult invalid(List<String> violations) {
        return new PasswordPolicyResult(false, List.copyOf(violations), List.of());
    }

    public static PasswordPolicyResult invalid(List<String> violations, List<String> warnings) {
        return new PasswordPolicyResult(false, List.copyOf(violations), List.copyOf(warnings));
    }
}
```

- [ ] **Step 3: Create `BreachDetector` interface**

```java
package io.casehub.platform.registration;

public interface BreachDetector {
    boolean isBreached(String password);
}
```

- [ ] **Step 4: Create `PasswordPolicyViolationException`**

```java
package io.casehub.platform.registration;

import java.util.List;

public class PasswordPolicyViolationException extends RuntimeException {

    private final List<String> violations;

    public PasswordPolicyViolationException(List<String> violations) {
        super("Password policy violated: " + String.join(", ", violations));
        this.violations = List.copyOf(violations);
    }

    public List<String> violations() {
        return violations;
    }
}
```

- [ ] **Step 5: Compile check**

Run: `mvn --batch-mode compile -pl registration-api -am`
Expected: BUILD SUCCESS

- [ ] **Step 6: Commit**

```bash
git add registration-api/src/main/java/io/casehub/platform/registration/PasswordPolicy.java
git add registration-api/src/main/java/io/casehub/platform/registration/PasswordPolicyResult.java
git add registration-api/src/main/java/io/casehub/platform/registration/BreachDetector.java
git add registration-api/src/main/java/io/casehub/platform/registration/PasswordPolicyViolationException.java
git commit -m "feat(registration-api): add PasswordPolicy, BreachDetector SPIs and PasswordPolicyResult

Refs #532

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

### Task 2: DefaultPasswordPolicy and HaveIBeenPwnedBreachDetector

**Files:**
- Create: `registration-core/src/main/java/io/casehub/platform/registration/core/DefaultPasswordPolicy.java`
- Create: `registration-core/src/main/java/io/casehub/platform/registration/core/HaveIBeenPwnedBreachDetector.java`
- Create: `registration-core/src/main/java/io/casehub/platform/registration/core/NoOpBreachDetector.java`
- Create: `registration-core/src/test/java/io/casehub/platform/registration/core/DefaultPasswordPolicyTest.java`
- Create: `registration-core/src/test/java/io/casehub/platform/registration/core/HaveIBeenPwnedBreachDetectorTest.java`

**Interfaces:**
- Consumes: `PasswordPolicy`, `PasswordPolicyResult`, `BreachDetector` (from Task 1)
- Produces: `DefaultPasswordPolicy(BreachDetector)` constructor, `NoOpBreachDetector` (always returns false), `HaveIBeenPwnedBreachDetector()` constructor

- [ ] **Step 1: Write DefaultPasswordPolicy tests**

```java
package io.casehub.platform.registration.core;

import io.casehub.platform.registration.PasswordPolicyResult;
import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.*;

class DefaultPasswordPolicyTest {

    private final DefaultPasswordPolicy policyNoBreachCheck = new DefaultPasswordPolicy(null);

    @Test
    void validPassword_passes() {
        var result = policyNoBreachCheck.validate("Str0ngPass!");
        assertTrue(result.valid());
        assertTrue(result.violations().isEmpty());
    }

    @Test
    void tooShort_rejected() {
        var result = policyNoBreachCheck.validate("Ab1!");
        assertFalse(result.valid());
        assertTrue(result.violations().stream().anyMatch(v -> v.contains("at least 8")));
    }

    @Test
    void tooLong_rejected() {
        var result = policyNoBreachCheck.validate("A1" + "x".repeat(127));
        assertFalse(result.valid());
        assertTrue(result.violations().stream().anyMatch(v -> v.contains("128")));
    }

    @Test
    void singleCharacterClass_rejected() {
        var result = policyNoBreachCheck.validate("alllowercase");
        assertFalse(result.valid());
        assertTrue(result.violations().stream().anyMatch(v -> v.contains("character")));
    }

    @Test
    void twoCharacterClasses_passes() {
        var result = policyNoBreachCheck.validate("lowercase1");
        assertTrue(result.valid());
    }

    @Test
    void exactlyMinLength_passes() {
        var result = policyNoBreachCheck.validate("Abcdefg1");
        assertTrue(result.valid());
    }

    @Test
    void exactlyMaxLength_passes() {
        String pw = "A1" + "x".repeat(126);
        assertEquals(128, pw.length());
        var result = policyNoBreachCheck.validate(pw);
        assertTrue(result.valid());
    }

    @Test
    void nullPassword_rejected() {
        var result = policyNoBreachCheck.validate(null);
        assertFalse(result.valid());
    }

    @Test
    void emptyPassword_rejected() {
        var result = policyNoBreachCheck.validate("");
        assertFalse(result.valid());
    }

    @Test
    void multipleViolations_allCollected() {
        var result = policyNoBreachCheck.validate("aaa");
        assertFalse(result.valid());
        assertTrue(result.violations().size() >= 2);
    }

    @Test
    void breachedPassword_rejected() {
        var policy = new DefaultPasswordPolicy(password -> true);
        var result = policy.validate("Str0ngPass!");
        assertFalse(result.valid());
        assertTrue(result.violations().stream().anyMatch(v -> v.contains("breach")));
    }

    @Test
    void cleanPassword_withBreachCheck_passes() {
        var policy = new DefaultPasswordPolicy(password -> false);
        var result = policy.validate("Str0ngPass!");
        assertTrue(result.valid());
    }

    @Test
    void breachCheckThrows_warningNotViolation() {
        var policy = new DefaultPasswordPolicy(password -> {
            throw new RuntimeException("Network error");
        });
        var result = policy.validate("Str0ngPass!");
        assertTrue(result.valid());
        assertFalse(result.warnings().isEmpty());
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn --batch-mode test -pl registration-core -Dtest=DefaultPasswordPolicyTest`
Expected: FAIL (class not found)

- [ ] **Step 3: Implement DefaultPasswordPolicy**

```java
package io.casehub.platform.registration.core;

import io.casehub.platform.registration.BreachDetector;
import io.casehub.platform.registration.PasswordPolicy;
import io.casehub.platform.registration.PasswordPolicyResult;

import java.util.ArrayList;
import java.util.List;

public class DefaultPasswordPolicy implements PasswordPolicy {

    private static final int MIN_LENGTH = 8;
    private static final int MAX_LENGTH = 128;

    private final BreachDetector breachDetector;

    public DefaultPasswordPolicy(BreachDetector breachDetector) {
        this.breachDetector = breachDetector;
    }

    @Override
    public PasswordPolicyResult validate(String password) {
        List<String> violations = new ArrayList<>();
        List<String> warnings = new ArrayList<>();

        if (password == null || password.isEmpty()) {
            violations.add("Password must not be empty");
            return PasswordPolicyResult.invalid(violations);
        }

        if (password.length() < MIN_LENGTH) {
            violations.add("Password must be at least " + MIN_LENGTH + " characters");
        }

        if (password.length() > MAX_LENGTH) {
            violations.add("Password must not exceed " + MAX_LENGTH + " characters");
        }

        if (countCharacterClasses(password) < 2) {
            violations.add("Password must contain at least 2 character classes (lowercase, uppercase, digit, special)");
        }

        if (violations.isEmpty() && breachDetector != null) {
            try {
                if (breachDetector.isBreached(password)) {
                    violations.add("Password found in known data breach");
                }
            } catch (Exception e) {
                warnings.add("Breach detection unavailable");
            }
        }

        if (!violations.isEmpty()) {
            return PasswordPolicyResult.invalid(violations, warnings);
        }
        if (!warnings.isEmpty()) {
            return PasswordPolicyResult.withWarnings(warnings);
        }
        return PasswordPolicyResult.ok();
    }

    private static int countCharacterClasses(String password) {
        int classes = 0;
        if (password.chars().anyMatch(Character::isLowerCase)) classes++;
        if (password.chars().anyMatch(Character::isUpperCase)) classes++;
        if (password.chars().anyMatch(Character::isDigit)) classes++;
        if (password.chars().anyMatch(c -> !Character.isLetterOrDigit(c))) classes++;
        return classes;
    }
}
```

- [ ] **Step 4: Implement NoOpBreachDetector**

```java
package io.casehub.platform.registration.core;

import io.casehub.platform.registration.BreachDetector;

public class NoOpBreachDetector implements BreachDetector {
    @Override
    public boolean isBreached(String password) {
        return false;
    }
}
```

- [ ] **Step 5: Run DefaultPasswordPolicy tests to verify they pass**

Run: `mvn --batch-mode test -pl registration-core -Dtest=DefaultPasswordPolicyTest`
Expected: PASS (all 13 tests)

- [ ] **Step 6: Write HaveIBeenPwnedBreachDetector tests**

```java
package io.casehub.platform.registration.core;

import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.*;

class HaveIBeenPwnedBreachDetectorTest {

    @Test
    void sha1Prefix_isFiveCharacters() {
        String hash = HaveIBeenPwnedBreachDetector.sha1Hex("password");
        assertEquals(40, hash.length());
    }

    @Test
    void parsesBreachedSuffix() {
        String hash = HaveIBeenPwnedBreachDetector.sha1Hex("password");
        String suffix = hash.substring(5).toUpperCase();
        String responseBody = "0000000000000000000000000000000000A:1\r\n"
                + suffix + ":12345\r\n"
                + "FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF:2\r\n";
        assertTrue(HaveIBeenPwnedBreachDetector.containsSuffix(responseBody, suffix));
    }

    @Test
    void doesNotMatchAbsentSuffix() {
        String responseBody = "0000000000000000000000000000000000A:1\r\n"
                + "FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF:2\r\n";
        assertFalse(HaveIBeenPwnedBreachDetector.containsSuffix(responseBody, "ABCDE12345678901234567890123456789AB"));
    }
}
```

- [ ] **Step 7: Implement HaveIBeenPwnedBreachDetector**

```java
package io.casehub.platform.registration.core;

import io.casehub.platform.registration.BreachDetector;

import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.time.Duration;
import java.util.HexFormat;

public class HaveIBeenPwnedBreachDetector implements BreachDetector {

    private static final String API_URL = "https://api.pwnedpasswords.com/range/";
    private static final Duration TIMEOUT = Duration.ofSeconds(3);

    private final HttpClient httpClient;

    public HaveIBeenPwnedBreachDetector() {
        this.httpClient = HttpClient.newBuilder()
                .connectTimeout(TIMEOUT)
                .build();
    }

    HaveIBeenPwnedBreachDetector(HttpClient httpClient) {
        this.httpClient = httpClient;
    }

    @Override
    public boolean isBreached(String password) {
        String hash = sha1Hex(password).toUpperCase();
        String prefix = hash.substring(0, 5);
        String suffix = hash.substring(5);

        HttpRequest request = HttpRequest.newBuilder()
                .uri(URI.create(API_URL + prefix))
                .timeout(TIMEOUT)
                .GET()
                .build();

        try {
            HttpResponse<String> response = httpClient.send(request,
                    HttpResponse.BodyHandlers.ofString());
            if (response.statusCode() != 200) {
                throw new RuntimeException("HIBP API returned " + response.statusCode());
            }
            return containsSuffix(response.body(), suffix);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            throw new RuntimeException("HIBP check interrupted", e);
        } catch (Exception e) {
            throw new RuntimeException("HIBP check failed", e);
        }
    }

    static boolean containsSuffix(String responseBody, String suffix) {
        for (String line : responseBody.split("\r\n")) {
            int colonIdx = line.indexOf(':');
            if (colonIdx > 0 && line.substring(0, colonIdx).equalsIgnoreCase(suffix)) {
                return true;
            }
        }
        return false;
    }

    static String sha1Hex(String input) {
        try {
            byte[] digest = MessageDigest.getInstance("SHA-1")
                    .digest(input.getBytes(StandardCharsets.UTF_8));
            return HexFormat.of().formatHex(digest);
        } catch (NoSuchAlgorithmException e) {
            throw new IllegalStateException("SHA-1 not available", e);
        }
    }
}
```

- [ ] **Step 8: Run HaveIBeenPwnedBreachDetector tests**

Run: `mvn --batch-mode test -pl registration-core -Dtest=HaveIBeenPwnedBreachDetectorTest`
Expected: PASS (all 3 tests)

- [ ] **Step 9: Commit**

```bash
git add registration-core/src/main/java/io/casehub/platform/registration/core/DefaultPasswordPolicy.java
git add registration-core/src/main/java/io/casehub/platform/registration/core/HaveIBeenPwnedBreachDetector.java
git add registration-core/src/main/java/io/casehub/platform/registration/core/NoOpBreachDetector.java
git add registration-core/src/test/java/io/casehub/platform/registration/core/DefaultPasswordPolicyTest.java
git add registration-core/src/test/java/io/casehub/platform/registration/core/HaveIBeenPwnedBreachDetectorTest.java
git commit -m "feat(registration-core): DefaultPasswordPolicy, HIBP breach detector, NoOp fallback

Refs #532

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

### Task 3: Wire policy into registration + CDI/Spring beans

**Files:**
- Modify: `registration-core/src/main/java/io/casehub/platform/registration/core/RegistrationServiceCore.java`
- Modify: `registration-core/src/test/java/io/casehub/platform/registration/core/RegistrationServiceCoreTest.java`
- Modify: `registration/src/main/java/io/casehub/platform/registration/quarkus/RegistrationBeans.java`
- Modify: `registration-spring/src/main/java/io/casehub/platform/registration/spring/RegistrationSpringAutoConfiguration.java`

**Interfaces:**
- Consumes: `PasswordPolicy`, `DefaultPasswordPolicy`, `NoOpBreachDetector` (from Tasks 1-2), `RegistrationServiceCore` constructor (existing)
- Produces: `RegistrationServiceCore` now accepts `PasswordPolicy` in constructor and validates before hashing

- [ ] **Step 1: Write test for policy rejection in registerWithPassword**

Add to `RegistrationServiceCoreTest.java`:

```java
@Test
void registerWithPassword_weakPassword_throwsPolicyViolation() {
    var policy = new DefaultPasswordPolicy(null);
    rebuildServiceWithPolicy(policy);
    var request = new PasswordRegistrationRequest(
            "user@example.com", "weak", null, "tenant-1", null);
    var ex = assertThrows(PasswordPolicyViolationException.class,
            () -> service.registerWithPassword(request));
    assertFalse(ex.violations().isEmpty());
}

@Test
void registerWithPassword_strongPassword_succeeds() {
    var policy = new DefaultPasswordPolicy(null);
    rebuildServiceWithPolicy(policy);
    var request = new PasswordRegistrationRequest(
            "user@example.com", "Str0ngPass!", null, "tenant-1", null);
    var result = service.registerWithPassword(request);
    assertInstanceOf(RegistrationResult.PendingVerification.class, result);
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mvn --batch-mode test -pl registration-core -Dtest="RegistrationServiceCoreTest#registerWithPassword_weakPassword_throwsPolicyViolation+registerWithPassword_strongPassword_succeeds"`
Expected: FAIL (constructor doesn't accept PasswordPolicy)

- [ ] **Step 3: Add PasswordPolicy to RegistrationServiceCore constructor**

Add `PasswordPolicy` as the 9th constructor parameter. Add a field `private final PasswordPolicy passwordPolicy`. In `registerWithPassword()`, insert validation after the existing-user check and before password hashing (line 104):

```java
var policyResult = passwordPolicy.validate(request.password());
if (!policyResult.valid()) {
    throw new PasswordPolicyViolationException(policyResult.violations());
}
```

- [ ] **Step 4: Update existing setUp() in test to pass NoOp policy**

The existing `RegistrationServiceCoreTest.setUp()` and `rebuildService()` methods must pass a `PasswordPolicy` that accepts everything (so existing tests are unaffected). Add a simple lambda `password -> PasswordPolicyResult.ok()` as the 9th arg. Add the `rebuildServiceWithPolicy(PasswordPolicy)` helper for the new tests.

- [ ] **Step 5: Run all RegistrationServiceCoreTest to verify pass**

Run: `mvn --batch-mode test -pl registration-core -Dtest=RegistrationServiceCoreTest`
Expected: PASS (all tests including new ones)

- [ ] **Step 6: Update RegistrationBeans — produce PasswordPolicy and BreachDetector**

Add to `RegistrationBeans.java`:

```java
@Produces
@DefaultBean
@ApplicationScoped
public BreachDetector noOpBreachDetector() {
    return new NoOpBreachDetector();
}

@Produces
@ApplicationScoped
public PasswordPolicy defaultPasswordPolicy(BreachDetector breachDetector) {
    return new DefaultPasswordPolicy(breachDetector);
}
```

Update the `registrationService` producer to accept `PasswordPolicy` as a parameter and pass it to the `RegistrationServiceCore` constructor.

- [ ] **Step 7: Update RegistrationSpringAutoConfiguration — produce PasswordPolicy and BreachDetector**

Add to `RegistrationSpringAutoConfiguration.java`:

```java
@Bean
@ConditionalOnMissingBean
public BreachDetector breachDetector() {
    return new NoOpBreachDetector();
}

@Bean
@ConditionalOnMissingBean
public PasswordPolicy passwordPolicy(BreachDetector breachDetector) {
    return new DefaultPasswordPolicy(breachDetector);
}
```

Update the `registrationService` bean to accept `PasswordPolicy` and pass it through.

- [ ] **Step 8: Full compile check**

Run: `mvn --batch-mode compile -pl registration-api,registration-core,registration,registration-spring -am`
Expected: BUILD SUCCESS

- [ ] **Step 9: Commit**

```bash
git add registration-core/src/main/java/io/casehub/platform/registration/core/RegistrationServiceCore.java
git add registration-core/src/test/java/io/casehub/platform/registration/core/RegistrationServiceCoreTest.java
git add registration/src/main/java/io/casehub/platform/registration/quarkus/RegistrationBeans.java
git add registration-spring/src/main/java/io/casehub/platform/registration/spring/RegistrationSpringAutoConfiguration.java
git commit -m "feat: wire PasswordPolicy into registration service + CDI/Spring beans

Refs #532

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

## Batch 2: Password Reset Flow

### Task 4: Password reset SPIs and in-memory store

**Files:**
- Create: `registration-api/src/main/java/io/casehub/platform/registration/PasswordResetToken.java`
- Create: `registration-api/src/main/java/io/casehub/platform/registration/PasswordResetStore.java`
- Create: `registration-api/src/main/java/io/casehub/platform/registration/PasswordResetRequested.java`
- Create: `registration-api/src/main/java/io/casehub/platform/registration/PasswordResetCompleted.java`
- Create: `user-inmem-core/src/main/java/io/casehub/platform/registration/inmem/InMemoryPasswordResetStore.java`
- Create: `user-inmem-core/src/test/java/io/casehub/platform/registration/inmem/InMemoryPasswordResetStoreTest.java`

**Interfaces:**
- Consumes: nothing (leaf SPIs)
- Produces: `PasswordResetToken(tokenHash, userId, tenancyId, expiresAt, createdAt)`, `PasswordResetStore.store(token)/consume(rawToken)`, `PasswordResetRequested(userId, tenancyId, requestedAt)`, `PasswordResetCompleted(userId, tenancyId, completedAt)`, `InMemoryPasswordResetStore`

- [ ] **Step 1: Create PasswordResetToken record**

```java
package io.casehub.platform.registration;

import java.time.Instant;

public record PasswordResetToken(
    String tokenHash,
    String userId,
    String tenancyId,
    Instant expiresAt,
    Instant createdAt
) {}
```

- [ ] **Step 2: Create PasswordResetStore interface**

```java
package io.casehub.platform.registration;

import java.util.Optional;

public interface PasswordResetStore {
    void store(PasswordResetToken token);
    Optional<PasswordResetToken> consume(String rawToken);
}
```

- [ ] **Step 3: Create CDI event records**

`PasswordResetRequested.java`:
```java
package io.casehub.platform.registration;

import java.time.Instant;

public record PasswordResetRequested(String userId, String tenancyId, Instant requestedAt) {}
```

`PasswordResetCompleted.java`:
```java
package io.casehub.platform.registration;

import java.time.Instant;

public record PasswordResetCompleted(String userId, String tenancyId, Instant completedAt) {}
```

- [ ] **Step 4: Write InMemoryPasswordResetStore tests**

```java
package io.casehub.platform.registration.inmem;

import io.casehub.platform.registration.PasswordResetToken;
import org.junit.jupiter.api.Test;

import java.time.Instant;

import static org.junit.jupiter.api.Assertions.*;

class InMemoryPasswordResetStoreTest {

    private final InMemoryPasswordResetStore store = new InMemoryPasswordResetStore();

    @Test
    void storeAndConsume_returnsToken() {
        String rawToken = "test-raw-token";
        String hash = InMemoryPasswordResetStore.sha256Hex(rawToken);
        var token = new PasswordResetToken(hash, "user-1", "tenant-1",
                Instant.now().plusSeconds(3600), Instant.now());
        store.store(token);

        var result = store.consume(rawToken);
        assertTrue(result.isPresent());
        assertEquals("user-1", result.get().userId());
    }

    @Test
    void consume_removesToken_singleUse() {
        String rawToken = "test-raw-token";
        String hash = InMemoryPasswordResetStore.sha256Hex(rawToken);
        var token = new PasswordResetToken(hash, "user-1", "tenant-1",
                Instant.now().plusSeconds(3600), Instant.now());
        store.store(token);

        store.consume(rawToken);
        var second = store.consume(rawToken);
        assertTrue(second.isEmpty());
    }

    @Test
    void consume_expired_returnsEmpty() {
        String rawToken = "test-raw-token";
        String hash = InMemoryPasswordResetStore.sha256Hex(rawToken);
        var token = new PasswordResetToken(hash, "user-1", "tenant-1",
                Instant.now().minusSeconds(1), Instant.now().minusSeconds(3600));
        store.store(token);

        var result = store.consume(rawToken);
        assertTrue(result.isEmpty());
    }

    @Test
    void consume_unknownToken_returnsEmpty() {
        var result = store.consume("nonexistent");
        assertTrue(result.isEmpty());
    }
}
```

- [ ] **Step 5: Run tests to verify they fail**

Run: `mvn --batch-mode test -pl user-inmem-core -Dtest=InMemoryPasswordResetStoreTest`
Expected: FAIL (class not found)

- [ ] **Step 6: Implement InMemoryPasswordResetStore**

Mirror `InMemoryEmailVerificationStore` exactly:

```java
package io.casehub.platform.registration.inmem;

import io.casehub.platform.registration.PasswordResetStore;
import io.casehub.platform.registration.PasswordResetToken;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.time.Instant;
import java.util.HexFormat;
import java.util.Optional;
import java.util.concurrent.ConcurrentHashMap;

public class InMemoryPasswordResetStore implements PasswordResetStore {

    private final ConcurrentHashMap<String, PasswordResetToken> store = new ConcurrentHashMap<>();

    @Override
    public void store(PasswordResetToken token) {
        store.put(token.tokenHash(), token);
    }

    @Override
    public Optional<PasswordResetToken> consume(String rawToken) {
        String hash = sha256Hex(rawToken);
        var token = store.remove(hash);
        if (token == null) {
            return Optional.empty();
        }
        if (token.expiresAt() != null && token.expiresAt().isBefore(Instant.now())) {
            return Optional.empty();
        }
        return Optional.of(token);
    }

    static String sha256Hex(String input) {
        try {
            byte[] digest = MessageDigest.getInstance("SHA-256")
                    .digest(input.getBytes(StandardCharsets.UTF_8));
            return HexFormat.of().formatHex(digest);
        } catch (NoSuchAlgorithmException e) {
            throw new IllegalStateException("SHA-256 not available", e);
        }
    }
}
```

- [ ] **Step 7: Run tests to verify they pass**

Run: `mvn --batch-mode test -pl user-inmem-core -Dtest=InMemoryPasswordResetStoreTest`
Expected: PASS (all 4 tests)

- [ ] **Step 8: Commit**

```bash
git add registration-api/src/main/java/io/casehub/platform/registration/PasswordResetToken.java
git add registration-api/src/main/java/io/casehub/platform/registration/PasswordResetStore.java
git add registration-api/src/main/java/io/casehub/platform/registration/PasswordResetRequested.java
git add registration-api/src/main/java/io/casehub/platform/registration/PasswordResetCompleted.java
git add user-inmem-core/src/main/java/io/casehub/platform/registration/inmem/InMemoryPasswordResetStore.java
git add user-inmem-core/src/test/java/io/casehub/platform/registration/inmem/InMemoryPasswordResetStoreTest.java
git commit -m "feat(registration): password reset token SPI, events, and in-memory store

Refs #532

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

### Task 5: Password reset service logic + event listener + CDI/Spring wiring

**Files:**
- Modify: `registration-api/src/main/java/io/casehub/platform/registration/RegistrationService.java` — add 2 methods
- Modify: `registration-api/src/main/java/io/casehub/platform/registration/RegistrationEventListener.java` — add 2 event callbacks
- Modify: `registration-core/src/main/java/io/casehub/platform/registration/core/RegistrationServiceCore.java` — implement reset methods
- Modify: `registration-core/src/test/java/io/casehub/platform/registration/core/RegistrationServiceCoreTest.java` — add reset tests
- Modify: `registration/src/main/java/io/casehub/platform/registration/quarkus/RegistrationBeans.java` — pass PasswordResetStore
- Modify: `registration/src/main/java/io/casehub/platform/registration/quarkus/RegistrationEndpoint.java` — add 2 endpoints
- Modify: `registration/src/main/java/io/casehub/platform/registration/quarkus/RegistrationAuthenticationEventListener.java` — bridge new events
- Modify: `registration-spring/src/main/java/io/casehub/platform/registration/spring/RegistrationSpringAutoConfiguration.java` — pass PasswordResetStore
- Modify: `user-inmem/src/main/java/io/casehub/platform/registration/inmem/quarkus/UserInmemBeans.java` — produce reset store

**Interfaces:**
- Consumes: `PasswordResetStore`, `PasswordResetToken`, `PasswordResetRequested`, `PasswordResetCompleted` (from Task 4), `PasswordPolicy` (from Task 1), `TokenGenerator`, `PasswordHasher`, `UserStore`, `PasswordCredentialStore`, `EmailSender` (all existing)
- Produces: `RegistrationService.requestPasswordReset(email, tenancyId)`, `RegistrationService.resetPassword(token, newPassword, tenancyId)`

- [ ] **Step 1: Add methods to RegistrationService SPI**

Add to `RegistrationService.java`:
```java
void requestPasswordReset(String email, String tenancyId);
RegistrationResult resetPassword(String rawToken, String newPassword, String tenancyId);
```

- [ ] **Step 2: Add event callbacks to RegistrationEventListener**

Add to `RegistrationEventListener.java`:
```java
default void onPasswordResetRequested(PasswordResetRequested event) {}
default void onPasswordResetCompleted(PasswordResetCompleted event) {}
```

- [ ] **Step 3: Write reset tests in RegistrationServiceCoreTest**

```java
@Test
void requestPasswordReset_activeUser_sendsEmail() {
    registerAndActivateUser("user@example.com", "Str0ngPass!");
    service.requestPasswordReset("user@example.com", "tenant-1");
    assertEquals(2, emailSender.sent.size()); // 1st = verification, 2nd = reset
    assertTrue(emailSender.sent.get(1).subject().contains("reset"));
}

@Test
void requestPasswordReset_unknownEmail_silentlySucceeds() {
    service.requestPasswordReset("unknown@example.com", "tenant-1");
    assertTrue(emailSender.sent.isEmpty());
}

@Test
void requestPasswordReset_inactiveUser_silentlySucceeds() {
    registerUser("user@example.com", "Str0ngPass!");
    // user is PENDING_VERIFICATION, not ACTIVE
    service.requestPasswordReset("user@example.com", "tenant-1");
    assertEquals(1, emailSender.sent.size()); // only verification email, no reset
}

@Test
void resetPassword_validToken_updatesPassword() {
    registerAndActivateUser("user@example.com", "Str0ngPass!");
    service.requestPasswordReset("user@example.com", "tenant-1");
    String rawToken = extractResetToken();

    var result = service.resetPassword(rawToken, "NewStr0ng!", "tenant-1");
    assertInstanceOf(RegistrationResult.Activated.class, result);
}

@Test
void resetPassword_invalidToken_throws() {
    assertThrows(IllegalArgumentException.class,
            () -> service.resetPassword("bogus", "NewStr0ng!", "tenant-1"));
}

@Test
void resetPassword_weakNewPassword_throws() {
    registerAndActivateUser("user@example.com", "Str0ngPass!");
    service.requestPasswordReset("user@example.com", "tenant-1");
    String rawToken = extractResetToken();

    assertThrows(PasswordPolicyViolationException.class,
            () -> service.resetPassword(rawToken, "weak", "tenant-1"));
}

@Test
void resetPassword_tenancyMismatch_throws() {
    registerAndActivateUser("user@example.com", "Str0ngPass!");
    service.requestPasswordReset("user@example.com", "tenant-1");
    String rawToken = extractResetToken();

    assertThrows(IllegalArgumentException.class,
            () -> service.resetPassword(rawToken, "NewStr0ng!", "wrong-tenant"));
}
```

Helper methods to add:
```java
private void registerUser(String email, String password) {
    service.registerWithPassword(new PasswordRegistrationRequest(
            email, password, null, "tenant-1", null));
}

private void registerAndActivateUser(String email, String password) {
    registerUser(email, password);
    String verificationToken = extractVerificationToken();
    service.verifyEmail(verificationToken);
    // If approval required, approve
    var user = userStore.findByEmail(email, "tenant-1").orElseThrow();
    if (user.status() == UserStatus.PENDING_APPROVAL) {
        service.approveRegistration(user.id(), "tenant-1");
    }
}

private String extractResetToken() {
    var lastEmail = emailSender.sent.get(emailSender.sent.size() - 1);
    // Token format: "Your password reset token: <token>"
    return lastEmail.body().replace("Your password reset token: ", "");
}
```

- [ ] **Step 4: Run tests to verify they fail**

Run: `mvn --batch-mode test -pl registration-core -Dtest="RegistrationServiceCoreTest#requestPasswordReset*+resetPassword*"`
Expected: FAIL (methods not implemented)

- [ ] **Step 5: Add PasswordResetStore field to RegistrationServiceCore constructor**

Add `PasswordResetStore passwordResetStore` as a constructor parameter (10th param, after `passwordPolicy`). Add field. Add `private static final Duration RESET_TOKEN_TTL = Duration.ofHours(1);`

- [ ] **Step 6: Implement requestPasswordReset**

```java
@Override
public void requestPasswordReset(String email, String tenancyId) {
    var user = userStore.findByEmail(email, tenancyId).orElse(null);
    if (user == null || user.status() != UserStatus.ACTIVE) {
        return; // silent — no user enumeration
    }

    String rawToken = TokenGenerator.generate();
    var now = Instant.now();
    passwordResetStore.store(new PasswordResetToken(
            TokenGenerator.sha256Hex(rawToken),
            user.id(),
            tenancyId,
            now.plus(RESET_TOKEN_TTL),
            now));

    emailSender.send(email,
            "Password reset request",
            "Your password reset token: " + rawToken);

    eventListener.onPasswordResetRequested(
            new PasswordResetRequested(user.id(), tenancyId, now));
}
```

- [ ] **Step 7: Implement resetPassword**

```java
@Override
public RegistrationResult resetPassword(String rawToken, String newPassword, String tenancyId) {
    var token = passwordResetStore.consume(rawToken)
            .orElseThrow(() -> new IllegalArgumentException("Invalid or expired reset token"));

    if (!token.tenancyId().equals(tenancyId)) {
        throw new IllegalArgumentException("Tenancy mismatch");
    }

    var policyResult = passwordPolicy.validate(newPassword);
    if (!policyResult.valid()) {
        throw new PasswordPolicyViolationException(policyResult.violations());
    }

    String hashedPassword = passwordHasher.hash(newPassword);
    passwordCredentialStore.updatePassword(token.userId(), tenancyId, hashedPassword);

    var user = userStore.findById(token.userId(), tenancyId).orElseThrow();
    eventListener.onPasswordResetCompleted(
            new PasswordResetCompleted(token.userId(), tenancyId, Instant.now()));

    return new RegistrationResult.Activated(user);
}
```

- [ ] **Step 8: Update test setUp to pass InMemoryPasswordResetStore**

In `RegistrationServiceCoreTest`, add `private InMemoryPasswordResetStore resetStore` field. Update `rebuildService()` and `rebuildServiceWithPolicy()` to pass the reset store as the 10th arg.

- [ ] **Step 9: Run all RegistrationServiceCoreTest**

Run: `mvn --batch-mode test -pl registration-core -Dtest=RegistrationServiceCoreTest`
Expected: PASS (all tests)

- [ ] **Step 10: Update RegistrationBeans**

Update `registrationService` producer to accept `PasswordResetStore` and pass it through. Update `UserInmemBeans` to produce `InMemoryPasswordResetStore`:

```java
@Produces
@Alternative
@Priority(100)
@ApplicationScoped
public PasswordResetStore inMemoryPasswordResetStore() {
    return new InMemoryPasswordResetStore();
}
```

- [ ] **Step 11: Update RegistrationEndpoint**

Add to `RegistrationEndpoint.java`:
```java
@PlatformMutation
public void requestPasswordReset(String email, String tenancyId) {
    registrationService.requestPasswordReset(email, tenancyId);
}

@PlatformMutation
public RegistrationResult resetPassword(String token, String newPassword, String tenancyId) {
    return registrationService.resetPassword(token, newPassword, tenancyId);
}
```

- [ ] **Step 12: Update RegistrationAuthenticationEventListener**

Add CDI event bridge methods for `PasswordResetRequested` and `PasswordResetCompleted`, following the existing pattern for `UserRegistered`/`UserActivated`.

- [ ] **Step 13: Update RegistrationSpringAutoConfiguration**

Update `registrationService` bean to accept `PasswordResetStore` and pass it through. Add `SpringRegistrationEventBridge` methods for the new events.

- [ ] **Step 14: Full compile**

Run: `mvn --batch-mode compile -pl registration-api,registration-core,registration,registration-spring,user-inmem,user-inmem-core -am`
Expected: BUILD SUCCESS

- [ ] **Step 15: Commit**

```bash
git add registration-api/src/main/java/io/casehub/platform/registration/RegistrationService.java
git add registration-api/src/main/java/io/casehub/platform/registration/RegistrationEventListener.java
git add registration-core/src/main/java/io/casehub/platform/registration/core/RegistrationServiceCore.java
git add registration-core/src/test/java/io/casehub/platform/registration/core/RegistrationServiceCoreTest.java
git add registration/src/main/java/io/casehub/platform/registration/quarkus/RegistrationBeans.java
git add registration/src/main/java/io/casehub/platform/registration/quarkus/RegistrationEndpoint.java
git add registration/src/main/java/io/casehub/platform/registration/quarkus/RegistrationAuthenticationEventListener.java
git add registration-spring/src/main/java/io/casehub/platform/registration/spring/RegistrationSpringAutoConfiguration.java
git add user-inmem/src/main/java/io/casehub/platform/registration/inmem/quarkus/UserInmemBeans.java
git commit -m "feat: password reset flow — service logic, endpoints, CDI/Spring wiring

Refs #532

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

## Batch 3: JPA Persistence and Documentation

### Task 6: JPA persistence for password reset tokens

**Files:**
- Create: `user-jpa-common/src/main/java/io/casehub/platform/registration/jpa/PasswordResetTokenEntity.java`
- Create: `user-jpa-common/src/main/resources/db/registration/migration/V9004__registration_password_reset_token.sql`
- Create: `user-jpa/src/main/java/io/casehub/platform/registration/jpa/JpaPasswordResetStore.java`
- Create: `user-spring-jpa/src/main/java/io/casehub/platform/registration/spring/jpa/PasswordResetTokenEntityRepository.java`
- Create: `user-spring-jpa/src/main/java/io/casehub/platform/registration/spring/jpa/SpringPasswordResetStore.java`
- Modify: `user-spring-jpa/src/main/java/io/casehub/platform/registration/spring/jpa/UserJpaAutoConfiguration.java`

**Interfaces:**
- Consumes: `PasswordResetStore`, `PasswordResetToken` (from Task 4)
- Produces: `JpaPasswordResetStore`, `SpringPasswordResetStore`, `PasswordResetTokenEntity`, Flyway V9004

- [ ] **Step 1: Create Flyway migration**

`V9004__registration_password_reset_token.sql`:
```sql
CREATE TABLE registration_password_reset_token (
    token_hash    VARCHAR(64)  NOT NULL,
    user_id       VARCHAR(255) NOT NULL,
    tenancy_id    VARCHAR(255) NOT NULL,
    expires_at    TIMESTAMP    NOT NULL,
    created_at    TIMESTAMP    NOT NULL,
    PRIMARY KEY (token_hash)
);
```

- [ ] **Step 2: Create PasswordResetTokenEntity**

Mirror `EmailVerificationEntity`:

```java
package io.casehub.platform.registration.jpa;

import io.casehub.platform.registration.PasswordResetToken;
import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.Id;
import jakarta.persistence.Table;

import java.time.Instant;

@Entity
@Table(name = "registration_password_reset_token")
public class PasswordResetTokenEntity {

    @Id
    @Column(name = "token_hash", length = 64)
    public String tokenHash;

    @Column(name = "user_id", nullable = false)
    public String userId;

    @Column(name = "tenancy_id", nullable = false)
    public String tenancyId;

    @Column(name = "expires_at", nullable = false)
    public Instant expiresAt;

    @Column(name = "created_at", nullable = false)
    public Instant createdAt;

    public static PasswordResetTokenEntity fromToken(PasswordResetToken token) {
        PasswordResetTokenEntity e = new PasswordResetTokenEntity();
        e.tokenHash = token.tokenHash();
        e.userId = token.userId();
        e.tenancyId = token.tenancyId();
        e.expiresAt = token.expiresAt();
        e.createdAt = token.createdAt();
        return e;
    }

    public PasswordResetToken toToken() {
        return new PasswordResetToken(tokenHash, userId, tenancyId, expiresAt, createdAt);
    }
}
```

- [ ] **Step 3: Create JpaPasswordResetStore**

Mirror `JpaEmailVerificationStore`:

```java
package io.casehub.platform.registration.jpa;

import io.casehub.platform.registration.PasswordResetStore;
import io.casehub.platform.registration.PasswordResetToken;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;
import jakarta.persistence.EntityManager;
import jakarta.transaction.Transactional;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.time.Instant;
import java.util.HexFormat;
import java.util.Optional;

@ApplicationScoped
public class JpaPasswordResetStore implements PasswordResetStore {

    @Inject
    EntityManager em;

    @Override
    @Transactional
    public void store(PasswordResetToken token) {
        em.persist(PasswordResetTokenEntity.fromToken(token));
    }

    @Override
    @Transactional
    public Optional<PasswordResetToken> consume(String rawToken) {
        String hash = sha256Hex(rawToken);
        PasswordResetTokenEntity entity = em.find(PasswordResetTokenEntity.class, hash);
        if (entity == null) {
            return Optional.empty();
        }
        if (entity.expiresAt.isBefore(Instant.now())) {
            em.remove(entity);
            return Optional.empty();
        }
        PasswordResetToken token = entity.toToken();
        em.remove(entity);
        return Optional.of(token);
    }

    private static String sha256Hex(String input) {
        try {
            byte[] digest = MessageDigest.getInstance("SHA-256")
                    .digest(input.getBytes(StandardCharsets.UTF_8));
            return HexFormat.of().formatHex(digest);
        } catch (NoSuchAlgorithmException e) {
            throw new IllegalStateException("SHA-256 not available", e);
        }
    }
}
```

- [ ] **Step 4: Create Spring JPA repository and store**

`PasswordResetTokenEntityRepository.java`:
```java
package io.casehub.platform.registration.spring.jpa;

import io.casehub.platform.registration.jpa.PasswordResetTokenEntity;
import org.springframework.data.jpa.repository.JpaRepository;

public interface PasswordResetTokenEntityRepository extends JpaRepository<PasswordResetTokenEntity, String> {
}
```

`SpringPasswordResetStore.java` — mirror `SpringEmailVerificationStore`:
```java
package io.casehub.platform.registration.spring.jpa;

import io.casehub.platform.registration.PasswordResetStore;
import io.casehub.platform.registration.PasswordResetToken;
import io.casehub.platform.registration.jpa.PasswordResetTokenEntity;
import org.springframework.transaction.annotation.Transactional;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.time.Instant;
import java.util.HexFormat;
import java.util.Optional;

public class SpringPasswordResetStore implements PasswordResetStore {

    private final PasswordResetTokenEntityRepository repo;

    public SpringPasswordResetStore(PasswordResetTokenEntityRepository repo) {
        this.repo = repo;
    }

    @Override
    @Transactional
    public void store(PasswordResetToken token) {
        repo.save(PasswordResetTokenEntity.fromToken(token));
    }

    @Override
    @Transactional
    public Optional<PasswordResetToken> consume(String rawToken) {
        String hash = sha256Hex(rawToken);
        return repo.findById(hash).map(entity -> {
            if (entity.expiresAt.isBefore(Instant.now())) {
                repo.delete(entity);
                return null;
            }
            PasswordResetToken token = entity.toToken();
            repo.delete(entity);
            return token;
        });
    }

    private static String sha256Hex(String input) {
        try {
            byte[] digest = MessageDigest.getInstance("SHA-256")
                    .digest(input.getBytes(StandardCharsets.UTF_8));
            return HexFormat.of().formatHex(digest);
        } catch (NoSuchAlgorithmException e) {
            throw new IllegalStateException("SHA-256 not available", e);
        }
    }
}
```

- [ ] **Step 5: Update UserJpaAutoConfiguration**

Add bean method:
```java
@Bean
@ConditionalOnMissingBean
public SpringPasswordResetStore springPasswordResetStore(PasswordResetTokenEntityRepository repo) {
    return new SpringPasswordResetStore(repo);
}
```

- [ ] **Step 6: Compile check**

Run: `mvn --batch-mode compile -pl user-jpa-common,user-jpa,user-spring-jpa -am`
Expected: BUILD SUCCESS

- [ ] **Step 7: Commit**

```bash
git add user-jpa-common/src/main/java/io/casehub/platform/registration/jpa/PasswordResetTokenEntity.java
git add user-jpa-common/src/main/resources/db/registration/migration/V9004__registration_password_reset_token.sql
git add user-jpa/src/main/java/io/casehub/platform/registration/jpa/JpaPasswordResetStore.java
git add user-spring-jpa/src/main/java/io/casehub/platform/registration/spring/jpa/PasswordResetTokenEntityRepository.java
git add user-spring-jpa/src/main/java/io/casehub/platform/registration/spring/jpa/SpringPasswordResetStore.java
git add user-spring-jpa/src/main/java/io/casehub/platform/registration/spring/jpa/UserJpaAutoConfiguration.java
git commit -m "feat: JPA + Spring Data persistence for password reset tokens

Refs #532

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

### Task 7: Full build verification and documentation

**Files:**
- Modify: `docs/guides/consumer-guide.md` — document password policy and reset flow

**Interfaces:**
- Consumes: all prior tasks
- Produces: verified full build, updated documentation

- [ ] **Step 1: Full build**

Run: `mvn --batch-mode install`
Expected: BUILD SUCCESS (all modules compile and tests pass)

- [ ] **Step 2: Update consumer-guide.md**

Add to the Registration section in `docs/guides/consumer-guide.md`:

```markdown
**Password policy** — enforced on registration and password reset. Default rules:
minimum 8 characters, maximum 128, at least 2 character classes. Optional
HaveIBeenPwned breach detection (disabled by default; enable with
`casehub.registration.breach-detection.enabled=true`). Custom policies:
implement `PasswordPolicy` and register as a CDI bean / Spring `@Bean`.

**Password reset** — `RegistrationService.requestPasswordReset(email, tenancyId)`
sends a reset token via email (1-hour TTL). `resetPassword(token, newPassword,
tenancyId)` validates the token, enforces password policy, and updates the
credential. Silent on unknown emails (no user enumeration). Single-use tokens.

CDI events: `PasswordResetRequested`, `PasswordResetCompleted`.
```

- [ ] **Step 3: Commit**

```bash
git add docs/guides/consumer-guide.md
git commit -m "docs: document password policy and reset flow in consumer guide

Refs #532

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

## References

- [2026-11-01-password-policy-and-reset-design.md] — design spec this plan implements
- `registration-api/.../EmailVerificationStore.java` — store SPI pattern
- `registration-api/.../EmailVerificationToken.java` — token record pattern
- `registration-api/.../RegistrationService.java` — service SPI to extend
- `registration-api/.../RegistrationEventListener.java` — event listener pattern
- `registration-core/.../RegistrationServiceCore.java` — service implementation to extend
- `registration-core/.../TokenGenerator.java` — token generation utility (reused)
- `registration-core/.../Argon2PasswordHasher.java` — hashing (reused)
- `user-inmem-core/.../InMemoryEmailVerificationStore.java` — in-memory store pattern
- `user-jpa-common/.../EmailVerificationEntity.java` — JPA entity pattern
- `user-jpa/.../JpaEmailVerificationStore.java` — JPA store pattern
- `user-spring-jpa/.../SpringEmailVerificationStore.java` — Spring store pattern
- `user-spring-jpa/.../UserJpaAutoConfiguration.java` — Spring auto-config pattern
- `registration/.../RegistrationBeans.java` — CDI producer pattern
- `registration-spring/.../RegistrationSpringAutoConfiguration.java` — Spring config pattern
- GitHub #532 — focal issue
