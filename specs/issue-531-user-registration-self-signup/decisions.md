# Decisions — Issue #531: User Registration / Self-Signup

## D1: Registration entry paths

**Choice:** Social login + email/password + admin invitations
**Alternatives:**
- Social + email invite — covers most cases but no email/password signup form
- Social only — simplest but no email-based signup
- Invitation-only — most controlled but no organic growth
**Rationale:** Full spectrum gives deployers maximum flexibility. Consumer apps need self-signup; enterprise needs invitations. All three paths share the same registration infrastructure.
**Trade-offs:** Larger implementation surface (three entry paths vs one)
**Sources:** platform-api AuthenticationProvider SPI, epic #525 scope exclusions
**Exploration:** quick
**Status:** captured

## D2: Tenant assignment during signup

**Choice:** Tenant in signup URL (`/signup/{tenancyId}`)
**Alternatives:**
- User chooses tenant — requires pending identity state with no tenant, complex lifecycle
- One tenant per deployment — too restrictive for multi-tenant deployments
- Domain-based auto-assignment — works for enterprise but not consumer apps
**Rationale:** Keeps the existing `AuthenticationContext` model intact where `tenancyId` is required upfront. Each tenant controls its own signup surface.
**Trade-offs:** Users must reach the correct tenant-specific URL (not a problem in practice — tenant controls their branding/domain)
**Sources:** platform-api AuthenticationContext.java (tenancyId required field)
**Exploration:** quick
**Status:** captured

## D3: Approval policy

**Choice:** Configurable per tenant (auto-approve / require-approval / invitation-only)
**Alternatives:**
- Always auto-approve — simplest but no control for enterprise
- Always require approval — safe but friction for consumer apps
**Rationale:** Different deployments have different trust models. Stored as a tenant preference via the existing PreferenceProvider infrastructure.
**Trade-offs:** Approval workflow needs an admin surface (approve/reject API)
**Sources:** platform-api PreferenceProvider SPI, PreferenceKey
**Exploration:** quick
**Status:** captured

## D4: User record storage

**Choice:** New local UserStore SPI in platform-api
**Alternatives:**
- Writable SCIM client — enterprise SCIM directories often restrict writes
- Dual local + SCIM sync — two sources of truth with reconciliation complexity
**Rationale:** Clean separation: UserStore owns self-managed users, SCIM stays read-only for directory-managed deployments. Deployers choose one model.
**Trade-offs:** Two user storage models to understand (UserStore vs SCIM)
**Sources:** scim-core ScimClient (read-only), platform-api UserResolver SPI
**Exploration:** quick
**Status:** captured

## D5: Email verification

**Choice:** Required for email/password; trust social provider's `email_verified` claim
**Alternatives:**
- Always required — adds friction to social login which users expect to be instant
- Never required — allows registration with unverified/fake emails
**Rationale:** Social providers (Google) already verify emails. Trusting their claim avoids redundant verification. Email/password has no external verifier so platform must verify.
**Trade-offs:** GitHub doesn't guarantee email_verified for all emails — those are treated as unverified
**Sources:** OAuth2/OIDC `email_verified` claim semantics
**Exploration:** quick
**Status:** captured

## D6: Scope boundary with #532

**Choice:** Include email/password authentication provider in this issue
**Alternatives:**
- Defer entirely to #532 — email/password signup can't work until #532 lands
**Rationale:** The password provider IS the registration form handler — they're tightly coupled. #531 = create account + first credential, #532 = subsequent password-based logins for existing users.
**Trade-offs:** Larger scope for #531
**Depends on:** D1 (email/password is one of the entry paths)
**Sources:** casehubio/platform#532 (password authentication)
**Exploration:** quick
**Status:** captured

## D7: SPI integration approach

**Choice:** Separate RegistrationService SPI alongside AuthenticationProvider
**Alternatives:**
- Extend AuthenticationProvider — mixes authentication and identity creation concerns
- Registration as AuthenticationProvider — stretches SPI semantics
**Rationale:** Registration is a distinct ceremony from authentication (different inputs, outputs, lifecycle). Clean separation: RegistrationService creates identity, AuthenticationProvider proves identity.
**Trade-offs:** New SPI to learn and implement
**Depends on:** D1 (entry paths determine what RegistrationService must support)
**Sources:** platform-api AuthenticationProvider.java, AuthenticationResult.java
**Exploration:** quick
**Status:** captured

## D8: Overall architecture

**Choice:** Stateless ceremony with UserStore (Approach A)
**Alternatives:**
- Event-driven provisioning (Approach B) — mixes auth/registration, doesn't support email/password naturally, async polling complexity
- Playbook-driven workflow (Approach C) — over-engineered for common case, runtime dependency on workflow engine
**Rationale:** Registration as a short-lived ceremony mirrors the existing AuthenticationProvider challenge-response pattern. Supports all three entry paths naturally. Composes with approval via tenant policy. Social login's `firstLogin=true` event complements for post-registration hooks.
**Trade-offs:** Stateless ceremony can't model long-running approval workflows natively (approval is fire-and-forget event + later admin action)
**Depends on:** D4 (UserStore), D7 (separate SPI)
**Sources:** authn-core AuthenticationRouterCore.java, authn-social-core AbstractOAuthAuthenticationProvider.java
**Exploration:** quick
**Status:** captured

## D9: UserRecord data model

**Choice:** Minimal identity + status — UserRecord(id, email, displayName, tenancyId, status, createdAt, activatedAt). Status enum: PENDING_VERIFICATION / PENDING_APPROVAL / ACTIVE / SUSPENDED. Credentials stored separately in PasswordCredentialStore.
**Alternatives:**
- Rich profile (firstName, lastName, phone, etc.) — couples identity to profile data
- Extensible metadata (Map<String, Object>) — flexible but untyped, hard to validate
**Rationale:** UserStore is about identity lifecycle, not profile data. Groups via existing GroupMembershipProvider. Credentials via dedicated stores (PasswordCredentialStore, WebAuthnCredentialStore, IdentityBindingStore).
**Trade-offs:** Profile data must be stored elsewhere if needed (preferences or a separate profile SPI)
**Depends on:** D4 (UserStore SPI), D8 (ceremony architecture)
**Sources:** platform-api identity types (PrincipalId, ActorType)
**Exploration:** quick
**Status:** captured

## D10: Password hashing

**Choice:** Argon2id via argon2-jvm (de.mkammerer, Apache 2.0, wraps libsodium)
**Alternatives:**
- bcrypt via jBCrypt — CPU-hard only, 72-byte password truncation, OWASP's second choice
- PBKDF2 via JCA — built-in but no memory-hardness
**Rationale:** OWASP's primary recommendation for new systems. Memory-hard (resists GPU/ASIC attacks). No 72-byte truncation. argon2-jvm is ~50KB + native lib — no Bouncy Castle. Parameters: memory 64 MiB, iterations 3, parallelism 1.
**Trade-offs:** Native library dependency (libsodium) may complicate some deployment environments
**Depends on:** D6 (email/password provider in scope)
**Sources:** OWASP Password Storage Cheat Sheet (Argon2id primary recommendation)
**Exploration:** quick
**Status:** revised (R1-03: bcrypt is OWASP's second choice; argon2-jvm eliminates the Bouncy Castle concern)

## D11: Invitation flow

**Choice:** Token-based invite with pre-assignment — InvitationRecord(token, email, tenancyId, assignedGroups, expiresAt, createdBy). Invited user clicks link → signup form pre-filled with tenant + email. Assigned groups applied on registration. Invitation consumed on use. Stored in InvitationStore SPI.
**Alternatives:**
- Email-only invite — simpler but no group pre-assignment
- Link-only invite — no identity pre-verification
**Rationale:** Admins need to control who joins and with what permissions. Token binds to a specific email, preventing link sharing. Pre-assigned groups support role-based onboarding.
**Trade-offs:** Requires InvitationStore SPI and admin API surface
**Depends on:** D3 (invitation-only is one of the tenant policies)
**Sources:** platform-api GroupMembershipProvider
**Exploration:** quick
**Status:** captured

## D12: Social login registration integration

**Choice:** New UserProvisioner SPI — called from `resolveOrCreateActorId()` when UserResolver returns empty. UserResolver stays read-only (CQS-compliant). UserProvisioner checks tenant policy, validates email_verified, creates UserRecord, returns PrincipalId. Account-takeover mitigation: never auto-links to existing accounts.
**Alternatives:**
- UserStoreUserResolver creates on miss — violates CQS, turns query into command
- Throw + catch at router — explicit but changes existing flow
- Pre-registration check in initiate() — requires modifying initiate to check registration policy
**Rationale:** Clean separation of concerns: UserResolver resolves (query), UserProvisioner creates (command). NoOpUserProvisioner @DefaultBean returns empty when registration module absent — backward-compatible.
**Trade-offs:** Requires modifying AbstractOAuthAuthenticationProvider to accept UserProvisioner (new constructor parameter)
**Depends on:** D4 (UserStore), D5 (trust social email_verified), D8 (ceremony architecture)
**Sources:** authn-social-core AbstractOAuthAuthenticationProvider.resolveOrCreateActorId() lines 154-161
**Exploration:** quick
**Status:** revised (R1-01: CQS violation fixed; R1-06: account-takeover mitigation added)
