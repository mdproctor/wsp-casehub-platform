# HANDOFF — casehub-platform

**Last worked:** #900 landed on main (d0b2430b), published. #909 closed (already fixed). 4 follow-ups filed (#910–#913).
**Branch:** main (clean, pushed to origin)
**Queue:** 4 items remaining, #910 is next but branch not yet created

## Session summary

Single-issue deep implementation session — #900 (M/Med): credential resolution + rotation for `StaticCredentialStore`.

**#900 (M/Med) — feat:** Extended `StaticCredentialStore` with inbound credential lookup, three-state lifecycle (ACTIVE/GRACE_PERIOD/REVOKED), rotation with configurable grace period, revocation, and SHA-256 hashed storage.

Key changes:
- **platform-api:** `CredentialState` enum, `StaticCredentialRecord` updated with `state`/`expiresAt` (backward-compatible 7-arg constructor preserved), `isExpired()`. Three new default methods on `StaticCredentialStore`: `lookup(credential)`, `rotate(actorId, provider, tenancyId, newCredential)`, `revoke(actorId, provider, tenancyId)`.
- **authn-inmem:** Full `InMemoryStaticCredentialStore` with 11 new tests.
- **authn-social-jpa-common:** `StaticCredentialEntity` migrated to surrogate UUIDv7 PK. `CredentialHasher` utility. `StaticCredentialId` deleted.
- **authn-social-jpa:** `JpaStaticCredentialStore` with SHA-256 hashing, `PESSIMISTIC_WRITE` rotation. Flyway V3/V3.1/V3.2.
- **authn-social-spring-jpa:** Full Spring Data JPA implementation.

**Blog:** "The Gap Between Store and Rotate" — published.

**Filed:** #910 (PostgreSQL partial unique indexes, XS/Low), #911 (contract test base, S/Low), #912 (cleanup scheduler, S/Low), #913 (Spring parity mcp-server, S/Med).

## Attention for next session

1. **Stale .plan file:** `/Users/mdproctor/claude/public/casehub/platform/.plan` references `issue-724-streaming-playbook-sse` — a stale plan from a different branch. Delete it before running `work start` for #910.
2. **#910 branch not created:** The queue shows #910 as active but both repos are on main. Run `work start #910` after clearing the stale .plan.
3. **Conflict resolved:** `c3d0dd4f` (fix #902) was superseded by remote `b84b7607` (fix #908) — same agent-interaction test migration. Skipped during rebase, no content lost.

## Queue (7 items)

1. #898 — ← next (priority, user-scheduled)
2. #902 — (priority, user-scheduled)
3. #904 — (priority, user-scheduled)
4. #910 — PostgreSQL partial unique indexes for credential rotation (XS/Low)
5. #911 — Contract test base for StaticCredentialStore (S/Low)
6. #912 — Credential grace period cleanup scheduler (S/Low)
7. #913 — Spring parity for mcp-server module (S/Med)

## References

- Spec: `docs/specs/issue-900-credential-resolution-rotation/2026-11-19-credential-resolution-rotation-design.md`
- Blog: `docs/blog/2026-11-20-mdp01-the-gap-between-store-and-rotate.md`
- Key files: `StaticCredentialStore.java`, `StaticCredentialRecord.java`, `CredentialState.java`, `InMemoryStaticCredentialStore.java`, `JpaStaticCredentialStore.java`, `SpringStaticCredentialStore.java`, `CredentialHasher.java`
