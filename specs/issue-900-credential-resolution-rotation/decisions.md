## D1: Data model for credential state and rotation

**Choice:** Surrogate UUID `id` column as PK. Multiple rows per (actor_id, provider, tenancy_id) — one ACTIVE, zero-or-one GRACE_PERIOD. Add `status`, `expires_at`, `credential_hash` columns.
**Alternatives:**
- Separate rotation table — backward compatible PK but splits one concept across two tables, doubles query surface
- Status in composite PK — prevents multiple grace-period credentials, status-in-PK is unusual
**Rationale:** Cleanest model for the domain. Rotation with grace period inherently requires multiple credentials per actor/provider/tenant. Surrogate ID is standard for this pattern.
**Trade-offs:** PK change requires Flyway V3 migration. Existing `find(actorId, provider, tenancyId)` must filter by status=ACTIVE.
**Sources:** StaticCredentialStore.java, StaticCredentialEntity.java, V2__add_static_credentials.sql, WorkerCredentialStore (lookup-by-token pattern)
**Exploration:** quick
**Status:** captured
