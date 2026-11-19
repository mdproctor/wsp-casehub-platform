## D1: Data model for credential state and rotation

**Choice:** Surrogate UUID `id` column as PK. Multiple rows per (actor_id, provider, tenancy_id) — one ACTIVE, zero-or-one GRACE_PERIOD. Add `status`, `expires_at`, `credential_hash` columns.
**Alternatives:**
- Separate rotation table — backward compatible PK but splits one concept across two tables, doubles query surface
- Status in composite PK — prevents multiple grace-period credentials, status-in-PK is unusual
- Temporal validity (valid_from/valid_until) instead of status enum — eliminates state machine but loses semantic distinction between revoked and expired credentials; makes audit queries for "all revoked credentials" impossible
**Rationale:** Cleanest model for the domain. Rotation with grace period inherently requires multiple credentials per actor/provider/tenant. Surrogate ID is standard for this pattern.
**Trade-offs:** PK change requires Flyway V3 migration. Existing `find(actorId, provider, tenancyId)` must filter by status=ACTIVE.
**Sources:** StaticCredentialStore.java, StaticCredentialEntity.java, V2__add_static_credentials.sql, WorkerCredentialStore (lookup-by-token pattern), SpringStaticCredentialStore.java, StaticCredentialRepository.java, StaticCredentialId.java, SocialJpaAutoConfiguration.java
**Exploration:** quick
**Status:** revised — added temporal validity as explicit rejected alternative (R1-03); expanded Sources list (R1-05)

## D2: SPI evolution — adding lookup/rotate/revoke

**Choice:** Add default methods to `StaticCredentialStore` with composite-key signatures:
- `lookup(String credential) → Optional<StaticCredentialRecord>` — defaults to `Optional.empty()`
- `rotate(String actorId, String provider, String tenancyId, String newCredential) → StaticCredentialRecord` — defaults to `throw UnsupportedOperationException`
- `revoke(String actorId, String provider, String tenancyId)` — defaults to `throw UnsupportedOperationException`

Composite-key signatures work because D6's invariant guarantees exactly one ACTIVE credential per (actor, provider, tenant) — the composite key unambiguously identifies the target. `rotate()` targets the ACTIVE credential, marks it GRACE_PERIOD, and inserts a new ACTIVE. `revoke()` targets all non-REVOKED credentials for the tuple (both ACTIVE and GRACE_PERIOD are invalidated during a security incident). Existing implementations compile without changes. Contract test for new methods required per PP-20260601-81b9e5.
**Alternatives:**
- Sub-interface `RotatableCredentialStore extends StaticCredentialStore` — clean separation but splits what should be one coherent interface. `GraphCaseMemoryStore extends CaseMemoryStore` is a precedent, but that adds a fundamentally different query paradigm (graph queries); rotation/revocation are lifecycle operations on the same entity, not a new query model. All consumers need rotation — no use case for injecting the base type without wanting lifecycle methods available.
- Separate `StaticCredentialResolver` SPI — splits read/write of same entity, coordination complexity
- Name the reverse-lookup method `resolve()` — collides with `CredentialResolver.resolve(String credentialRef)` in the same `platform-api` module; both are `resolve(String) → something` on credential-related interfaces. `lookup` matches `WorkerCredentialStore.lookup(String token)` exactly.
**Rationale:** Matches `WorkerCredentialStore` pattern (all methods have default implementations). Keeps one interface, one injection point. `lookup` name aligns with `WorkerCredentialStore.lookup()` for inbound credential resolution. `revoke()` throws by default per protocol PP-20260528-557f5c (spi-deletion-default-throws) — revocation invalidates credential validity, same risk class as data erasure; silent no-op during a security incident is dangerous.
**Trade-offs:** Interface grows from 4 to 7 methods. `revoke()` throwing by default means `NoOpStaticCredentialStore` must override with `{}` (matches `NoOpCaseMemoryStore.eraseById()` pattern).
**Sources:** WorkerCredentialStore.java (default method pattern, `lookup()` naming), StaticCredentialStore.java, CredentialResolver.java (naming collision avoided), PP-20260528-557f5c (spi-deletion-default-throws), PP-20260601-81b9e5 (spi-evolution-default-methods — contract test mandate)
**Exploration:** quick
**Status:** revised — renamed `resolve()` to `lookup()` (R1-08); `revoke()` default changed from no-op to throw (R1-07); added contract test mandate (R1-10); expanded sub-interface rationale with GraphCaseMemoryStore analysis (R1-09); added explicit method signatures with composite keys (R2-02)

## D3: Hashing strategy — where hashing happens

**Choice:** Hash at the store implementation boundary. SPI stays hash-agnostic — `store()` and `lookup()` accept raw credentials. JPA stores credential hash in `credential_hash` column; in-memory stores keep raw values with constant-time comparison.
**Hashing code path:** `JpaStaticCredentialStore.store()` computes SHA-256 of `record.credential()` and populates `credential_hash` column. The raw `credential` column is dropped from the V3 schema. `lookup(rawCredential)` hashes the input and queries `WHERE credential_hash = ?`. On retrieval via `find()`/`findAll()`, `StaticCredentialRecord.credential()` returns `null` — the raw credential is not stored and cannot be reconstructed. The `credential` field is semantically write-only: populated on store, null on read.
**Entropy assumption:** All credential types (API_KEY, BOT_TOKEN, PERSONAL_ACCESS_TOKEN) are expected to have 128+ bits of entropy. SHA-256 is appropriate for high-entropy secrets — brute-force is infeasible at 2^128 regardless of hash speed. For comparison: GitHub PATs have ~214 bits, Slack bot tokens ~128 bits. If low-entropy credential types are added in the future, the hashing boundary (store implementation) allows algorithm changes without SPI impact.
**Alternatives:**
- Platform-api utility with pre-hashing — uniform but couples SPI to hashing, complicates record semantics
- Hash in the record itself — mixes persistence and domain concerns, `credential()` accessor meaning changes
- Slow hash (bcrypt/Argon2id) — designed for low-entropy passwords, not high-entropy API tokens; 100-300ms per hash on `lookup()` hot path is unacceptable latency for every inbound API request
**Rationale:** Hashing is a persistence/security concern, not a domain concern. Each implementation secures storage as appropriate for its context (JPA = production, in-memory = test/ephemeral).
**Trade-offs:** In-memory store doesn't hash — acceptable since `authn-inmem` is `<scope>test</scope>` in all consumer pom.xml files and not deployed in production. `credential()` returning null on read is a semantic change — existing code reading back stored credentials must be audited.
**Sources:** Issue #900 (SHA-256 requirement), StaticCredentialEntity.java, WorkerCredentialStore (no hashing precedent)
**Exploration:** quick
**Depends on:** D1 (credential_hash column in new schema)
**Status:** revised — specified hashing code path and round-trip semantics (R1-14); documented entropy assumption (R1-12); clarified in-memory store scope (R1-13)

## D4: StaticCredentialRecord evolution — adding state fields

**Choice:** Add `CredentialState state` and `Instant expiresAt` to the existing record with defaults. Compact constructor defaults `state` to `ACTIVE` and `expiresAt` to `null`. Add backward-compatible convenience constructor with original 7 fields. No surrogate `id` on the domain record — `id` is a persistence concern internal to the JPA entity; no SPI method signature uses it (D2's composite-key signatures make it unnecessary).
**Credential nullability:** `Objects.requireNonNull(credential, "credential")` is removed from the compact constructor. `credential` becomes nullable on the record: non-null on write (store() validates), null on read (raw credential not persisted after hashing per D3). Validation moves from the record constructor to `store()` implementations, which reject null credentials before hashing. Existing code that reads `.credential()` after `find()`/`findAll()` (e.g. `ServiceConnectionE2ETest` line 75) must be updated.
**Alternatives:**
- New `StaticCredentialEntry` wrapper record — two record types for same concept, mapping overhead, `find()` and `findAll()` return different types
- Keep `requireNonNull(credential)` and use sentinel value (empty string) on read — semantically wrong; a present empty string is different from an absent credential
- Include surrogate `id` on the domain record — persistence leak; no SPI method needs it since composite-key signatures (D2) plus the ACTIVE invariant (D6) unambiguously identify targets
**Rationale:** One type throughout, zero existing call-site changes via backward-compatible constructor. Record grows from 7 to 9 fields — still reasonable. Nullable `credential` correctly models the read vs. write asymmetry introduced by D3's hashing design.
**Trade-offs:** Nullable `expiresAt` (null means no expiry, which is the common case for ACTIVE credentials). Nullable `credential` (null on read path — a semantic change from the current non-null contract).
**Sources:** StaticCredentialRecord.java, WorkerCredential.java (expiresAt + isExpired() pattern), ServiceConnectionE2ETest.java (existing .credential() read-back usage)
**Exploration:** quick
**Depends on:** D1 (state and expiresAt columns), D2 (composite-key signatures — no id needed), D3 (hashing makes credential write-only)
**Status:** revised — removed `id` from domain record (R1-16/R2-02); made `credential` nullable with constructor validation moved to store() (R2-03)

## D5: CredentialState enum values and lifecycle

**Choice:** `CredentialState` enum with three values: `ACTIVE` (current valid credential), `GRACE_PERIOD` (old credential still accepted during rotation window, with `expires_at` set), `REVOKED` (credential explicitly invalidated — security incident, manual revocation). REVOKED credentials are retained in the database for audit trail purposes — not deleted. Terminal states: REVOKED (never re-activated). Both `find()` and `findAll()` filter to ACTIVE by default — consistent behavior, no silent contract break for existing callers. Admin views requiring all states are a separate concern, served by a dedicated method when that need arises.
**Alternatives:**
- Two values only (ACTIVE, GRACE_PERIOD) with physical deletion for revocation — loses audit trail of security events
- Four values adding EXPIRED — unnecessary; GRACE_PERIOD credentials with `expires_at < NOW` are implicitly expired, queryable without a separate state
- `findAll()` returns all states by default — silent behavioral change for existing callers who assume every returned record is a live credential; creates an asymmetry with `find()` (ACTIVE-only) that is non-obvious and error-prone
**Rationale:** Three states capture the complete lifecycle. REVOKED is semantically distinct from expired (security intent vs. time-based). Retaining revoked credentials enables post-incident analysis. Filtering to ACTIVE by default on both `find()` and `findAll()` preserves backward compatibility — existing callers currently get one record per provider from `findAll()`, and that behavior is preserved.
**Trade-offs:** Query surface must handle three states in JPA implementations internally. Admin/audit queries for non-ACTIVE credentials require a separate method (not part of issue #900 scope).
**Sources:** Issue #900 (mentions REVOKED), WorkerCredentialStore (revoke pattern)
**Exploration:** quick (surfaced by review R1-04)
**Depends on:** D1 (status column)
**Status:** revised — `findAll()` now filters to ACTIVE by default, consistent with `find()` (R2-04)

## D6: Invariant enforcement and concurrency control for rotation

**Choice:** PostgreSQL partial unique index `CREATE UNIQUE INDEX ... ON authn_static_credential(actor_id, provider, tenancy_id) WHERE status = 'ACTIVE'` enforces at-most-one ACTIVE credential per (actor, provider, tenant) at the database level. Second partial index for GRACE_PERIOD. For H2 test compatibility, application-level enforcement via `SELECT ... FOR UPDATE` on existing credentials within the `@Transactional rotate()` boundary — the row lock prevents concurrent rotation from creating duplicate ACTIVE credentials.
**Alternatives:**
- Application-level enforcement only — vulnerable to races without row-level locking; insufficient for production
- Serializable transaction isolation — heavy-handed; row-level locking is sufficient and more performant
- Optimistic locking (`@Version` column) — retry-on-conflict adds complexity; pessimistic lock is simpler for a low-contention operation like rotation
**Rationale:** Belt-and-suspenders: database constraint catches bugs, row-level lock prevents races. Rotation is low-frequency (credential lifecycle, not request-path) so pessimistic locking overhead is negligible.
**Trade-offs:** Partial unique indexes are PostgreSQL-specific; H2 tests rely on application-level enforcement only. This is acceptable per existing Flyway conventions — PostgreSQL-specific features are allowed with H2 compatibility noted.
**Sources:** V2__add_static_credentials.sql (current schema), PP-20260601-81b9e5 (SPI evolution conventions)
**Exploration:** quick (surfaced by review R1-02, R1-20)
**Depends on:** D1 (surrogate PK enables multiple rows), D5 (status values for partial index predicates)
**Status:** captured
