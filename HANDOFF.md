# HANDOFF — casehub-platform

## Last Session

Completed 9 issues on `issue-445-agent-invoke-handler-wiring`, closing the branch with 17 squashed commits landed on main. Two phases of work:

**Block control flow (#449-#453):** Renamed `when` → `if` across Java and TypeScript. Added MatchPattern sealed interface (ValuePattern, StructuralPattern, DefaultPattern), MatchCase record, Jackson deserializers, StepWalker three-way key classification with recursive structural step resolution (block, if/else, match/cases, parallel), StepSchemaComposer structural variants.

**Follow-ups (#454-#458):** TypeScript `when→if` rename (pages repo, cross-repo), parse-time warning for match without default, ProcessExecutor `@DefaultBean` with configurable allow-list, TypeScript MatchPattern parity (pages repo), `matchContext()` VariableSource for `${match}` scoping.

**Docs:** YAML language guide fully rewritten — 10 sections covering variables through step plugins. `when.schema.json` renamed to `if.schema.json`. Code review fix: MatchCaseDeserializer rejects cases without pattern or default. Case validation in StepWalker.

**Cross-repo commits (pages):**
- `6ac41cd0`: `when→if/condition` rename in TS yaml-core (8 files, 283 tests)
- `f2522e55`: MatchPattern types + matches() function in TS yaml-core

**Brainstorming:** Explored FSI concurrency needs and match/cases unification with state machine transitions. Key design outcome: state machine `from/on` fields should accept the same pattern shapes as `match/cases` — short form (concise `from/to/on/when`) and long form (full `match/cases`) with identical underlying semantics. Three-layer evaluation model identified: imperative (`match/if`), reactive (`when`), future rules engine (TBD keyword).

## Immediate Next Step

Start Batch 1 from `.plan-next`: #459 (unify state machine transitions with MatchPattern), #460 (three-layer ADR), plus hardening (#461, #462, #467, #468). All XS-S scale, one session.

## Queue State

`.plan-next` has 4 batches, 10 issues (#459-#468). No `.plan` active — branch is closed, work is on main.

## Key Design Decisions (this session)

- State machine `from` and `on` accept ValuePattern/StructuralPattern/AnyOfPattern/DefaultPattern — same shapes as `match/cases` `pattern:`. Short form stays concise; long form uses full match/cases.
- Three-layer evaluation model: imperative (`match/if`), reactive (`when/on:`), future rules (TBD). Keywords must not collide across layers.
- try/catch/finally (#463) must dovetail with casehub-work's existing saga/compensation implementation — review before designing.

## References

- `.plan-next` — queued work: 4 batches, 10 issues
- `docs/guides/yaml-language-guide.md` — 10-section guide (updated this session)
- `specs/issue-445-agent-invoke-handler-wiring/2026-09-26-inline-block-control-flow-design.md` — block control flow spec
- `specs/issue-445-agent-invoke-handler-wiring/decisions.md` — D1-D5 block control flow decisions
- `specs/issue-386-runtime-orchestration/2026-09-22-runtime-orchestration-primitives-design.md` — decorator evaluation order, state machines, concurrency primitives
