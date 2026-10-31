# User Registration / Self-Signup Authentication Flow — Design Spec

**Issue:** casehubio/platform#531
**Date:** 2026-10-31
**Status:** Draft
**Epic:** #525 (Identity Authentication)

## Relationship to Epic #525

This issue explicitly revises epic #525's Decision D11 ("Pre-existing SCIM identity
required"). D11 stated: "Keeps platform as infrastructure, not a user registration
system." This issue introduces a second user identity model — self-managed users via
`UserStore` — alongside the existing directory-managed model (SCIM). The two are
mutually exclusive per deployment, selected by classpath presence. SCIM remains
read-only; UserStore handles self-signup.

## Problem

The authentication subsystem (epic #525, Decision D11) requires pre-existing SCIM
identity — users must exist in the SCIM directory before they can authenticate via
WebAuthn or social login. There is no path from "unknown person" to "authenticated
user with a platform identity."

The current social login fallback (`AbstractOAuthAuthenticationProvider.resolveOrCreateActorId()`)
silently uses the raw OAuth `externalId` as the `actorId` when no SCIM identity
exists. This creates an identity binding without a proper user record — no groups,
no lifecycle status, no admin visibility.

## Goals

1. Enable self-signup through social login (Google/GitHub/Apple), email/password, and
   admin-initiated invitations
2. Introduce a `UserStore` SPI for local user identity management, keeping SCIM
   read-only for directory-managed deployments
3. Support configurable tenant registration policies (auto-approve, require approval,
   invitation-only)
4. Email verification for email/password signups; trust social provider's
   `email_verified` claim
5. Implement the email/password `AuthenticationProvider` (password hashing, credential
   storage) — the signup path for #531, with #532 covering subsequent password logins

## Scope Exclusions

| Concern | Rationale | Tracked As |
|---------|-----------|------------|
| MFA / step-up authentication | Requires AuthenticationResult evolution | #533 |
| Password reset / forgot-password | Post-signup lifecycle concern | New issue |
| User profile management | UserRecord is minimal identity, not a profile | New issue |
| SCIM write-back | UserStore and SCIM are independent stores | New issue |
| Account deletion / GDPR right-to-erasure | Separate lifecycle concern | New issue |

## Architecture Overview

Registration is a **stateless ceremony** — a short-lived interaction that creates
a user identity, mirrors the `AuthenticationProvider` challenge-response pattern but
serves a different purpose (identity creation vs identity proof).

```
┌──────────────┐     ┌──────────────────┐     ┌──────────────┐
│  Entry Paths │     │ RegistrationSvc  │     │  UserStore   │
├──────────────┤     ├──────────────────┤     ├──────────────┤
│ Social login ├────►│ Policy check     ├────►│ UserRecord   │
│ Email/pass   │     │ Email verify     │     │ (CRUD)       │
│ Invitation   │     │ Create user      │     └──────────────┘
└──────────────┘     │ Apply groups     │     ┌──────────────┐
                     │ Fire events      │     │ Password     │
                     └──────────────────┘     │ Credential   │
                                              │ Store        │
                                              └──────────────┘
                                              ┌──────────────┐
                                              │ Invitation   │
                                              │ Store        │
                                              └──────────────┘
```

### Three Entry Paths

**Social login:** User clicks "Sign in with Google" on a tenant's signup page.
The existing `AbstractOAuthAuthenticationProvider` flow calls `UserResolver.resolveByEmail()`.
When no user is found, a new `UserProvisioner` SPI is called from
`resolveOrCreateActorId()`. `UserResolver` stays read-only (CQS-compliant).
`UserProvisioner` checks the tenant registration policy, validates the provider's
`email_verified` claim, creates a `UserRecord` in `UserStore`, and returns the new
`PrincipalId`. **Account-takeover mitigation:** `UserProvisioner` only creates NEW
users. If an existing user with that email already exists (registered via a different
method), it returns empty — the user must log in with their existing method and
explicitly link the social identity from settings.

**Email/password:** User submits email + password on a signup form. The
`RegistrationService.registerWithPassword()` method creates a `UserRecord` in
`PENDING_VERIFICATION` status, stores a hashed password in `PasswordCredentialStore`,
and sends an email verification token. On verification, the user transitions to
`ACTIVE` (or `PENDING_APPROVAL` if tenant requires approval).

**Invitation:** Admin creates an invitation via `InvitationService.create()`. The
invited user receives a link with a token, which pre-fills the signup form with
tenant and email. On registration (social or email/password), the invitation's
pre-assigned groups are applied and the invitation is consumed.

## SPI Definitions

### UserStore — `io.casehub.platform.registration`

```java
public interface UserStore {
    UserRecord create(UserRecord user);
    Optional<UserRecord> findById(String id, String tenancyId);
    Optional<UserRecord> findByEmail(String email, String tenancyId);
    UserRecord updateStatus(String id, String tenancyId, UserStatus newStatus);
    void delete(String id, String tenancyId);
}
```

### UserRecord

```java
public record UserRecord(
    String id,
    String email,
    String displayName,
    String tenancyId,
    UserStatus status,
    String registrationMethod,   // "google", "github", "apple", "password", "invitation"
    Instant createdAt,
    Instant activatedAt
) {
    public UserRecord {
        Objects.requireNonNull(id, "id");
        Objects.requireNonNull(email, "email");
        Objects.requireNonNull(tenancyId, "tenancyId");
        Objects.requireNonNull(status, "status");
        Objects.requireNonNull(registrationMethod, "registrationMethod");
    }
}
```

### UserStatus

```java
public enum UserStatus {
    PENDING_VERIFICATION,  // email not yet verified (email/password path)
    PENDING_APPROVAL,      // verified but awaiting admin approval
    ACTIVE,                // fully active
    REJECTED,              // admin rejected registration
    SUSPENDED              // admin-suspended (was active)
}
```

State transitions:
```
PENDING_VERIFICATION → PENDING_APPROVAL  (email verified, approval required)
PENDING_VERIFICATION → ACTIVE            (email verified, auto-approve)
PENDING_VERIFICATION → REJECTED          (verification expired, admin cleanup)
PENDING_APPROVAL     → ACTIVE            (admin approved)
PENDING_APPROVAL     → REJECTED          (admin rejected)
ACTIVE               → SUSPENDED         (admin suspended)
SUSPENDED            → ACTIVE            (admin reinstated)
```

`REJECTED` is a terminal state — rejected users must re-register. Verification
tokens expire after 24 hours; users in `PENDING_VERIFICATION` past expiry can be
cleaned up by a scheduled retention purge.

### PasswordCredentialStore — `io.casehub.platform.registration`

```java
public interface PasswordCredentialStore {
    void store(PasswordCredential credential);
    Optional<PasswordCredential> findByActorId(String actorId, String tenancyId);
    void updatePassword(String actorId, String tenancyId, String hashedPassword);
    void delete(String actorId, String tenancyId);
}
```

### PasswordCredential

```java
public record PasswordCredential(
    String actorId,
    String tenancyId,
    String hashedPassword,  // bcrypt hash
    Instant createdAt,
    Instant lastUsedAt
) {}
```

### InvitationStore — `io.casehub.platform.registration`

```java
public interface InvitationStore {
    InvitationRecord store(InvitationRecord invitation);
    Optional<InvitationRecord> findByToken(String token);
    Optional<InvitationRecord> findByEmail(String email, String tenancyId);
    void consume(String token);
    List<InvitationRecord> findByTenancy(String tenancyId);
    void delete(String token);
}
```

### InvitationRecord

```java
public record InvitationRecord(
    String token,
    String email,
    String tenancyId,
    Set<String> assignedGroups,
    Instant expiresAt,
    String createdBy,
    Instant createdAt,
    boolean consumed
) {
    public boolean isExpired() {
        return expiresAt != null && expiresAt.isBefore(Instant.now());
    }
}
```

### EmailVerificationStore — `io.casehub.platform.registration`

```java
public interface EmailVerificationStore {
    void store(EmailVerificationToken token);
    Optional<EmailVerificationToken> consume(String token);
}

public record EmailVerificationToken(
    String token,
    String userId,
    String tenancyId,
    Instant expiresAt,
    Instant createdAt
) {}
```

### UserProvisioner — `io.casehub.platform.registration`

Called by `AbstractOAuthAuthenticationProvider.resolveOrCreateActorId()` when
`UserResolver` returns empty. `UserResolver` remains read-only (CQS-compliant).

```java
public interface UserProvisioner {
    Optional<PrincipalId> provisionFromSocialLogin(
        String email, String tenancyId, String provider, boolean emailVerified);
}
```

The default implementation (`UserStoreProvisioner`) in `registration-core`:
1. Checks `RegistrationPolicy.getMode(tenancyId)` — returns empty if `INVITATION_ONLY`
2. Checks `UserStore.findByEmail(email, tenancyId)` — returns empty if user already
   exists (account-takeover mitigation: never auto-link to existing accounts)
3. If `emailVerified` is false, returns empty (unverified social emails cannot
   auto-register)
4. Creates `UserRecord` with status `ACTIVE` (if `OPEN`) or `PENDING_APPROVAL`
5. Fires `UserRegistered` CDI event
6. Returns `PrincipalId.human(user.id())`

`NoOpUserProvisioner @DefaultBean` returns `Optional.empty()` — social login falls
back to the existing `externalId` behavior when registration module is not on
classpath.

### EmailSender — `io.casehub.platform.registration`

```java
public interface EmailSender {
    void send(String to, String subject, String body);
}
```

No-op default. Deployers provide an implementation backed by SMTP (Jakarta Mail),
a notification delivery channel, or any external email service. The registration
module never depends on `casehub-connectors` — email delivery is pluggable via SPI.

### RegistrationPolicy — `io.casehub.platform.registration`

```java
public interface RegistrationPolicy {
    RegistrationMode getMode(String tenancyId);
}

public enum RegistrationMode {
    OPEN,             // auto-approve after verification
    APPROVAL_REQUIRED, // admin must approve
    INVITATION_ONLY   // no self-signup, invitations only
}
```

Default implementation reads from `PreferenceProvider` using a new preference key
`casehub.registration.mode` (default: `OPEN`).

### RegistrationService — `io.casehub.platform.registration`

```java
public interface RegistrationService {

    RegistrationResult registerWithPassword(PasswordRegistrationRequest request);

    RegistrationResult verifyEmail(String token);

    RegistrationResult approveRegistration(String userId, String tenancyId);

    RegistrationResult rejectRegistration(String userId, String tenancyId, String reason);

    InvitationRecord createInvitation(InvitationRequest request);

    void revokeInvitation(String token);
}
```

### RegistrationResult

```java
public sealed interface RegistrationResult {
    record Created(UserRecord user) implements RegistrationResult {}
    record PendingVerification(String userId, String email) implements RegistrationResult {}
    record PendingApproval(String userId) implements RegistrationResult {}
    record Activated(UserRecord user) implements RegistrationResult {}
    record Rejected(String userId, String reason) implements RegistrationResult {}
    record AlreadyExists(String email) implements RegistrationResult {}
    record PolicyDenied(RegistrationMode mode) implements RegistrationResult {}
}
```

### CDI Events — `io.casehub.platform.registration`

```java
public record UserRegistered(String userId, String tenancyId,
                              String email, String registrationMethod) {}

public record UserActivated(String userId, String tenancyId,
                             String email) {}

public record RegistrationApproved(String userId, String tenancyId,
                                    String approvedBy) {}

public record RegistrationRejected(String userId, String tenancyId,
                                    String reason, String rejectedBy) {}

public record InvitationCreated(String token, String email,
                                 String tenancyId, String createdBy) {}
```

These events integrate with the existing notification/subscription pipeline:
`UserRegistered` can trigger admin notifications when approval is required;
`UserActivated` can trigger welcome notifications to the user.

## Registration Ceremony Flows

### Email/Password Registration

```
Client                    RegistrationService             Stores
  │                              │                          │
  │ POST /register/password      │                          │
  │  {email, password,           │                          │
  │   displayName, tenancyId}    │                          │
  ├─────────────────────────────►│                          │
  │                              │ check RegistrationPolicy │
  │                              │  → OPEN or APPROVAL_REQ  │
  │                              │ check UserStore.findByEmail │
  │                              │  → must not exist         │
  │                              │ create UserRecord         │
  │                              │  status=PENDING_VERIF.   │
  │                              ├─────────────────────────►│
  │                              │ hash password (Argon2id)  │
  │                              │ store PasswordCredential │
  │                              ├─────────────────────────►│
  │                              │ create verification token │
  │                              │ store EmailVerifToken    │
  │                              ├─────────────────────────►│
  │                              │ fire UserRegistered      │
  │  PendingVerification         │                          │
  │◄─────────────────────────────┤                          │
  │                              │                          │
  │ GET /register/verify?token=  │                          │
  ├─────────────────────────────►│                          │
  │                              │ consume token            │
  │                              │ if OPEN: status→ACTIVE   │
  │                              │ if APPROVAL: status→     │
  │                              │   PENDING_APPROVAL       │
  │                              │ fire UserActivated or    │
  │                              │   RegistrationPending    │
  │  Activated or PendingApproval│                          │
  │◄─────────────────────────────┤                          │
```

### Social Login Registration (via UserProvisioner)

```
Client          AuthenticationRouter    AbstractOAuth...    UserProvisioner
  │                    │                      │                     │
  │ POST /auth/initiate│                      │                     │
  │  {method:"google"} │                      │                     │
  ├───────────────────►│                      │                     │
  │                    │ initiate(ctx)        │                     │
  │                    ├─────────────────────►│                     │
  │  OAuth redirect    │                      │                     │
  │◄───────────────────┤                      │                     │
  │                    │                      │                     │
  │ POST /auth/verify  │                      │                     │
  │  {code, state}     │                      │                     │
  ├───────────────────►│                      │                     │
  │                    │ verify(challenge,data)│                     │
  │                    ├─────────────────────►│                     │
  │                    │                      │ resolveOrCreateActorId │
  │                    │                      │ 1. resolveByEmail    │
  │                    │                      │    → empty           │
  │                    │                      │ 2. provisionFromSocial│
  │                    │                      ├────────────────────►│
  │                    │                      │                     │ check policy → OPEN
  │                    │                      │                     │ check no existing user
  │                    │                      │                     │ check email_verified
  │                    │                      │                     │ create UserRecord
  │                    │                      │                     │  status=ACTIVE
  │                    │                      │                     │ fire UserRegistered
  │                    │                      │  PrincipalId        │
  │                    │                      │◄────────────────────┤
  │                    │  AuthenticationResult│                     │
  │                    │◄─────────────────────┤                     │
  │  session/JWT       │                      │                     │
  │◄───────────────────┤                      │                     │
```

### Invitation Flow

```
Admin                   InvitationService          InvitationStore
  │                            │                        │
  │ POST /register/invitations │                        │
  │  {email, tenancyId,        │                        │
  │   assignedGroups}          │                        │
  ├───────────────────────────►│                        │
  │                            │ generate token         │
  │                            │ store InvitationRecord │
  │                            ├───────────────────────►│
  │                            │ fire InvitationCreated │
  │  InvitationRecord          │                        │
  │◄───────────────────────────┤                        │
  │                            │                        │
  │  (email sent to invitee    │                        │
  │   with link: /signup/      │                        │
  │   {tenancyId}?invite=token)│                        │

Invitee                 RegistrationService         Stores
  │                            │                      │
  │ (clicks invite link)       │                      │
  │ POST /register/password    │                      │
  │  {email, password,         │                      │
  │   invitationToken}         │                      │
  ├───────────────────────────►│                      │
  │                            │ validate invitation   │
  │                            │  (token, email match) │
  │                            │ create UserRecord     │
  │                            │  status=ACTIVE        │
  │                            │  (invitation bypasses │
  │                            │   approval)           │
  │                            │ apply assignedGroups  │
  │                            │ consume invitation    │
  │  Activated(user)           │                      │
  │◄───────────────────────────┤                      │
```

## Module Structure

Following the platform's `-core` / Quarkus / `-spring` / `-inmem` / `-jpa` pattern:

| Module | Artifact | Purpose |
|--------|----------|---------|
| `registration-api/` | `casehub-platform-registration-api` | Pure Java SPIs — UserStore, UserRecord, UserStatus, PasswordCredentialStore, InvitationStore, EmailVerificationStore, RegistrationService, RegistrationPolicy, UserProvisioner, EmailSender, CDI events. Zero deps (follows `agent-api` pattern — SPIs not in `platform-api` because only the registration modules consume them). |
| `registration-core/` | `casehub-platform-registration-core` | Framework-neutral RegistrationServiceCore, UserStoreProvisioner, PasswordAuthenticationProviderCore, EmailVerificationServiceCore, InvitationServiceCore, Argon2PasswordHasher. Depends on registration-api + argon2-jvm. Pure Java — no CDI, no Spring. |
| `registration/` | `casehub-platform-registration` | Quarkus CDI wiring — RegistrationBeans (`@Produces` all core beans), REST endpoints via `@McpDomain("registration")` on RegistrationService + `@McpDomain("invitations")` on InvitationService. `NoOp` defaults for all SPIs. |
| `registration-spring/` | `casehub-platform-registration-spring` | Spring Boot auto-configuration — generated from Quarkus `@Produces` via spring-generator. |
| `user-inmem-core/` | `casehub-platform-user-inmem-core` | Framework-neutral InMemoryUserStore + InMemoryPasswordCredentialStore + InMemoryInvitationStore + InMemoryEmailVerificationStore. ConcurrentHashMap. |
| `user-inmem/` | `casehub-platform-user-inmem` | Quarkus CDI wiring — `@Produces @Alternative @Priority(100)`. Test scope. |
| `user-jpa-common/` | `casehub-platform-user-jpa-common` | JPA entities — UserEntity, PasswordCredentialEntity, InvitationEntity, EmailVerificationEntity. Flyway migrations. Framework-neutral. |
| `user-jpa/` | `casehub-platform-user-jpa` | Quarkus `@ApplicationScoped` JPA stores. Hibernate ORM, `@Transactional`. |
| `user-spring-jpa/` | `casehub-platform-user-spring-jpa` | Spring Data JPA stores — shares entities via user-jpa-common. |

### registration-api contents

New package `io.casehub.platform.registration`:
- `UserStore`, `UserRecord`, `UserStatus`
- `PasswordCredentialStore`, `PasswordCredential`
- `InvitationStore`, `InvitationRecord`
- `EmailVerificationStore`, `EmailVerificationToken`
- `RegistrationService`, `RegistrationResult` (sealed)
- `RegistrationPolicy`, `RegistrationMode`
- `UserProvisioner`
- `EmailSender`
- `PasswordRegistrationRequest`
- CDI events: `UserRegistered`, `UserActivated`, `RegistrationApproved`,
  `RegistrationRejected`, `InvitationCreated`

### platform/ additions

- `NoOpUserProvisioner @DefaultBean` — returns `Optional.empty()` (social login
  falls back to `externalId` behavior when registration module absent)
- `PreferenceRegistrationPolicy @DefaultBean` — reads `casehub.registration.mode`
  from PreferenceProvider (default: `OPEN`)

### Relationship to StaticCredentialStore

`StaticCredentialStore` (in platform-api) stores API keys, bot tokens, and PATs —
opaque tokens compared by equality. `PasswordCredentialStore` stores hashed
credentials verified by a one-way hash function. The semantics are fundamentally
different (stored-and-compared vs hashed-and-verified), following the precedent set
by `WebAuthnCredentialStore` which also has its own dedicated store.

## PasswordAuthenticationProvider

New `AuthenticationProvider` implementation for email/password login. Lives in
`registration-core/`, wired by `registration/` (Quarkus) and `registration-spring/`
(Spring).

```java
public class PasswordAuthenticationProviderCore implements AuthenticationProvider {
    private final PasswordCredentialStore credentialStore;
    private final UserStore userStore;
    private final PasswordHasher passwordHasher;

    @Override
    public String method() { return "password"; }

    @Override
    public ChallengeResponse initiate(AuthenticationContext context) {
        // No challenge needed for password auth — return a no-op challenge
        // that simply indicates readiness to accept credentials
    }

    @Override
    public AuthenticationResult verify(ChallengeRecord challenge, Map<String, Object> data) {
        String email = (String) data.get("email");
        String password = (String) data.get("password");

        var user = userStore.findByEmail(email, challenge.tenancyId())
            .orElseThrow(() -> new UnknownIdentityException("password", "Unknown email"));

        if (user.status() != UserStatus.ACTIVE) {
            throw new AccountLockedException("password",
                "Account is " + user.status().name().toLowerCase());
        }

        var credential = credentialStore.findByActorId(user.id(), challenge.tenancyId())
            .orElseThrow(() -> new InvalidCredentialException("password", "No password set"));

        if (!passwordHasher.verify(password, credential.hashedPassword())) {
            throw new InvalidCredentialException("password", "Invalid password");
        }

        credentialStore.updateLastUsed(user.id(), challenge.tenancyId());

        return new AuthenticationResult(
            PrincipalId.human(user.id()),
            challenge.tenancyId(),
            Set.of(),
            "password",
            Map.of());
    }
}
```

### PasswordHasher

```java
public interface PasswordHasher {
    String hash(String plaintext);
    boolean verify(String plaintext, String hashed);
}
```

`Argon2PasswordHasher` implements this using `argon2-jvm` with configurable
parameters (memory: 64 MiB, iterations: 3, parallelism: 1). These match OWASP's
Argon2id recommended minimums for interactive logins.

## Social Login Integration

The existing `AbstractOAuthAuthenticationProvider.resolveOrCreateActorId()` is
modified to call `UserProvisioner` when `UserResolver` returns empty. `UserResolver`
remains read-only — it resolves existing users only. `UserProvisioner` handles
identity creation.

```java
// Modified resolveOrCreateActorId in AbstractOAuthAuthenticationProvider
private String resolveOrCreateActorId(OAuthIdentity identity, String tenancyId) {
    if (identity.email() != null) {
        var resolved = userResolver.resolveByEmail(identity.email(), tenancyId);
        if (resolved.isPresent()) {
            return resolved.get().id();
        }
    }
    // NEW: delegate to UserProvisioner instead of falling back to externalId
    if (identity.email() != null) {
        var provisioned = userProvisioner.provisionFromSocialLogin(
            identity.email(), tenancyId, method(), identity.emailVerified());
        if (provisioned.isPresent()) {
            return provisioned.get().id();
        }
    }
    return identity.externalId(); // final fallback (backward-compatible)
}
```

`OAuthIdentity` gains an `emailVerified()` accessor — each provider extracts
this from the ID token (`email_verified` claim for Google/Apple) or user-info
response. GitHub has no `email_verified` equivalent for all emails, so
`GitHubAuthenticationProvider` passes `false` for non-primary emails.

When the tenant policy is `APPROVAL_REQUIRED`, the provisioner creates the user in
`PENDING_APPROVAL` status. The social login flow completes and the user receives a
session/JWT. The JWT includes the user's status in its claims (`ust` claim).
Application-layer access control checks `UserStatus` before granting access to
protected resources — a `PENDING_APPROVAL` user can see a "waiting for approval"
page but cannot access tenant data. This mirrors how `AccountLockedException`
already gates access for suspended accounts. The `RegistrationApproved` event
triggers a notification to the user, who can then refresh their session to get an
updated JWT with `ACTIVE` status.

### Account-Takeover Mitigation

`UserStoreProvisioner` never auto-links a social login to an existing account.
If `UserStore.findByEmail(email, tenancyId)` returns a user, provisioning returns
`Optional.empty()`. The user must log in with their existing method and explicitly
link the social identity from account settings (a future issue). This prevents the
attack where an attacker creates a Google account with a victim's email and gains
access to the victim's existing email/password account.

### Tenant Enumeration Mitigation

Registration endpoints return identical responses regardless of whether the
`tenancyId` in the URL resolves to a real tenant. A request to `/signup/nonexistent`
returns the same form/response as `/signup/real-tenant`. Policy enforcement happens
server-side during the registration ceremony, not at the URL routing layer.

## REST API Surface

All endpoints generated by `graphql-generator` APT from `@McpDomain` annotations on
the SPI interfaces.

| Method | Path | Purpose | Auth |
|--------|------|---------|------|
| POST | `/register/password` | Email/password signup | No |
| GET | `/register/verify` | Email verification callback | No |
| POST | `/register/invitations` | Create invitation | Admin |
| DELETE | `/register/invitations/{token}` | Revoke invitation | Admin |
| GET | `/register/invitations` | List tenant invitations | Admin |
| POST | `/register/approve/{userId}` | Approve pending registration | Admin |
| POST | `/register/reject/{userId}` | Reject pending registration | Admin |
| GET | `/register/policy/{tenancyId}` | Get registration policy | No |

## Flyway Migrations

Namespace: `V9000` — registration schema.

```sql
-- V9000__registration_user.sql
CREATE TABLE registration_user (
    id            VARCHAR(255) NOT NULL,
    email         VARCHAR(255) NOT NULL,
    display_name  VARCHAR(255),
    tenancy_id    VARCHAR(255) NOT NULL,
    status        VARCHAR(50)  NOT NULL,
    registration_method VARCHAR(50) NOT NULL,
    created_at    TIMESTAMP    NOT NULL,
    activated_at  TIMESTAMP,
    PRIMARY KEY (id),
    UNIQUE (email, tenancy_id)
);

-- V9001__registration_password_credential.sql
CREATE TABLE registration_password_credential (
    actor_id      VARCHAR(255) NOT NULL,
    tenancy_id    VARCHAR(255) NOT NULL,
    hashed_password VARCHAR(255) NOT NULL,
    created_at    TIMESTAMP    NOT NULL,
    last_used_at  TIMESTAMP,
    PRIMARY KEY (actor_id, tenancy_id)
);

-- V9002__registration_invitation.sql
CREATE TABLE registration_invitation (
    token         VARCHAR(255) NOT NULL,
    email         VARCHAR(255) NOT NULL,
    tenancy_id    VARCHAR(255) NOT NULL,
    assigned_groups TEXT,          -- JSON array
    expires_at    TIMESTAMP,
    created_by    VARCHAR(255) NOT NULL,
    created_at    TIMESTAMP    NOT NULL,
    consumed      BOOLEAN      NOT NULL DEFAULT FALSE,
    PRIMARY KEY (token)
);

-- V9003__registration_email_verification.sql
CREATE TABLE registration_email_verification (
    token         VARCHAR(255) NOT NULL,
    user_id       VARCHAR(255) NOT NULL,
    tenancy_id    VARCHAR(255) NOT NULL,
    expires_at    TIMESTAMP    NOT NULL,
    created_at    TIMESTAMP    NOT NULL,
    PRIMARY KEY (token)
);
```

## Security Considerations

- **Password storage:** Argon2id via `argon2-jvm` (Apache 2.0, wraps libsodium).
  OWASP's primary recommendation for new systems. Parameters: memory 64 MiB,
  iterations 3, parallelism 1 (configurable via `casehub.registration.argon2.*`).
  Passwords never stored or logged in plaintext.
- **Email verification tokens:** Cryptographically random (SecureRandom), 32 bytes,
  base64url-encoded. Single-use (consumed on verification). Default TTL: 24 hours.
- **Invitation tokens:** Same generation as verification tokens. Single-use. Bound to
  specific email — invitation link only works for the invited email address.
- **Timing attacks:** `PasswordHasher.verify()` uses bcrypt's constant-time comparison.
  Login for non-existent emails performs a dummy bcrypt hash to prevent timing
  side-channels.
- **Rate limiting:** Registration endpoints should be rate-limited per IP/tenant.
  Not implemented in this issue — deferred to the existing `agent-gate` or a
  future HTTP rate-limiting module.
- **Enumeration protection:** `POST /register/password` returns the same response
  whether the email already exists or is newly registered (prevents email
  enumeration). The `AlreadyExists` result is only visible server-side.

## Notification Integration

Registration events integrate with the existing subscription/notification pipeline:

- `UserRegistered` with `status=PENDING_APPROVAL` → admin notification via
  `SubscriptionEngine` (subscribable: `registration.user.pending`)
- `UserActivated` → welcome notification to the user
- `RegistrationRejected` → rejection notice to the user
- `InvitationCreated` → email delivery to invitee (via `NotificationDispatcher`)

Events implement `SubscribableEvent` so tenants can create custom subscriptions
for registration events.

## Testing Strategy

- **Unit tests (registration-core):**
  - `RegistrationServiceCoreTest` — all ceremony flows (email/password, invitation,
    approval, rejection, policy checks)
  - `UserStoreUserResolverTest` — resolution + auto-creation + policy enforcement
  - `PasswordAuthenticationProviderCoreTest` — login with valid/invalid credentials,
    locked accounts, missing credentials
  - `Argon2PasswordHasherTest` — hash + verify roundtrip, cost factor
  - `EmailVerificationServiceCoreTest` — token generation, consumption, expiry

- **Integration tests (user-jpa):**
  - JPA store tests with `@QuarkusTest` + `@TestTransaction`
  - Unique constraint enforcement (email + tenancy)
  - Concurrent registration (same email) → exactly one succeeds

- **In-memory tests (user-inmem-core):**
  - All store contracts verified with in-memory implementations
  - Used by registration-core tests for isolation

## Documentation Updates

### Consumer guide (`docs/guides/consumer-guide.md`)

New section "User Registration" covering:
- Three registration paths and when to use each
- Tenant registration policy configuration
- Invitation API
- How to listen for registration events

### CLAUDE.md module table

New entries for all 8 modules.

## References

- casehubio/platform#531 — this issue
- casehubio/platform#525 — parent epic (Identity Authentication)
- Epic #525 spec: `docs/specs/epic-525-identity-auth/2026-10-06-identity-authentication-design.md`
  — Decision D11 (pre-existing SCIM identity), authentication flows, SPI definitions
- Issue #271 spec: `specs/issue-271-principal-identity-model/2026-09-03-principal-identity-model-design.md`
  — PrincipalId identity types
- `platform-api/src/main/java/io/casehub/platform/api/authn/` — existing authn SPIs
- `authn-social-core/src/main/java/.../AbstractOAuthAuthenticationProvider.java` —
  social login flow, `resolveOrCreateActorId()` integration point
- `authn-webauthn-core/src/main/java/.../WebAuthnAuthenticationProvider.java` —
  WebAuthn registration requires `existingPrincipal`
- `platform/src/main/java/.../authn/NoOpUserResolver.java` — current no-op that
  silently falls through
- OWASP Password Storage Cheat Sheet — bcrypt recommendation
- casehubio/platform#532 — password authentication for existing users (future)
- casehubio/platform#533 — MFA / step-up authentication (future)
