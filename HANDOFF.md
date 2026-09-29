# HANDOFF — Slot 198

## Last Session

Landed parent#498 — Spring Data MongoDB for platform persistence.

### parent#498 — persistence-spring-mongodb (platform)
Created `persistence-spring-mongodb` module in platform repo:
- `SpringPreferenceDocument` — `@Document` with compound `_id`, scope/tenancy indexes
- `PreferenceDocumentRepository` — `MongoRepository` with derived queries
- `SpringMongoPreferenceStore` / `SpringMongoPreferenceProvider` — SPI implementations
- `PersistenceMongoAutoConfiguration` — `@AutoConfiguration` + `@ConditionalOnMissingBean`
- 9 unit tests (Mockito, no embedded MongoDB)

Verified work repo's `persistence-spring-mongodb` already existed (16 store SPIs, raw driver via `persistence-mongodb-core`). No changes needed there.

**Architectural note recorded on the issue:** Platform uses Spring Data `MongoRepository` (simple, 2 stores). Work uses raw `MongoClient` via shared core module (complex, 16 stores — avoids duplicate query implementations).

Commit: `0d550d62` on main, pushed to origin.

## Immediate Next Step

**work#401 — Port Panache to plain JPA (21 files)**
Work repo, M/Med. The JPA stores in `runtime/src/main/java/io/casehub/work/runtime/repository/jpa/` use Hibernate Panache. Need porting to plain JPA for Spring compatibility. Different repo from this session — fresh session recommended.

## Queue Status

Position 17/26 in .plan. 11 items remaining:

| # | Issue | Repo | Scale | Notes |
|---|-------|------|-------|-------|
| 17 | work#401 | work | M/Med | Port Panache → plain JPA (21 files) |
| 18 | engine#1103 | engine | XS/Low | Fix compile errors (TrustGateService + AgentCapability) |
| 19 | workers#25 | workers | S/Low | CLAUDE.md update |
| 20 | workers#26 | workers | S/Low | Contributor guide update |
| 21 | workers#27 | workers | M/Med | spring-integration-test |
| 22 | platform#472 | platform | M/Med | MCP Spring session provider |
| 23 | platform#473 | platform | M/High | K8s Spring fabric8 integration |
| 24 | qhorus#458 | qhorus | — | runtime-core extraction |
| 25 | qhorus#459 | qhorus | — | Pre-existing test failures |
| 26 | platform#477 | platform | — | graphql-generator BeanParam ordering |

## Loose Ends

- qhorus#459 — Pre-existing test failures (PeerAttestation, A2ATenantScoping, AgentCardTenant)
- `runtime-spring` still disabled in qhorus reactor (blocked by spring-generator DeliveryConfig type-mapping bug)

## References

- Epic: casehubio/parent#515
- .plan: position 17/26, work#401 active
