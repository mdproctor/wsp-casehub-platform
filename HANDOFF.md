# Handoff — Simulation Service (Slot 195)

## What happened this session

One issue completed (#323), advancing the queue from position 13/18 to 14/18. Follow-on issue #344 filed for comprehensive corpora.

**#323 — Consumer adoption (simulation patterns for clinical, devtown, aml, fsitrading):** Three deliverables:

1. **Consumer Adoption section in simulation-guide.md** (279 lines): Adoption checklist, per-app subsections for clinical (AgentProvider-first), devtown (REST-client-first, 5 GitHub APIs), aml (memory-first, smallest gap), fsitrading (agent + domain SPIs). Three @InjectMock → simulation migration patterns. CI integration with Quarkus profiles. Documents CbrCaseMemoryStore gap (clinical/aml use CbrCaseMemoryStore, not CaseMemoryStore — memory-simulation-core does not cover it). Consumer-side @SimulationEligible enablement guidance (annotation path vs listing-file path). Production overhead note.

2. **Example YAML corpus fixtures** at `docs/examples/simulation/`: 6 files across 4 apps — clinical/agent-provider, devtown/github-api + case-memory-store, aml/model-registry, fsitrading/agent-provider + model-registry. Minimal templates (2-3 entries each), domain-plausible values.

3. **Follow-on issue #344** filed for comprehensive corpora (10-15 entries per SPI per app, depends on #328 and #330).

## Decisions

- **D49: Platform-side docs + fixtures only** — consumer changes via issues (CLAUDE.md constraint)
- **D50: Per-app sections** — organised by application, not by pattern
- **D51: Minimal corpus templates** — 2-3 entries, comprehensive deferred to #344
- **D52: Generic migration patterns** — not tied to specific consumer code
- **D53: Quarkus profile-based CI** — no Maven profiles or CI changes
- **D54: Fixtures at docs/examples/simulation/** — reference material, not runtime

## Key findings from design review

- **CbrCaseMemoryStore gap (R1-01):** clinical and aml use CbrCaseMemoryStore (extends CbrCaseStore, CbrCaseRetriever, CbrCaseLifecycle, CbrCaseAdmin), not CaseMemoryStore. memory-simulation-core only covers CaseMemoryStore. Consumer-side simulation-eligible listing needed.
- **YAML field naming (R1-02):** top-level entry fields are kebab-case; nested input/output fields must match SPI's actual field names (camelCase for Java records).
- **Type gap (R1-09):** YAML fixtures work for key-lookup/sequential with raw data. Rich domain return types (List<Memory>) need programmatic seeding.

## References

| Artifact | Path |
|----------|------|
| Design spec (#323) | `wksp/specs/feat-294-simulation-service/2026-09-16-consumer-adoption-design.md` |
| Implementation plan (#323) | `wksp/plans/2026-09-16-consumer-adoption.md` |
| Decisions (D49-D54) | `wksp/specs/feat-294-simulation-service/decisions.md` |
| Simulation guide | `proj/docs/guides/simulation-guide.md` |
| Example fixtures | `proj/docs/examples/simulation/` |
| Follow-on issue | casehubio/platform#344 |
| .plan | `wksp/.plan` (position 14/18, #328 active) |

## Next action

Start #328 — domain-specific corpus builders. Needs brainstorming to clarify scope.
