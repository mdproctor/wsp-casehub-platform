## D1: Conceptual model — three-level identity hierarchy

**Choice:** Principal → Actor → Participant hierarchy with clear semantic boundaries
**Alternatives:**
- Single unified identity type — loses semantic distinction between ownership, execution, and participation
- Two levels (Principal + Actor only) — defers Participant to later, but the model is incomplete
**Rationale:** Different contexts require different identity semantics: ownership/permissions (PrincipalId), execution/audit (ActorId), interaction membership (ParticipantId). Using the right type at each call site communicates intent even when the underlying string is identical.
**Trade-offs:** Three types instead of one — more concepts for consumers to learn. Mitigated by clear rules of thumb (ownership → Principal, action → Actor, session → Participant).
**Sources:** Issue #271 body, casehubio/neocortex#269 (immediate consumer), existing CurrentPrincipal/ActorType/ActorTypeResolver in platform-api
**Exploration:** quick
**Status:** captured

## D2: String format — type:id for all identity levels

**Choice:** All identity strings use `type:id` format (e.g., `human:john`, `agent:claude:analyst@v1`, `system:scheduler`)
**Alternatives:**
- Prefix on PrincipalId only, plain strings for Actor/Participant — inconsistent, saves negligible storage
- Structured type with separate fields (id + type) — requires schema changes at every serialization boundary
**Rationale:** Formalizes the convention already in use via ActorTypeResolver. Type is encoded in the string, so existing String columns and APIs don't need schema changes. The prefix overhead (~7 bytes) is negligible.
**Trade-offs:** Parsing cost on every construction. Mitigated by the fact that ActorTypeResolver already does this parsing today.
**Sources:** ActorTypeResolver.java, existing actorId conventions (agent:*, system:*)
**Exploration:** quick
**Status:** captured

## D3: Three valid principal types — HUMAN, AGENT, SYSTEM

**Choice:** PrincipalType enum with HUMAN, AGENT, SYSTEM — consistent with existing ActorType
**Alternatives:**
- Exclude SYSTEM (not a real principal) — breaks consistency, system actions still need identity attribution
- Open-ended string type — loses exhaustive matching, no compile-time safety
**Rationale:** SYSTEM is already used throughout the codebase (ActorType.SYSTEM, system:* prefix convention). Keeping it as a valid principal type maintains consistency.
**Trade-offs:** SYSTEM principals don't map to real humans or agents, but they need identity attribution for audit and ownership.
**Sources:** ActorType.java, ActorTypeResolver.java
**Exploration:** quick
**Status:** captured

## D4: Type structure — sealed hierarchy with shared Identity interface

**Choice:** Sealed interface `Identity` with three record permits: PrincipalId, ActorId, ParticipantId
**Alternatives:**
- Three independent records, no shared interface — simpler but no polymorphism for logging/audit APIs
- Single PrincipalId with parameter naming for semantics — loses "types as compiled documentation" benefit
**Rationale:** Sealed hierarchy gives exhaustive pattern matching. Records give immutability + equals/hashCode. Delegation chain (Participant → Actor → Principal) matches the conceptual hierarchy. Shared Identity interface enables APIs that accept any identity level generically.
**Trade-offs:** One extra interface. Negligible cost for the polymorphism benefit.
**Sources:** Java 17 sealed interfaces, existing codebase patterns
**Exploration:** quick
**Status:** captured

## D5: Scope — types and documentation only, no SPI migration

**Choice:** Deliver PrincipalId/ActorId/ParticipantId types + consumer guide updates. Do not migrate existing SPI signatures or rename CurrentPrincipal.
**Alternatives:**
- Full SPI migration (replace String actorId/userId/ownerId with typed IDs) — large blast radius, separate issue
- Rename CurrentPrincipal → CurrentActor — large migration, separate issue
**Rationale:** Neocortex needs the types now. SPI migration and CurrentPrincipal rename are valuable but independent work items that should be tracked separately.
**Trade-offs:** Existing SPIs continue using raw strings until migration issues are filed and completed. New code can adopt the types immediately.
**Depends on:** D1, D4
**Sources:** User direction — "file as separate issue, neocortex just needs the types right now"
**Exploration:** quick
**Status:** captured

## D6: PrincipalType enum — reuse ActorType, rename later

**Choice:** PrincipalId uses the existing ActorType enum (HUMAN, AGENT, SYSTEM). Rename ActorType → PrincipalType tracked as a separate cross-repo refactor issue (slot-based, IntelliJ rename across all consumer repos).
**Alternatives:**
- New PrincipalType enum alongside ActorType — duplicate enums with identical values until migration completes
**Rationale:** Avoids parallel enums. The rename is a mechanical IntelliJ refactor across all consumer repos.
**Trade-offs:** Naming mismatch until the refactor lands — PrincipalId.type() returns ActorType. Acceptable as temporary state.
**Depends on:** D4
**Sources:** ActorType.java, user direction
**Exploration:** quick
**Status:** captured

## D7: Package placement — existing identity package

**Choice:** Place PrincipalId, ActorId, ParticipantId, Identity in `io.casehub.platform.api.identity` alongside CurrentPrincipal and ActorType.
**Alternatives:**
- New sub-package `io.casehub.platform.api.identity.model` — separates value types from CDI SPIs, but the package isn't overcrowded
**Rationale:** The package already has the right name and contains all identity-related types. Three records + one sealed interface is a modest addition.
**Trade-offs:** None significant.
**Depends on:** D4
**Sources:** Existing package structure
**Exploration:** quick
**Status:** captured

## D8: Serialized names use target naming from day one

**Choice:** Any new serialized form (YAML keys, JSON fields, config properties) introduced by this issue uses `principalType` — the target name — not `actorType`. The Java enum stays as `ActorType` (D6) but Jackson/serialization annotations map to `principalType`. Also add Javadoc on `ActorType` noting the planned rename (#272).
**Alternatives:**
- Use `actorType` in serialization, rename later — serialized names are harder to change than Java names, creates a breaking change for consumers
**Rationale:** Serialized forms appear in YAML files, config, API responses. Renaming those is a breaking change. Java class renames are mechanical (IntelliJ refactor). Get the external-facing name right from the start.
**Trade-offs:** Mild naming mismatch between Java enum name (`ActorType`) and serialized field name (`principalType`) until #272 lands.
**Depends on:** D6
**Sources:** User direction
**Exploration:** quick
**Status:** captured
