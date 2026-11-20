# HANDOFF — casehub-platform

**Last worked:** #900 (credential resolution + rotation) implemented and ready to land; #909 closed (already fixed); 4 follow-ups filed (#910–#913)
**Branch:** `issue-900-credential-resolution-rotation` — 5 commits after squash, squash-reviewed
**Queue:** 4 new items (#910–#913), plus any remaining from previous session

## This session

Single-issue deep implementation session — #900 (M/Med): credential resolution + rotation for `StaticCredentialStore`.

**Design phase:** Brainstormed 4 design decisions (D1–D4), Standard decision review surfaced 2 additional decisions (D5–D6, totalling 27 issues reviewed), Light spec review (12 issues). Spec written and committed.

**#900 (M/Med) — feat:** Extended `StaticCredentialStore` with inbound credential lookup, three-state lifecycle (ACTIVE/GRACE_PERIOD/REVOKED), rotation with configurable grace period, revocation, and SHA-256 hashed storage.

Key changes:
- **platform-api:** `CredentialState` enum, `StaticCredentialRecord` updated with `state`/`expiresAt` (backward-compatible 7-arg constructor preserved), `isExpired()` method. Three new default methods on `StaticCredentialStore`: `lookup(credential)`, `rotate(actorId, provider, tenancyId, newCredential)`, `revoke(actorId, provider, tenancyId)`.
- **authn-inmem:** Full `InMemoryStaticCredentialStore` — lookup with constant-time comparison (`MessageDigest.isEqual`), rotate with configurable TTL, revoke. 11 new tests.
- **authn-social-jpa-common:** `StaticCredentialEntity` migrated from composite PK to surrogate UUIDv7. `CredentialHasher` utility (SHA-256 hex). `StaticCredentialId` deleted (dead code).
- **authn-social-jpa:** `JpaStaticCredentialStore` — lookup by credential hash, rotate with `PESSIMISTIC_WRITE` row-level locking, revoke via bulk UPDATE. Flyway V3 (DDL) + V3.1 (Java backfill) + V3.2 (PK change + indexes).
- **authn-social-spring-jpa:** `SpringStaticCredentialStore` + `StaticCredentialRepository` — full Spring Data JPA implementation. `SocialJpaAutoConfiguration` updated for grace period TTL injection.
- **platform:** `NoOpStaticCredentialStore` overrides `revoke()` with empty body.

**Code review findings (all fixed):** null credential validation added to `store()` in both InMemory and JPA, dead `StaticCredentialId.java` deleted, `ResultSet` wrapped in try-with-resources in V3.1 migration.

**Filed:** #909 (dead StaticCredentialId — already fixed, closed), #910 (PostgreSQL partial unique indexes — XS/Low), #911 (contract test base — S/Low), #912 (grace period cleanup scheduler — S/Low), #913 (Spring parity mcp-server — S/Med, pre-existing).

**Blog:** "The Gap Between Store and Rotate" — credential lifecycle design, rotation without dropped requests, hashing at the store boundary.

## Queue (4 items)

1. #910 — PostgreSQL partial unique indexes for credential rotation (XS/Low)
2. #911 — Contract test base for StaticCredentialStore (S/Low)
3. #912 — Credential grace period cleanup scheduler (S/Low)
4. #913 — Spring parity for mcp-server module (S/Med)

## References

- Spec: `docs/specs/issue-900-credential-resolution-rotation/2026-11-19-credential-resolution-rotation-design.md`
- Blog: `docs/blog/2026-11-20-mdp01-the-gap-between-store-and-rotate.md`
- Key files: `StaticCredentialStore.java`, `StaticCredentialRecord.java`, `CredentialState.java`, `InMemoryStaticCredentialStore.java`, `JpaStaticCredentialStore.java`, `SpringStaticCredentialStore.java`, `CredentialHasher.java`
