## D1: Scope — signing backends

**Choice:** Include all signing backends (vault-transit, aws-kms, gcp-kms, azure-keyvault) in scope.
**Alternatives:**
- Defer signing — smaller scope, separate issue, but leaves incomplete Spring coverage
**Rationale:** Signing backends already have core/quarkus split. Adding Spring auto-config is mechanical — spring-generator handles it. Complete coverage in one pass avoids a follow-up issue.
**Trade-offs:** Larger scope (4 additional Spring modules).
**Sources:** ledger/signing/ directory structure (already has core + quarkus split per provider)
**Exploration:** quick
**Status:** captured

## D2: Configuration approach

**Choice:** Framework-neutral LedgerProperties record hierarchy in ledger-core. Quarkus adapter reads @ConfigMapping and populates records. Spring adapter reads @ConfigurationProperties and populates same records.
**Alternatives:**
- spring-generator ConfigProperties mapping — less code but couples Spring config shape to Quarkus @ConfigMapping layout
- Individual constructor params — simplest but produces verbose constructors (30+ config keys)
**Rationale:** Matches platform pattern. Core POJOs accept a single config type — framework modules own the config source. If config shape evolves, core POJOs are unaffected.
**Trade-offs:** Boilerplate record hierarchy mirrors LedgerConfig's nested interfaces.
**Sources:** platform-core config approach, LedgerConfig.java (15 sub-interfaces, 30+ keys)
**Exploration:** quick
**Status:** captured

## D3: @McpDomain API pattern

**Choice:** Core-extract @McpDomain impl logic to constructor-injected POJOs in ledger-core. Keep @McpDomain annotation on the concrete Quarkus class (Pattern 2). Generator handles both patterns.
**Alternatives:**
- Migrate to Pattern 1 (SPI interface in api module) — more work, aligns with platform preferred pattern but not required
- Leave as-is, hand-write Spring controllers — most control, most maintenance
**Rationale:** Generators support Pattern 2. Core extraction makes the business logic framework-neutral. Migration to Pattern 1 can happen independently later if desired.
**Trade-offs:** Pattern 2 concrete classes are slightly less clean than SPI interfaces for generator consumption.
**Sources:** graphql-spring-generator description ("scans @McpDomain SPI interfaces and classes"), DefaultLedgerEntryApi.java
**Exploration:** quick
**Status:** captured

## D4: Core extraction depth

**Choice:** Extract everything possible to core POJOs. Framework modules become thin wiring shells with zero business logic.
**Alternatives:**
- Extract business logic only — @Scheduled, CDI events, Arc-specific wiring stay in runtime with Spring equivalents in ledger-spring
- Minimal extraction, spring-generator first — only extract what spring-generator can't handle
**Rationale:** Maximum framework neutrality. Core POJOs are testable without any container. Framework modules are interchangeable thin shells. Aligns with pre-release "bold changes welcome" stance.
**Trade-offs:** Larger up-front extraction effort. Some patterns (e.g., enricher pipeline with priority-ordered discovery) need framework-specific adapter code in both Quarkus and Spring.
**Sources:** platform core extraction approach (parent#469)
**Exploration:** quick
**Status:** captured

## D5: JPA entity sharing

**Choice:** Create ledger-jpa-common module with shared entity classes. Both Quarkus runtime and Spring Data JPA modules depend on it.
**Alternatives:**
- Reuse existing entities from runtime directly — simpler but pulls Quarkus deps onto Spring classpath
- Duplicate entity classes — full isolation but violates DRY
**Rationale:** Matches platform pattern (12 -jpa-common modules). Entities are pure JPA — @Entity, @Table, @Id — no framework coupling. Single source of truth for schema.
**Trade-offs:** New module to maintain. Entity moves require updating imports in runtime.
**Sources:** platform -jpa-common modules (acl-jpa-common, notifications-jpa-common, etc.)
**Exploration:** quick
**Status:** captured

## D6: Execution strategy

**Choice:** Bottom-up (dependency-ordered): jpa-common → config records → service extraction → Spring modules + generators → signing-spring → integration test.
**Alternatives:**
- Batch by layer (platform style) — proven at scale but each batch is larger
- Vertical slices — validates pattern on a real subsystem but risks re-work
**Rationale:** Follows the dependency graph naturally. Each step unblocks the next. Each step is independently testable and committable. Ledger is smaller than platform, so fine-grained ordering is practical.
**Trade-offs:** More sequential than batch-by-layer. Each step must complete before the next can fully proceed.
**Sources:** Spring deployment completion spec (batches 1-7), platform#384
**Exploration:** quick
**Status:** captured
