# User Registration / Self-Signup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** #531 — User registration / self-signup authentication flow
**Issue group:** #531

**Goal:** Enable self-signup through social login, email/password, and admin
invitations with configurable tenant registration policies, introducing a local
UserStore SPI for self-managed user identities.

**Architecture:** Stateless registration ceremony with separate RegistrationService
SPI alongside the existing AuthenticationProvider. New `registration-api` module
holds all SPIs (following the `agent-api` pattern). `registration-core` contains
framework-neutral logic. Social login integration via new `UserProvisioner` SPI
called from `AbstractOAuthAuthenticationProvider` when `UserResolver` returns empty.
Argon2id for password hashing.

**Tech Stack:** Java 21, Quarkus, Spring Boot 4, argon2-jvm (de.mkammerer),
Hibernate ORM, Flyway, Maven

## Global Constraints

- `registration-api/` must remain zero-dependency — pure Java only
- `registration-core/` depends only on registration-api + platform-api + argon2-jvm
- All new modules: `<proc>none</proc>` in pom.xml — no annotation processing
- No `quarkus:build` goal on any new module
- Follow `-core` / Quarkus / Spring / `-inmem` / `-jpa` module pattern
- Flyway migrations in V9000-V9999 range, location `classpath:db/registration/migration`
- Tokens (invitation, email verification) stored as SHA-256 hashes; raw never persisted
- Every commit references #531

---

## Batch 1: Foundation — SPIs, Types, and In-Memory Stores

After this batch: all types, SPIs, and in-memory implementations exist. Core logic can
be built on top.

### Task 1: registration-api module — SPIs and types

**Files:**
- Create: `registration-api/pom.xml`
- Create: `registration-api/src/main/java/io/casehub/platform/registration/UserStore.java`
- Create: `registration-api/src/main/java/io/casehub/platform/registration/UserRecord.java`
- Create: `registration-api/src/main/java/io/casehub/platform/registration/UserStatus.java`
- Create: `registration-api/src/main/java/io/casehub/platform/registration/PasswordCredentialStore.java`
- Create: `registration-api/src/main/java/io/casehub/platform/registration/PasswordCredential.java`
- Create: `registration-api/src/main/java/io/casehub/platform/registration/InvitationStore.java`
- Create: `registration-api/src/main/java/io/casehub/platform/registration/InvitationRecord.java`
- Create: `registration-api/src/main/java/io/casehub/platform/registration/EmailVerificationStore.java`
- Create: `registration-api/src/main/java/io/casehub/platform/registration/EmailVerificationToken.java`
- Create: `registration-api/src/main/java/io/casehub/platform/registration/RegistrationService.java`
- Create: `registration-api/src/main/java/io/casehub/platform/registration/RegistrationResult.java`
- Create: `registration-api/src/main/java/io/casehub/platform/registration/RegistrationPolicy.java`
- Create: `registration-api/src/main/java/io/casehub/platform/registration/RegistrationMode.java`
- Create: `registration-api/src/main/java/io/casehub/platform/registration/UserProvisioner.java`
- Create: `registration-api/src/main/java/io/casehub/platform/registration/EmailSender.java`
- Create: `registration-api/src/main/java/io/casehub/platform/registration/PasswordHasher.java`
- Create: `registration-api/src/main/java/io/casehub/platform/registration/PasswordRegistrationRequest.java`
- Create: `registration-api/src/main/java/io/casehub/platform/registration/InvitationRequest.java`
- Create: `registration-api/src/main/java/io/casehub/platform/registration/InvitationCreationResult.java`
- Create: `registration-api/src/main/java/io/casehub/platform/registration/UserRegistered.java`
- Create: `registration-api/src/main/java/io/casehub/platform/registration/UserActivated.java`
- Create: `registration-api/src/main/java/io/casehub/platform/registration/RegistrationApproved.java`
- Create: `registration-api/src/main/java/io/casehub/platform/registration/RegistrationRejected.java`
- Create: `registration-api/src/main/java/io/casehub/platform/registration/InvitationCreated.java`
- Modify: `pom.xml` (root) — add `<module>registration-api</module>`
- Test: `registration-api/src/test/java/io/casehub/platform/registration/UserRecordTest.java`
- Test: `registration-api/src/test/java/io/casehub/platform/registration/UserStatusTest.java`
- Test: `registration-api/src/test/java/io/casehub/platform/registration/PasswordRegistrationRequestTest.java`

**Interfaces:**
- Produces: All SPIs and types consumed by every subsequent task. See spec
  §SPI Definitions for exact signatures.

- [ ] **Step 1: Create pom.xml** — `jar` packaging, parent `casehub-parent`,
  artifactId `casehub-platform-registration-api`. Zero dependencies.
  `<proc>none</proc>`. Copy structure from `yaml-plugin-api/pom.xml`.

- [ ] **Step 2: Write record/enum types** — `UserRecord`, `UserStatus`,
  `PasswordCredential`, `InvitationRecord`, `EmailVerificationToken`,
  `RegistrationMode`, `PasswordRegistrationRequest`, `InvitationRequest`,
  `InvitationCreationResult`. All records with null-checks per spec.

- [ ] **Step 3: Write SPI interfaces** — `UserStore`, `PasswordCredentialStore`,
  `InvitationStore`, `EmailVerificationStore`, `RegistrationService`,
  `RegistrationPolicy`, `UserProvisioner`, `EmailSender`, `PasswordHasher`.
  Copy exact signatures from spec §SPI Definitions.

- [ ] **Step 4: Write sealed RegistrationResult** — 7 record variants per spec.

- [ ] **Step 5: Write CDI event records** — `UserRegistered`, `UserActivated`,
  `RegistrationApproved`, `RegistrationRejected`, `InvitationCreated`. Each
  implements `SubscribableEvent` with `type()` returning the event type string
  per spec. All events also implement `tenancyId()` (required by `SubscribableEvent`).

- [ ] **Step 6: Write tests** — `UserRecordTest` (null-check enforcement, canonical
  construction), `UserStatusTest` (all 5 values exist), `PasswordRegistrationRequestTest`
  (null-checks, toString excludes password).

- [ ] **Step 7: Add module to root pom and build** —
  `mvn --batch-mode -pl registration-api install -DskipTests=false`

- [ ] **Step 8: Commit**
  `git add registration-api/ pom.xml && git commit -m "feat(registration-api): SPI types and interfaces for user registration Refs #531"`

### Task 2: platform-api + platform/ additions

**Files:**
- Create: `platform-api/src/main/java/io/casehub/platform/api/authn/RegistrationEventListener.java`
- Create: `platform-api/src/main/java/io/casehub/platform/api/authn/AccountNotActiveException.java`
- Create: `platform-api/src/main/java/io/casehub/platform/api/authn/UserStatusResolver.java`
- Create: `platform/src/main/java/io/casehub/platform/authn/NoOpRegistrationEventListener.java`
- Create: `platform/src/main/java/io/casehub/platform/authn/NoOpUserProvisioner.java`
- Create: `platform/src/main/java/io/casehub/platform/authn/NoOpUserStatusResolver.java`
- Create: `platform/src/main/java/io/casehub/platform/registration/PreferenceRegistrationPolicy.java`
- Modify: `platform/pom.xml` — add `registration-api` dependency (compile scope)
- Test: `platform-api/src/test/java/io/casehub/platform/api/authn/AccountNotActiveExceptionTest.java`
- Test: `platform/src/test/java/io/casehub/platform/registration/PreferenceRegistrationPolicyTest.java`

**Interfaces:**
- Consumes: `UserProvisioner` (from Task 1), `PreferenceProvider` (existing)
- Produces: `RegistrationEventListener`, `AccountNotActiveException`,
  `UserStatusResolver`, all NoOp defaults

- [ ] **Step 1: Write RegistrationEventListener** — 5 default no-op methods per spec
  §RegistrationEventListener. Lives in `platform-api` so `registration-core` can
  call it without CDI.

- [ ] **Step 2: Write AccountNotActiveException** — extends `AuthenticationException`,
  has `statusName()` accessor per spec.

- [ ] **Step 3: Write UserStatusResolver** — single method
  `Optional<String> resolveStatus(String actorId, String tenancyId)` per spec.

- [ ] **Step 4: Write NoOp defaults** — `NoOpRegistrationEventListener @DefaultBean`
  (silent no-op), `NoOpUserProvisioner @DefaultBean` (returns `Optional.empty()`),
  `NoOpUserStatusResolver @DefaultBean` (returns `Optional.empty()`).

- [ ] **Step 5: Write PreferenceRegistrationPolicy** — `@DefaultBean`, reads
  `casehub.registration.mode` from `PreferenceProvider`, defaults to `OPEN`.

- [ ] **Step 6: Add registration-api dependency to platform/pom.xml**

- [ ] **Step 7: Write tests** — `AccountNotActiveExceptionTest` (message format,
  statusName accessor), `PreferenceRegistrationPolicyTest` (default OPEN, reads
  from preferences).

- [ ] **Step 8: Build both modules** —
  `mvn --batch-mode -pl platform-api,platform install -DskipTests=false`

- [ ] **Step 9: Commit**
  `git commit -m "feat(platform-api): RegistrationEventListener, AccountNotActiveException, UserStatusResolver Refs #531"`

### Task 3: user-inmem-core — in-memory store implementations

**Files:**
- Create: `user-inmem-core/pom.xml`
- Create: `user-inmem-core/src/main/java/io/casehub/platform/registration/inmem/InMemoryUserStore.java`
- Create: `user-inmem-core/src/main/java/io/casehub/platform/registration/inmem/InMemoryPasswordCredentialStore.java`
- Create: `user-inmem-core/src/main/java/io/casehub/platform/registration/inmem/InMemoryInvitationStore.java`
- Create: `user-inmem-core/src/main/java/io/casehub/platform/registration/inmem/InMemoryEmailVerificationStore.java`
- Modify: `pom.xml` (root) — add `<module>user-inmem-core</module>`
- Test: `user-inmem-core/src/test/java/io/casehub/platform/registration/inmem/InMemoryUserStoreTest.java`
- Test: `user-inmem-core/src/test/java/io/casehub/platform/registration/inmem/InMemoryPasswordCredentialStoreTest.java`
- Test: `user-inmem-core/src/test/java/io/casehub/platform/registration/inmem/InMemoryInvitationStoreTest.java`
- Test: `user-inmem-core/src/test/java/io/casehub/platform/registration/inmem/InMemoryEmailVerificationStoreTest.java`

**Interfaces:**
- Consumes: All store SPIs from Task 1
- Produces: In-memory implementations used by registration-core tests (Task 4-6)

- [ ] **Step 1: Create pom.xml** — depends on `registration-api` (compile).

- [ ] **Step 2: Write InMemoryUserStore** — `ConcurrentHashMap<String, UserRecord>`
  keyed by `id`. `findByEmail` scans values. `updateStatus` replaces record with
  new status + activatedAt if transitioning to ACTIVE.

- [ ] **Step 3: Write test for InMemoryUserStore** — create, findById, findByEmail,
  updateStatus transitions, delete, unique email per tenancy enforcement.

- [ ] **Step 4: Write InMemoryPasswordCredentialStore** — `ConcurrentHashMap` keyed
  by `actorId + "|" + tenancyId`.

- [ ] **Step 5: Write test** — store, find, updatePassword, updateLastUsed, delete.

- [ ] **Step 6: Write InMemoryInvitationStore** — keyed by `id`. `findByTokenHash`
  scans values. `consume` marks consumed. Store implementations hash incoming
  raw tokens using SHA-256.

- [ ] **Step 7: Write test** — store, findByTokenHash, findByEmail, consume
  (idempotent), findByTenancy, delete.

- [ ] **Step 8: Write InMemoryEmailVerificationStore** — keyed by `tokenHash`.
  `consume` removes and returns. Callers pass raw tokens; store hashes before lookup.

- [ ] **Step 9: Write test** — store, consume (single-use), consume expired → empty.

- [ ] **Step 10: Build** — `mvn --batch-mode -pl user-inmem-core install -DskipTests=false`

- [ ] **Step 11: Commit**
  `git commit -m "feat(user-inmem-core): in-memory store implementations for registration Refs #531"`

---

## Batch 2: Core Logic — Registration Ceremony and Password Auth

After this batch: all ceremony flows (email/password registration, email verification,
invitation, approval/rejection) work against in-memory stores. Password authentication
works. All tested.

### Task 4: registration-core — Argon2 hasher + RegistrationServiceCore

**Files:**
- Create: `registration-core/pom.xml`
- Create: `registration-core/src/main/java/io/casehub/platform/registration/core/Argon2PasswordHasher.java`
- Create: `registration-core/src/main/java/io/casehub/platform/registration/core/RegistrationServiceCore.java`
- Create: `registration-core/src/main/java/io/casehub/platform/registration/core/TokenGenerator.java`
- Modify: `pom.xml` (root) — add `<module>registration-core</module>`
- Test: `registration-core/src/test/java/io/casehub/platform/registration/core/Argon2PasswordHasherTest.java`
- Test: `registration-core/src/test/java/io/casehub/platform/registration/core/RegistrationServiceCoreTest.java`

**Interfaces:**
- Consumes: `UserStore`, `PasswordCredentialStore`, `InvitationStore`,
  `EmailVerificationStore`, `RegistrationPolicy`, `EmailSender`,
  `RegistrationEventListener`, `PasswordHasher` (all from Tasks 1-2),
  in-memory implementations (Task 3)
- Produces: `Argon2PasswordHasher implements PasswordHasher`,
  `RegistrationServiceCore implements RegistrationService`,
  `TokenGenerator` (32-byte SecureRandom, base64url)

- [ ] **Step 1: Create pom.xml** — depends on `registration-api`, `platform-api`,
  `argon2-jvm` (de.mkammerer:argon2-jvm:2.11). Test scope: `user-inmem-core`.

- [ ] **Step 2: Write TokenGenerator** — static `generate()` returns 32-byte
  SecureRandom base64url-encoded string. Static `sha256Hex(String raw)` returns
  hex-encoded SHA-256 hash.

- [ ] **Step 3: Write Argon2PasswordHasher** — implements `PasswordHasher`.
  Constructor takes memory (64 MiB), iterations (3), parallelism (1). Uses
  `Argon2Factory.create(Argon2Factory.Argon2Types.ARGON2id)`.

- [ ] **Step 4: Write Argon2PasswordHasherTest** — hash returns non-null,
  verify correct password → true, verify wrong password → false, hash is
  non-deterministic (two hashes of same input differ).

- [ ] **Step 5: Write RegistrationServiceCore** — constructor-injected dependencies.
  Implements all 6 methods per spec:
  - `registerWithPassword`: policy check → duplicate check (treat REJECTED as
    non-existent, delete old record) → create UserRecord (PENDING_VERIFICATION) →
    hash password → store credential → generate verification token → store token →
    send email → fire event → return PendingVerification
  - `verifyEmail`: consume token → check expiry → update status (ACTIVE if OPEN,
    PENDING_APPROVAL if APPROVAL_REQUIRED) → fire event → return result
  - `approveRegistration`: findById → check PENDING_APPROVAL → update ACTIVE →
    fire RegistrationApproved → return Activated
  - `rejectRegistration`: findById → check PENDING_APPROVAL → update REJECTED →
    fire RegistrationRejected → return Rejected
  - `createInvitation`: generate token → create record (with tokenHash) →
    fire InvitationCreated → return InvitationCreationResult (rawToken + record)
  - `revokeInvitation`: delete by id

- [ ] **Step 6: Write RegistrationServiceCoreTest** — test each flow:
  - `registerWithPassword_openPolicy_createsPendingVerification`
  - `registerWithPassword_invitationOnly_returnsPolicyDenied`
  - `registerWithPassword_duplicateEmail_returnsAlreadyExists`
  - `registerWithPassword_rejectedUser_deletesAndReRegisters`
  - `registerWithPassword_withInvitation_bypassesApproval`
  - `verifyEmail_openPolicy_activatesUser`
  - `verifyEmail_approvalRequired_movesToPendingApproval`
  - `verifyEmail_expiredToken_returnsError`
  - `approveRegistration_pendingApproval_activates`
  - `rejectRegistration_pendingApproval_rejects`
  - `createInvitation_generatesTokenAndRecord`
  - `revokeInvitation_deletesRecord`

- [ ] **Step 7: Run tests** — `mvn --batch-mode -pl registration-core test`

- [ ] **Step 8: Commit**
  `git commit -m "feat(registration-core): RegistrationServiceCore with Argon2id password hashing Refs #531"`

### Task 5: registration-core — UserStoreProvisioner + UserStoreUserResolver + UserStoreUserStatusResolver

**Files:**
- Create: `registration-core/src/main/java/io/casehub/platform/registration/core/UserStoreProvisioner.java`
- Create: `registration-core/src/main/java/io/casehub/platform/registration/core/UserStoreUserResolver.java`
- Create: `registration-core/src/main/java/io/casehub/platform/registration/core/UserStoreUserStatusResolver.java`
- Test: `registration-core/src/test/java/io/casehub/platform/registration/core/UserStoreProvisionerTest.java`
- Test: `registration-core/src/test/java/io/casehub/platform/registration/core/UserStoreUserResolverTest.java`

**Interfaces:**
- Consumes: `UserProvisioner`, `UserStore`, `RegistrationPolicy`,
  `RegistrationEventListener` (Tasks 1-2), `UserResolver` (platform-api),
  `UserStatusResolver` (Task 2)
- Produces: `UserStoreProvisioner implements UserProvisioner`,
  `UserStoreUserResolver implements UserResolver`,
  `UserStoreUserStatusResolver implements UserStatusResolver`

- [ ] **Step 1: Write UserStoreProvisioner** — per spec §UserProvisioner:
  check policy → check no existing non-REJECTED user → check emailVerified →
  delete REJECTED if found → create UserRecord → fire event → return PrincipalId.

- [ ] **Step 2: Write UserStoreProvisionerTest** —
  - `provision_openPolicy_verifiedEmail_createsActiveUser`
  - `provision_approvalRequired_createsPendingApprovalUser`
  - `provision_invitationOnly_returnsEmpty`
  - `provision_existingUser_returnsEmpty` (account-takeover mitigation)
  - `provision_rejectedUser_deletesAndReCreates`
  - `provision_unverifiedEmail_returnsEmpty`

- [ ] **Step 3: Write UserStoreUserResolver** — implements `UserResolver`.
  `resolveByEmail` queries `UserStore.findByEmail`, returns PrincipalId for
  ACTIVE/PENDING_VERIFICATION/PENDING_APPROVAL users, empty for REJECTED/SUSPENDED.

- [ ] **Step 4: Write UserStoreUserResolverTest** —
  - `resolve_activeUser_returnsPrincipalId`
  - `resolve_pendingUser_returnsPrincipalId`
  - `resolve_rejectedUser_returnsEmpty`
  - `resolve_suspendedUser_returnsEmpty`
  - `resolve_noUser_returnsEmpty`

- [ ] **Step 5: Write UserStoreUserStatusResolver** — implements `UserStatusResolver`.
  Queries `UserStore.findById`, returns `user.status().name()`.

- [ ] **Step 6: Run tests** — `mvn --batch-mode -pl registration-core test`

- [ ] **Step 7: Commit**
  `git commit -m "feat(registration-core): UserStoreProvisioner, UserResolver, UserStatusResolver Refs #531"`

### Task 6: registration-core — PasswordAuthenticationProviderCore

**Files:**
- Create: `registration-core/src/main/java/io/casehub/platform/registration/core/PasswordAuthenticationProviderCore.java`
- Test: `registration-core/src/test/java/io/casehub/platform/registration/core/PasswordAuthenticationProviderCoreTest.java`

**Interfaces:**
- Consumes: `PasswordCredentialStore`, `UserStore`, `PasswordHasher` (Task 1),
  `AuthenticationProvider`, `AuthenticationResult`, `AccountNotActiveException` (Task 2)
- Produces: `PasswordAuthenticationProviderCore implements AuthenticationProvider`
  (method = "password")

- [ ] **Step 1: Write PasswordAuthenticationProviderCore** — per spec
  §PasswordAuthenticationProvider. `initiate()` returns no-op challenge.
  `verify()` looks up user by email, checks ACTIVE status, verifies password
  hash, includes `userStatus` in metadata. Timing equalization: dummy hash
  when user not found.

- [ ] **Step 2: Write PasswordAuthenticationProviderCoreTest** —
  - `verify_validCredentials_returnsResult`
  - `verify_invalidPassword_throwsInvalidCredential`
  - `verify_unknownEmail_throwsInvalidCredential` (timing equalization)
  - `verify_pendingVerification_throwsAccountNotActive`
  - `verify_suspended_throwsAccountNotActive`
  - `verify_noPasswordCredential_throwsInvalidCredential`

- [ ] **Step 3: Run tests** — `mvn --batch-mode -pl registration-core test`

- [ ] **Step 4: Commit**
  `git commit -m "feat(registration-core): PasswordAuthenticationProviderCore Refs #531"`

---

## Batch 3: Social Login Integration

After this batch: social login triggers user provisioning when no existing identity
is found. `OAuthIdentity` carries `emailVerified`. `SocialLoginCompleted` event
includes `emailVerified`. The pending-verification reconciliation flow works.

### Task 7: authn-social-core changes — UserProvisioner integration

**Files:**
- Modify: `authn-social-core/src/main/java/io/casehub/platform/authn/social/OAuthIdentity.java`
- Modify: `authn-social-core/src/main/java/io/casehub/platform/authn/social/AbstractOAuthAuthenticationProvider.java`
- Modify: `authn-social-core/src/main/java/io/casehub/platform/authn/social/GoogleAuthenticationProvider.java`
- Modify: `authn-social-core/src/main/java/io/casehub/platform/authn/social/GitHubAuthenticationProvider.java`
- Modify: `authn-social-core/src/main/java/io/casehub/platform/authn/social/AppleAuthenticationProvider.java`
- Modify: `platform-api/src/main/java/io/casehub/platform/api/authn/SocialLoginCompleted.java`
- Modify: `authn-social-core/pom.xml` — add `registration-api` dependency (compile)
- Modify: `authn/src/main/java/io/casehub/platform/authn/quarkus/AuthnBeans.java`
- Test: `authn-social-core/src/test/java/io/casehub/platform/authn/social/AbstractOAuthAuthenticationProviderTest.java`

**Interfaces:**
- Consumes: `UserProvisioner` (Task 1), `UserStatusResolver` (Task 2)
- Produces: Modified `AbstractOAuthAuthenticationProvider` that calls
  `UserProvisioner.provisionFromSocialLogin()` when `UserResolver` returns empty

- [ ] **Step 1: Add emailVerified to OAuthIdentity** — new boolean field per spec
  §Cross-Module Changes. All construction sites must be updated.

- [ ] **Step 2: Add emailVerified to SocialLoginCompleted** — new boolean field
  per spec. Update all construction sites (in `AbstractOAuthAuthenticationProvider.verify()`).

- [ ] **Step 3: Modify AbstractOAuthAuthenticationProvider constructor** — add
  `UserProvisioner` and `UserStatusResolver` parameters. Store as fields.

- [ ] **Step 4: Modify resolveOrCreateActorId** — per spec §Social Login Integration:
  try `UserResolver.resolveByEmail()` first, then `UserProvisioner.provisionFromSocialLogin()`
  if empty, then throw `UnknownIdentityException` if both empty.

- [ ] **Step 5: Modify verify()** — after resolveOrCreateActorId, call
  `userStatusResolver.resolveStatus()` and include in metadata map as `"userStatus"`.
  Pass `identity.emailVerified()` to `SocialLoginCompleted`.

- [ ] **Step 6: Update GoogleAuthenticationProvider.extractIdentity()** — extract
  `email_verified` from ID token claims. Google guarantees this claim.

- [ ] **Step 7: Update GitHubAuthenticationProvider.extractIdentity()** — call
  GitHub `/user/emails` API, check primary email's `verified` flag.

- [ ] **Step 8: Update AppleAuthenticationProvider.extractIdentity()** — extract
  `email_verified` from ID token. Apple guarantees this for relay emails.

- [ ] **Step 9: Update AuthnBeans** — pass `UserProvisioner` and `UserStatusResolver`
  (CDI Instance) to provider constructors.

- [ ] **Step 10: Write/update tests** — test `resolveOrCreateActorId` with:
  - UserResolver finds user → returns existing actorId (no provisioning)
  - UserResolver empty + provisioner succeeds → returns new actorId
  - UserResolver empty + provisioner empty → throws UnknownIdentityException
  - verify() includes userStatus in metadata when resolver returns status

- [ ] **Step 11: Build authn modules** —
  `mvn --batch-mode -pl authn-social-core,authn,platform-api install -DskipTests=false`

- [ ] **Step 12: Commit**
  `git commit -m "feat(authn-social-core): integrate UserProvisioner for social login registration Refs #531"`

---

## Batch 4: Persistence and Quarkus Wiring

After this batch: full Quarkus deployment works with JPA persistence, REST endpoints,
and CDI event bridge. The `PasswordAuthenticationProvider` is wired into the authn
provider list.

### Task 8: user-jpa-common + user-jpa — JPA persistence

**Files:**
- Create: `user-jpa-common/pom.xml`
- Create: `user-jpa-common/src/main/java/io/casehub/platform/registration/jpa/UserEntity.java`
- Create: `user-jpa-common/src/main/java/io/casehub/platform/registration/jpa/PasswordCredentialEntity.java`
- Create: `user-jpa-common/src/main/java/io/casehub/platform/registration/jpa/InvitationEntity.java`
- Create: `user-jpa-common/src/main/java/io/casehub/platform/registration/jpa/EmailVerificationEntity.java`
- Create: `user-jpa-common/src/main/resources/db/registration/migration/V9000__registration_user.sql`
- Create: `user-jpa-common/src/main/resources/db/registration/migration/V9001__registration_password_credential.sql`
- Create: `user-jpa-common/src/main/resources/db/registration/migration/V9002__registration_invitation.sql`
- Create: `user-jpa-common/src/main/resources/db/registration/migration/V9003__registration_email_verification.sql`
- Create: `user-jpa/pom.xml`
- Create: `user-jpa/src/main/java/io/casehub/platform/registration/jpa/JpaUserStore.java`
- Create: `user-jpa/src/main/java/io/casehub/platform/registration/jpa/JpaPasswordCredentialStore.java`
- Create: `user-jpa/src/main/java/io/casehub/platform/registration/jpa/JpaInvitationStore.java`
- Create: `user-jpa/src/main/java/io/casehub/platform/registration/jpa/JpaEmailVerificationStore.java`
- Modify: `pom.xml` (root) — add both modules

**Interfaces:**
- Consumes: All store SPIs from Task 1
- Produces: JPA entities + `@ApplicationScoped` store implementations

- [ ] **Step 1: Create user-jpa-common pom.xml** — depends on `registration-api`,
  `jakarta.persistence-api`, `jakarta.annotation-api`.

- [ ] **Step 2: Write JPA entities** — `UserEntity` (`@Table("registration_user")`),
  `PasswordCredentialEntity`, `InvitationEntity` (JSON column for `assigned_groups`),
  `EmailVerificationEntity`. Follow existing entity patterns (e.g., `SessionEntity`
  in `session-jpa-common`).

- [ ] **Step 3: Write Flyway migrations** — V9000-V9003 per spec §Flyway Migrations.

- [ ] **Step 4: Create user-jpa pom.xml** — depends on `user-jpa-common`,
  `registration-api`, `quarkus-hibernate-orm`. Blocking-only.

- [ ] **Step 5: Write JPA store implementations** — `@ApplicationScoped`, `@Transactional`
  on mutations. `JpaUserStore` uses Hibernate `EntityManager`. Follow `persistence-jpa`
  module patterns. Token hashing (SHA-256) in invitation and verification stores.

- [ ] **Step 6: Build** — `mvn --batch-mode -pl user-jpa-common,user-jpa install -DskipTests`

- [ ] **Step 7: Commit**
  `git commit -m "feat(user-jpa): JPA entities and store implementations for registration Refs #531"`

### Task 9: registration/ + user-inmem/ — Quarkus CDI wiring + REST

**Files:**
- Create: `registration/pom.xml`
- Create: `registration/src/main/java/io/casehub/platform/registration/quarkus/RegistrationBeans.java`
- Create: `registration/src/main/java/io/casehub/platform/registration/quarkus/RegistrationCdiEventBridge.java`
- Create: `registration/src/main/java/io/casehub/platform/registration/quarkus/RegistrationEndpoint.java`
- Create: `registration/src/main/java/io/casehub/platform/registration/quarkus/InvitationEndpoint.java`
- Create: `user-inmem/pom.xml`
- Create: `user-inmem/src/main/java/io/casehub/platform/registration/inmem/quarkus/UserInmemBeans.java`
- Modify: `pom.xml` (root) — add both modules

**Interfaces:**
- Consumes: All core implementations from Tasks 4-6, in-memory stores from Task 3
- Produces: CDI wiring, REST endpoints, CDI event bridge

- [ ] **Step 1: Create user-inmem pom.xml** — depends on `user-inmem-core`,
  `registration-api`. CDI wiring only.

- [ ] **Step 2: Write UserInmemBeans** — `@Produces @Alternative @Priority(100)` for
  each in-memory store implementation.

- [ ] **Step 3: Create registration/ pom.xml** — depends on `registration-core`,
  `registration-api`, `platform-api`, Quarkus core. Test scope: `user-inmem`.

- [ ] **Step 4: Write RegistrationCdiEventBridge** — `@ApplicationScoped implements
  RegistrationEventListener`. Each method fires the corresponding CDI event via
  `Event<T>.fire()`. Follows the `AuthenticationEventListener` bridge pattern.

- [ ] **Step 5: Write RegistrationBeans** — `@Produces` for RegistrationServiceCore,
  UserStoreProvisioner, UserStoreUserResolver, UserStoreUserStatusResolver,
  PasswordAuthenticationProviderCore, Argon2PasswordHasher, TokenGenerator.
  `@DefaultBean` for `EmailSender` (no-op). Produces `PasswordAuthenticationProviderCore`
  and adds to the authn provider list.

- [ ] **Step 6: Write RegistrationEndpoint** — `@McpDomain("registration")` with
  `@PlatformMutation` / `@PlatformQuery` annotations. Delegates to `RegistrationService`.
  Approve/reject: `@RolesAllowed(PlatformRoles.ADMIN)`.

- [ ] **Step 7: Write InvitationEndpoint** — `@McpDomain("invitations")` with
  `@PlatformMutation` / `@PlatformQuery` annotations. All methods:
  `@RolesAllowed(PlatformRoles.ADMIN)`.

- [ ] **Step 8: Build** — `mvn --batch-mode -pl user-inmem,registration install -DskipTests`

- [ ] **Step 9: Commit**
  `git commit -m "feat(registration): Quarkus CDI wiring, REST endpoints, CDI event bridge Refs #531"`

---

## Batch 5: Spring + Documentation

After this batch: full dual-framework deployment, documentation updated, CLAUDE.md
module table current.

### Task 10: Spring modules — registration-spring + user-spring-jpa

**Files:**
- Create: `registration-spring/pom.xml`
- Create: `registration-spring/src/main/java/io/casehub/platform/registration/spring/RegistrationSpringAutoConfiguration.java`
- Create: `user-spring-jpa/pom.xml`
- Create: `user-spring-jpa/src/main/java/io/casehub/platform/registration/spring/jpa/SpringUserStore.java`
- Create: `user-spring-jpa/src/main/java/io/casehub/platform/registration/spring/jpa/SpringPasswordCredentialStore.java`
- Create: `user-spring-jpa/src/main/java/io/casehub/platform/registration/spring/jpa/SpringInvitationStore.java`
- Create: `user-spring-jpa/src/main/java/io/casehub/platform/registration/spring/jpa/SpringEmailVerificationStore.java`
- Modify: `pom.xml` (root) — add both modules
- Modify: `spring-boot-starter/pom.xml` — optional dep on registration-spring

**Interfaces:**
- Consumes: registration-core, user-jpa-common (shared entities)
- Produces: Spring auto-configuration + Spring Data JPA stores

- [ ] **Step 1: Create user-spring-jpa pom.xml** — depends on `user-jpa-common`,
  `registration-api`, Spring Data JPA.

- [ ] **Step 2: Write Spring Data JPA stores** — Spring Repository interfaces +
  store implementations delegating to repositories. Follow `persistence-spring-jpa`
  patterns. `@AutoConfiguration @ConditionalOnMissingBean`.

- [ ] **Step 3: Create registration-spring pom.xml** — depends on `registration-core`.

- [ ] **Step 4: Write RegistrationSpringAutoConfiguration** — `@AutoConfiguration`
  with `@Bean @ConditionalOnMissingBean` for all core beans. Spring event bridge
  (uses `ApplicationEventPublisher`).

- [ ] **Step 5: Update spring-boot-starter** — optional dependency on
  registration-spring.

- [ ] **Step 6: Build** — `mvn --batch-mode -pl user-spring-jpa,registration-spring install -DskipTests`

- [ ] **Step 7: Commit**
  `git commit -m "feat(registration-spring): Spring Boot auto-configuration for registration Refs #531"`

### Task 11: Documentation

**Files:**
- Modify: `CLAUDE.md` — add module table entries for all 9 new modules
- Modify: `docs/guides/consumer-guide.md` — add "User Registration" section

**Interfaces:**
- Consumes: all modules from Tasks 1-10
- Produces: updated documentation

- [ ] **Step 1: Add module entries to CLAUDE.md** — 9 entries following existing
  format: registration-api, registration-core, registration, registration-spring,
  user-inmem-core, user-inmem, user-jpa-common, user-jpa, user-spring-jpa.

- [ ] **Step 2: Add "User Registration" section to consumer guide** — three
  registration paths, tenant policy configuration, invitation API, registration
  events, code examples.

- [ ] **Step 3: Full build** — `mvn --batch-mode install`

- [ ] **Step 4: Commit**
  `git commit -m "docs: add registration module documentation Refs #531"`

---

## References

- [2026-10-31-user-registration-self-signup-design.md] — design spec this plan implements
- [decisions.md] — 12 architectural decisions (D1-D12, D10+D12 revised per review)
- [platform-api/.../authn/AuthenticationProvider.java] — existing AuthenticationProvider SPI
- [platform-api/.../authn/UserResolver.java] — existing UserResolver SPI (read-only)
- [authn-social-core/.../AbstractOAuthAuthenticationProvider.java] — social login flow, integration point
- [authn-social-core/.../OAuthIdentity.java] — gains emailVerified field
- [platform-api/.../authn/SocialLoginCompleted.java] — gains emailVerified field
- [authn/.../AuthnBeans.java] — Quarkus CDI wiring for auth providers
- [agent-api/pom.xml] — module structure precedent for registration-api
- [memory-inmem/] — module structure precedent for user-inmem
- [GitHub #531] — focal issue
- [GitHub #525] — parent epic
- [GitHub #532] — password authentication for existing users (future)
