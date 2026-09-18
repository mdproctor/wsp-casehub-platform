<<<<<<< HEAD
# Session Handover — Slot 198

## What Happened

Executed Task 1 (Batch 1: Foundation) of the Spring Data JPA plan for casehubio/parent#493. Created 10 jpa-common Maven modules, moved 20 Java entity/helper files and 11 Flyway SQL migrations from existing -jpa modules into their shared -jpa-common counterparts using IntelliJ MCP `ide_move_file`. Updated all 10 existing -jpa pom.xml files to depend on their new -jpa-common module. Added all 10 jpa-common modules to the parent pom.xml reactor.

Fixed three dependency issues discovered during build verification:
- Added `jackson-databind` (provided) to datasource-jpa-common, memory-jpa-common, and acl-jpa-common (entities use ObjectMapper for JSON columns)
- Added `hibernate-core` (provided) to acl-jpa-common (AclAuditLogEntity uses @JdbcTypeCode)
- Added `jandex-maven-plugin` to all 10 jpa-common modules (Quarkus Hibernate ORM discovers entities via Jandex index)

Build verification: full compilation passes (`mvn install -DskipTests`), all 260 tests across 9 modified -jpa modules pass. Two pre-existing test failures noted: `RestControllerWriterTest#mapsVoidReturnToNoContent` (rest-spring-generator) and `EventTypeResourceTest` (subscriptions), plus `agent-claude` tests fail without local Claude CLI.

Pre-existing: `memory-jpa` module is not in the parent pom reactor — was never listed there. Not introduced by this change.

Branch: `feat/493-spring-data-jpa` (4 commits on project repo, workspace branch created to match).

## What's Next

| Item | Scale | Complexity | Notes |
|------|-------|------------|-------|
| Task 2: persistence-spring-jpa (pattern module) | M | Med | Full TDD — establishes the pattern for all 9 remaining spring-jpa modules |
| Tasks 3-9: remaining spring-jpa modules | L | Low-Med | Follow Task 2 pattern, increasing complexity per batch |
| Task 10: full build verification + CLAUDE.md | S | Low | Final verification pass |
=======
# Handoff — Simulation Service (Slot 195)

## What happened this session

One issue completed (#328), advancing the queue from position 14/18 to 15/18. Two follow-on issues filed (#347 pattern synthesis, #348 data catalogue).

**#328 — Domain-specific corpus builders:** Eight deliverables across 7 commits:

1. **InvocationRecord.of() factories** (simulation-api): `of(tenancyId, input, output)` and `of(tenancyId, key, input, output)` — eliminates 5-arg constructor boilerplate.

2. **CorpusSeed<I,O>** (simulation-api): final concrete class — typed accumulator with `withKeyExtractor()` (auto-derives keys on `add()`), `withOutputMapper()` (derives output from input), `seedInto(corpus)` (data-only, no runtime mutation). Composition over inheritance — the issue proposed abstract `CorpusBuilder<I,O>` but first-principles analysis showed inheritance adds nothing when all per-SPI variation is static.

3. **\*QN constants generation** (simulation-generator): `SimulationDecoratorProcessor` now emits companion `*QN` classes per SPI (e.g. `AccessControlProviderQN.CANACCESS`). Overloaded methods deduplicated. 11 QN classes generated for platform-api SPIs.

4. **simulation-testing module** (new): 5 SPI descriptor classes — AclCorpus, ModelCorpus, NotificationCorpus, PreferenceCorpus, CredentialCorpus. Each provides typed `CorpusSeed` factory methods, domain fixture factories, and default key extractors. Depends on simulation-api + platform-api + platform-simulation-core (generated QN constants) + schema-generator + jackson.

5. **LlmCorpusPopulator** (simulation-testing): Takes `Function<String, String>` (framework-agnostic). Uses `PlatformSchemaGenerator` for JSON Schema prompts. Hybrid few-shot: existing seed entries serve as LLM examples. Output adapter overload for Optional-returning SPIs.

6. **AgentCorpus + AgentProviderQN** (agent-simulation-core): Descriptor for AgentProvider simulation. `llmFunction()` adapter wires AgentProvider → Function<String, String>. SimulatedAgentBackend updated to use `AgentProviderQN.INVOKE`.

7. **Documentation**: Corpus builders section in simulation-guide.md. simulation-testing module added to CLAUDE.md module table.

8. **Follow-on issues**: #347 (pattern-based synthesis — named patterns, perturbation primitives, domain mutators, constraint-aware perturbation, statistical envelopes), #348 (data catalogue — exemplar storage, canonical sequences, statistical profiles, mutators-with-corpus).

## Decisions

- **D55: Composition over inheritance** — CorpusSeed is final in simulation-api; per-SPI descriptors are static utility classes (revised: moved from simulation-core to simulation-api by splitting seedInto to remove SimulationRuntime dependency)
- **D56: InvocationRecord.of() factories** — zero new types, eliminates boilerplate
- **D57: withKeyExtractor auto-derives keys** — seedInto is data-only, extractor registration explicit and separate (revised: decoupled from runtime)
- **D58: withOutputMapper** — optional, for SPIs where output derives from input
- **D59: Per-SPI descriptors — static members only** — qualified names from generated QN constants (revised: D66)
- **D60: simulation-testing module** — new test-scope module
- **D61: AgentCorpus in agent-simulation-core** — avoids agent-api dep on simulation-testing
- **D62: LlmCorpusPopulator takes Function, not AgentProvider** — framework-agnostic
- **D63: 5 high-value SPIs first** — ACL, Model, Notification, Preference, Credential
- **D64: Pattern synthesis planned extension** — named patterns, domain mutators, constraint-aware perturbation, statistical envelopes (#347)
- **D65: Data catalogue planned extension** — exemplar storage, canonical sequences, statistical profiles, mutators-with-corpus, tiered computation, licensing constraints (#348)
- **D66: Generator produces QN constants classes** — compile-time safety for qualified names
- **D67: Synthesis before catalogue** — degraded mode first, catalogue adds computed envelopes

## Key findings from design review

Two adversarial reviews ran:

**First review (D55-D63, 5 rounds):**
- **R3-03/R3-06:** CorpusSeed moved from simulation-core to simulation-api — enabled by splitting seedInto to remove SimulationRuntime dependency
- **R3-02:** Qualified name constants must be generated (D66), not hand-authored strings — eliminates three-way string coupling
- **R3-04:** LlmCorpusPopulator error handling: all exceptions propagate as unchecked, fail fast
- **R3-05:** withOutputMapper + withKeyExtractor interaction explicitly specified — both operate on raw input

**Second review (D64-D65, 2 rounds):**
- **R1-02:** RecordFieldScorer analogy with mutation is structural only — composition models differ categorically (weighted sum vs Cholesky decomposition)
- **R1-08:** Statistical envelope computation tiered: Level 1 (descriptive, standard Java), Level 2 (distributional, Apache Commons Math), Level 3 (conditional, REST-based service)
- **R1-09:** Licensing constraints — raw exemplar data not redistributable; shareable layer is profiles + mutators
- **ADR1-14:** Synthesis (#347) before catalogue (#348) — degraded mode validates API before computed bounds arrive

## Vision notes (from brainstorming discussion)

Three-layer data realism stack emerged during design:
- **Seeding** (#328, done) — CorpusSeed as universal accumulation point
- **Synthesis** (#347) — named patterns, perturbation primitives, domain-specific mutators that travel with the corpus
- **Catalogue** (#348) — exemplar storage with statistical envelopes, canonical sequences, external data importers

Key concepts discussed but not yet designed:
- Statistical mutators as domain-published matched pairs (data + rules)
- Constraint-aware perturbation sampling from empirical distributions
- Inter-field correlation preservation (heart rate ↔ PR interval)
- GitHub repos as catalogue repositories with CI-validatable schemas
- Progressive disclosure DX (zero-friction profiles → guided import → captured data)
>>>>>>> issue-294-simulation-service

## References

| Artifact | Path |
|----------|------|
<<<<<<< HEAD
| Design spec | `specs/issue-493-spring-data-jpa/2026-09-16-spring-data-jpa-modules-design.md` |
| Decisions | `specs/issue-493-spring-data-jpa/decisions.md` |
| Plan | `plans/2026-09-16-spring-data-jpa-modules.md` |
| .plan queue | `.plan` — 8 issues, #493 active, position 0/8 |
| Epic | casehubio/parent#501 |
=======
| Design spec (#328) | `wksp/specs/feat-294-simulation-service/2026-09-18-corpus-builders-design.md` |
| Implementation plan (#328) | `wksp/plans/2026-09-18-corpus-builders.md` |
| Decisions (D55-D67) | `wksp/specs/feat-294-simulation-service/decisions.md` |
| Simulation guide | `proj/docs/guides/simulation-guide.md` |
| CorpusSeed | `proj/simulation-api/src/main/java/io/casehub/platform/simulation/CorpusSeed.java` |
| simulation-testing module | `proj/simulation-testing/` |
| Follow-on: pattern synthesis | casehubio/platform#347 |
| Follow-on: data catalogue | casehubio/platform#348 |
| .plan | `wksp/.plan` (position 15/18, #329 active) |

## Next action

Start #329 — strategy configuration. Needs brainstorming.
>>>>>>> issue-294-simulation-service
