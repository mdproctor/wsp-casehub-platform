# HANDOFF — casehub-platform

**Last worked:** #853, #872 landed; 6 issues closed (5 already-fixed); 1 follow-up filed (#891)
**Landed:** `496d486c` on main, published
**Queue:** 10 items remaining, #848 is next

## This session

Queue triage session — eight issues handled, two with code changes.

**#853 (S/Med) — fix:** `AgentSessionPlugins.queryDefinition()` lacked `absorbSiblings(true)`, causing the Walker to reject `response-format` as an unknown key during `run-playbook` execution while `validate-playbook` compilation passed (compilation stubs had `absorbSiblings=true`). One-line fix + test update from error-assertion to success-assertion.

**#872 (XS/Low) — feat:** Added `Records.toMapNonNull()` — null-safe variant of `toMap()` that skips null values and empty Optionals. Code review caught that nested records used the null-preserving `toMap` path; refactored both methods into a shared `toMap(record, omitNulls)` with recursive flag propagation.

**Already-fixed closures:** #866 (lifecycle guard error msg — soredium already updated), #846 (test failures — fixed by prior #884), #657 (corruption triage — old `corruption.py` replaced), #730 (step lifecycle wiring — `StepTraceCollector` → `stepCompletionNotifier` already wired), #731 (CDI event observer — `CorpusSelectionEventObserver` already implements). **Not-applicable:** #717 (playbook UI rendering — no frontend in this repo).

**Filed:** #891 — `AgentSessionQueryHandler` ignores `SessionQuery.responseFormat()` in production (S/Med).

**Blog:** "The Two Walkers Problem" — Walker sibling absorption divergence and recursive null propagation.

## Queue (10 items)

1. #848 — Streaming plugins bypass validation and coercion ← next
2. #586 — Update generator-common to depend on mcp-api
3. #732 — MCP tool for runtime corpus phase inspection
4. #733 — Per-phase corpus-files
5. #639 — AgentSessionConfig.withModelParameters
6. #826 — Budget pool telemetry types for LLM cost
7. #697 — AgentSession.clear for non-Claude backends
8. #251 — ts-core TsjTsExecutor JVM-native TS execution
9. #284 — Capacity MCP tools
10. #891 — AgentSessionPlugins absorbs response-format but never reads it

## References

- Blog: `docs/blog/2026-11-19-mdp02-the-two-walkers-problem.md`
- Key files: `AgentSessionPlugins.java`, `Records.java`
