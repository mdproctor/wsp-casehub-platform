## D1: Password policy architecture

**Choice:** SPI + composite implementation — `PasswordPolicy` interface in `registration-api`, `DefaultPasswordPolicy` in `registration-core` composed of local rules + optional `BreachDetector`. `BreachDetector` SPI in `registration-api`, `HaveIBeenPwnedBreachDetector` in `registration-core` using `java.net.http.HttpClient`.
**Alternatives:**
- Monolithic validator — simpler but not extensible, consumers can't disable breach detection
- Rule-chain pattern — `List<PasswordRule>` composition, over-engineered for current needs (YAGNI)
**Rationale:** Follows established platform SPI-in-api pattern. Breach detection as injectable dependency is important — not all deployments can reach external APIs. JDK HttpClient keeps registration-core free of external HTTP dependencies.
**Trade-offs:** Slightly more types than a monolithic approach, but the composability pays for itself when breach detection needs to be disabled.
**Sources:** `registration-api/` SPI pattern, `PasswordHasher` SPI as precedent, `RegistrationServiceCore.registerWithPassword()` as call site
**Exploration:** quick
**Status:** captured

## D2: Password reset flow placement

**Choice:** Extend `RegistrationService` SPI with `requestPasswordReset(email, tenancyId)` and `resetPassword(token, newPassword)`. Implementation in `RegistrationServiceCore`. `PasswordResetToken` + `PasswordResetStore` SPI in `registration-api` mirroring `EmailVerificationToken`/`EmailVerificationStore`. Endpoints in existing `RegistrationEndpoint`.
**Alternatives:**
- Separate `PasswordResetService` — new SPI, core class, endpoint class. More types for the same dependency composition. SRP argument doesn't hold when reset shares every dependency with registration.
**Rationale:** Reset is part of the password credential lifecycle that `RegistrationService` already owns. Same dependencies (TokenGenerator, PasswordHasher, PasswordCredentialStore, EmailSender), same token-store pattern, same module.
**Trade-offs:** RegistrationService grows from 3 to 5 methods, but all are credential-lifecycle operations.
**Sources:** `RegistrationService` SPI, `RegistrationServiceCore.verifyEmail()` pattern, `EmailVerificationStore` pattern, `PasswordCredentialStore.updatePassword()` (exists, unused)
**Depends on:** D1 (password policy validates new password in resetPassword)
**Exploration:** quick
**Status:** captured

## D3: Breach detection failure policy

**Choice:** Fail-open with warning. When HaveIBeenPwned API is unreachable, password passes policy validation but `PasswordPolicyResult` includes a warning flag. Local rules still protect; breach detection is defense-in-depth, not a hard gate.
**Alternatives:**
- Fail-closed — reject password on API error. Safer but creates availability coupling to external service; HIBP outage blocks all registrations and resets.
- Configurable fail policy — config property for OPEN/CLOSED. Premature; can add later without breaking changes (YAGNI).
**Rationale:** Registration/reset availability should not depend on a third-party API. Local rules + Argon2id provide strong baseline protection. Warning enables audit logging without blocking users.
**Trade-offs:** A breached password could be accepted during a HIBP outage. Mitigated by strong local rules and the transient nature of outages.
**Sources:** HaveIBeenPwned k-anonymity API (range endpoint), platform no-op/graceful-degradation patterns
**Depends on:** D1 (breach detection is a component of password policy)
**Exploration:** quick
**Status:** captured
