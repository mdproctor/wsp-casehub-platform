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

## D2: SPI evolution — adding resolve/rotate/revoke

**Choice:** Add default methods to `StaticCredentialStore`. `resolve()` defaults to `Optional.empty()`, `rotate()` defaults to `throw UnsupportedOperationException`, `revoke()` defaults to no-op. Existing implementations compile without changes.
**Alternatives:**
- Sub-interface `RotatableCredentialStore extends StaticCredentialStore` — clean separation but two interfaces for one store, no platform precedent
- Separate `StaticCredentialResolver` SPI — splits read/write of same entity, coordination complexity
**Rationale:** Matches `WorkerCredentialStore` pattern exactly (all methods have default no-op/empty implementations). Keeps one interface, one injection point.
**Trade-offs:** Interface grows from 4 to 7 methods.
**Sources:** WorkerCredentialStore.java (default method pattern), StaticCredentialStore.java
**Exploration:** quick
**Status:** captured

## D3: Hashing strategy — where hashing happens

**Choice:** Hash at the store implementation boundary. SPI stays hash-agnostic — `store()` and `resolve()` accept raw credentials. JPA stores credential hash in `credential_hash` column; in-memory stores keep raw values with constant-time comparison.
**Alternatives:**
- Platform-api utility with pre-hashing — uniform but couples SPI to hashing, complicates record semantics
- Hash in the record itself — mixes persistence and domain concerns, `credential()` accessor meaning changes
**Rationale:** Hashing is a persistence/security concern, not a domain concern. Each implementation secures storage as appropriate for its context (JPA = production, in-memory = test/ephemeral).
**Trade-offs:** In-memory store doesn't hash — acceptable since it's test/ephemeral only.
**Sources:** Issue #900 (SHA-256 requirement), StaticCredentialEntity.java, WorkerCredentialStore (no hashing precedent)
**Exploration:** quick
**Depends on:** D1 (credential_hash column in new schema)
**Status:** captured

## D4: StaticCredentialRecord evolution — adding state fields

**Choice:** Add `CredentialState state` and `Instant expiresAt` to the existing record with defaults. Compact constructor defaults `state` to `ACTIVE` and `expiresAt` to `null`. Add backward-compatible convenience constructor with original 7 fields.
**Alternatives:**
- New `StaticCredentialEntry` wrapper record — two record types for same concept, mapping overhead, `find()` and `resolve()` return different types
**Rationale:** One type throughout, zero existing call-site changes via backward-compatible constructor. Record grows from 7 to 9 fields (plus `id`) — still reasonable.
**Trade-offs:** Nullable `expiresAt` (null means no expiry, which is the common case for ACTIVE credentials).
**Sources:** StaticCredentialRecord.java, WorkerCredential.java (expiresAt + isExpired() pattern)
**Exploration:** quick
**Depends on:** D1 (state and expiresAt columns)
**Status:** captured
