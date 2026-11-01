# Password Policy and Reset Flow — Design Spec

**Issue:** casehubio/platform#532
**Branch:** issue-532-password-auth-provider
**Date:** 2026-11-01

## Summary

Add password policy enforcement (local rules + HaveIBeenPwned breach detection)
and a secure token-based password reset flow. Both integrate into the existing
registration module — new SPIs in `registration-api`, implementations in
`registration-core`, persistence in the existing `user-*` modules.

## Existing Infrastructure (from #531)

Already implemented and tested:
- `PasswordAuthenticationProviderCore` — login flow with timing equalization
- `Argon2PasswordHasher` — Argon2id (64MB, 3 iterations)
- `PasswordCredentialStore` — including `updatePassword()` (exists, unused)
- `EmailVerificationToken`/`EmailVerificationStore` — hash-and-consume pattern
- `TokenGenerator` — 256-bit SecureRandom + SHA-256
- `RegistrationServiceCore` — owns the password credential lifecycle

## 1. Password Policy

### SPIs (registration-api)

**`PasswordPolicy`** — validates a candidate password before hashing.

```java
public interface PasswordPolicy {
    PasswordPolicyResult validate(String password);
}
```

**`PasswordPolicyResult`** — sealed result with violations and warnings.

```java
public record PasswordPolicyResult(
    boolean valid,
    List<String> violations,
    List<String> warnings
) {
    public static PasswordPolicyResult ok() { ... }
    public static PasswordPolicyResult withWarnings(List<String> warnings) { ... }
    public static PasswordPolicyResult invalid(List<String> violations) { ... }
}
```

`violations` are hard failures (password rejected). `warnings` are advisory
(e.g. breach check unavailable — password accepted but flagged).

**`BreachDetector`** — checks whether a password appears in known breach
databases.

```java
public interface BreachDetector {
    boolean isBreached(String password);
}
```

Returns `true` if the password is found in a breach database. Implementations
handle their own error recovery — the SPI contract says nothing about
failure behaviour; that responsibility belongs to the `PasswordPolicy` that
composes the detector.

### Implementation (registration-core)

**`DefaultPasswordPolicy`** — constructor-injected with nullable
`BreachDetector`.

Local rules:
- Minimum length: 8 characters
- Maximum length: 128 characters (prevents Argon2 DoS with very long inputs)
- Character class diversity: at least 2 of {lowercase, uppercase, digit,
  special character} — pragmatic bar that blocks trivially weak passwords
  without imposing annoying complexity mandates

Breach detection:
- If `BreachDetector` is non-null, calls `isBreached(password)`
- If breach detected: adds violation "Password found in known data breach"
- If `isBreached` throws (network error, timeout): adds warning
  "Breach detection unavailable" — password is **not** rejected (D3: fail-open)

All violations are collected before returning (no short-circuit), so the user
sees every problem at once.

**`HaveIBeenPwnedBreachDetector`** — k-anonymity API via
`java.net.http.HttpClient`.

Algorithm:
1. SHA-1 hash the password (required by HIBP API — not used for storage)
2. Send the first 5 characters of the hex-encoded hash to
   `GET https://api.pwnedpasswords.com/range/{prefix}`
3. Response is a list of hash suffixes with occurrence counts
4. Check if our suffix appears in the response

Properties:
- 3-second timeout (connect + read)
- No retry — single attempt, fail-open on any error
- The full password hash never leaves the process; only a 5-char prefix
  is transmitted (k-anonymity)

**`NoOpBreachDetector`** — always returns `false`. `@DefaultBean` in Quarkus,
`@ConditionalOnMissingBean` in Spring. Allows deployments without external
API access to still use `DefaultPasswordPolicy` with local rules only.
`HaveIBeenPwnedBreachDetector` displaces this when on the classpath with
appropriate configuration.

### Integration Points

`PasswordPolicy.validate()` is called in two places:
1. `RegistrationServiceCore.registerWithPassword()` — before hashing
2. `RegistrationServiceCore.resetPassword()` — before updating credential

On invalid result, both throw `PasswordPolicyViolationException` (new,
in `registration-api`) containing the violation list.

## 2. Password Reset Flow

### SPIs (registration-api)

**`PasswordResetToken`** — mirrors `EmailVerificationToken`.

```java
public record PasswordResetToken(
    String tokenHash,
    String userId,
    String tenancyId,
    Instant expiresAt,
    Instant createdAt
)
```

**`PasswordResetStore`** — mirrors `EmailVerificationStore`.

```java
public interface PasswordResetStore {
    void store(PasswordResetToken token);
    Optional<PasswordResetToken> consume(String rawToken);
}
```

`consume` atomically retrieves by hashing the raw token, removes it
(single-use), and returns empty if not found or expired.

### CDI Events (registration-api)

```java
public record PasswordResetRequested(String userId, String tenancyId, Instant requestedAt)
    implements SubscribableEvent { ... }

public record PasswordResetCompleted(String userId, String tenancyId, Instant completedAt)
    implements SubscribableEvent { ... }
```

Follow the existing `UserRegistered`/`UserActivated` pattern.

### Service Methods (RegistrationService SPI + RegistrationServiceCore)

**`requestPasswordReset(String email, String tenancyId)`**

1. Look up user by email + tenancy via `UserStore.findByEmail()`
2. If not found: return silently (no user enumeration — same pattern as
   timing-equalized login)
3. If found but status not ACTIVE: return silently
4. Generate reset token via `TokenGenerator.generate()`
5. Hash via `TokenGenerator.sha256Hex(rawToken)`
6. Store `PasswordResetToken` with 1-hour TTL
7. Send raw token via `EmailSender` with reset-specific template
8. Fire `PasswordResetRequested` event
9. Return success (caller cannot distinguish found vs not-found)

**`resetPassword(String rawToken, String newPassword, String tenancyId)`**

1. Consume token via `PasswordResetStore.consume(rawToken)`
2. If empty: throw `InvalidTokenException`
3. Validate `tenancyId` matches token's tenancyId
4. Validate new password via `PasswordPolicy.validate(newPassword)`
5. If invalid: throw with violations (token is already consumed — user
   must request a new one, preventing brute-force policy bypass)
6. Hash new password via `PasswordHasher.hash(newPassword)`
7. Update credential via `PasswordCredentialStore.updatePassword()`
8. Fire `PasswordResetCompleted` event
9. Return success

### Endpoints

Added to existing `RegistrationEndpoint` (`@McpDomain("registration")`):

- `requestPasswordReset(email, tenancyId)` — `@PlatformMutation`
- `resetPassword(token, newPassword, tenancyId)` — `@PlatformMutation`

REST endpoints generated by `graphql-generator` APT. No authentication
required (unauthenticated users need to reset passwords).

## 3. Persistence

### In-Memory (user-inmem-core)

`InMemoryPasswordResetStore` — `ConcurrentHashMap<String, PasswordResetToken>`
keyed by tokenHash. Same pattern as `InMemoryEmailVerificationStore`.

### JPA (user-jpa-common + user-jpa)

`PasswordResetTokenEntity` — JPA entity in `user-jpa-common`. Table
`registration_password_reset_token`. Columns: `token_hash` (PK),
`user_id`, `tenancy_id`, `expires_at`, `created_at`.

Flyway migration `V9004__registration_password_reset_token.sql` in
`user-jpa-common/src/main/resources/db/registration/migration/`.

`JpaPasswordResetStore` — `@ApplicationScoped` in `user-jpa`.

### Spring JPA (user-spring-jpa)

`SpringPasswordResetStore` + `PasswordResetTokenEntityRepository` in
`user-spring-jpa`. Same pattern as `SpringEmailVerificationStore`.

### CDI/Spring Wiring

**Quarkus:** `RegistrationBeans` produces `DefaultPasswordPolicy`,
`NoOpBreachDetector` (`@DefaultBean`). `UserInmemBeans` produces
`InMemoryPasswordResetStore`.

**Spring:** `RegistrationSpringAutoConfiguration` produces
`DefaultPasswordPolicy`, `NoOpBreachDetector`
(`@ConditionalOnMissingBean`). JPA store via auto-configuration in
`user-spring-jpa`.

`HaveIBeenPwnedBreachDetector` is produced conditionally — only when
`casehub.registration.breach-detection.enabled=true` (default: false).
When produced, it displaces `NoOpBreachDetector` via `@Alternative
@Priority(1)` (Quarkus) or `@ConditionalOnProperty` (Spring).

## 4. Testing

### Unit Tests (registration-core)

- `DefaultPasswordPolicyTest` — local rules: too short, too long,
  insufficient diversity, valid passwords, edge cases (exactly 8 chars,
  exactly 128 chars)
- `DefaultPasswordPolicyTest` — breach integration: breached password
  rejected, clean password passes, detector throws → warning not violation
- `HaveIBeenPwnedBreachDetectorTest` — mock HTTP responses: breached hash
  suffix found, not found, timeout, server error
- `RegistrationServiceCoreTest` — extended: registerWithPassword now
  validates policy (reject weak password, accept strong)
- `RegistrationServiceCoreTest` — new: requestPasswordReset (happy path,
  unknown email returns silently, inactive user returns silently),
  resetPassword (happy path, invalid token, expired token, policy
  violation on new password)

### In-Memory Store Tests (user-inmem-core)

- `InMemoryPasswordResetStoreTest` — store/consume, expired returns
  empty, consume removes token (single-use), unknown token returns empty

### Integration Tests

JPA and Spring JPA stores tested via existing test infrastructure patterns.

## 5. Module Impact Summary

| Module | Changes |
|--------|---------|
| `registration-api` | +`PasswordPolicy`, `PasswordPolicyResult`, `BreachDetector`, `PasswordResetToken`, `PasswordResetStore`, `PasswordResetRequested`, `PasswordResetCompleted`, `PasswordPolicyViolationException`. Extend `RegistrationService` +2 methods |
| `registration-core` | +`DefaultPasswordPolicy`, `HaveIBeenPwnedBreachDetector`, `NoOpBreachDetector`. Extend `RegistrationServiceCore` +2 methods + policy validation in registerWithPassword |
| `registration` | Extend `RegistrationBeans` (produce policy + breach beans). Extend `RegistrationEndpoint` +2 operations |
| `registration-spring` | Extend auto-config (produce policy + breach beans) |
| `user-inmem-core` | +`InMemoryPasswordResetStore` |
| `user-inmem` | Extend `UserInmemBeans` (produce reset store) |
| `user-jpa-common` | +`PasswordResetTokenEntity`, +Flyway V9004 |
| `user-jpa` | +`JpaPasswordResetStore` |
| `user-spring-jpa` | +`SpringPasswordResetStore`, +`PasswordResetTokenEntityRepository` |
| `docs/guides/consumer-guide.md` | Document password policy and reset flow |

## References

- `registration-api/.../PasswordHasher.java` — SPI pattern precedent
- `registration-api/.../EmailVerificationToken.java` — token record pattern
- `registration-api/.../EmailVerificationStore.java` — store SPI pattern
- `registration-core/.../RegistrationServiceCore.java` — service composition pattern
- `registration-core/.../TokenGenerator.java` — token generation utility
- `registration-core/.../PasswordAuthenticationProviderCore.java` — timing equalization pattern
- `registration-core/.../Argon2PasswordHasher.java` — hashing implementation
- `user-inmem-core/.../InMemoryEmailVerificationStore.java` — in-memory store pattern
- `user-jpa-common/.../EmailVerificationEntity.java` — JPA entity pattern
- HaveIBeenPwned API (range endpoint, k-anonymity) — breach detection
- casehubio/platform#532 — issue
- casehubio/platform#531 — prior work (registration infrastructure)
