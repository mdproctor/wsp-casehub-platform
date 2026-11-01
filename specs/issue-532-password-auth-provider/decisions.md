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
