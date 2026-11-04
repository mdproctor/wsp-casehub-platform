# HANDOFF — casehub-platform

## Last Session (2026-11-04)

Completed #706 — Typed error handling in catch blocks (M/Med), synced to main:

- `ErrorCategory`: added `yamlKey()`/`fromYamlKey()` for kebab-case YAML naming, 6 new values (RATE_LIMIT, SESSION_LIMIT, NOT_FOUND, AUTH_DENIED, SIMULATION, INFRASTRUCTURE)
- `YamlError`: added `toDetailMap()` across all 20 records in the RuntimeStepError, CoordinationError, ParseError hierarchies
- `Result.Failure`: added `detail` field (`Map<String, Object>`) for structured error data through the retry decorator
- `FailureCategory`: constants updated from SCREAMING_SNAKE to kebab-case
- New `RuntimeStepError` records: `RateLimitError`, `SessionLimitError`, `InfrastructureError`, `AuthDeniedError`, `CategorizedStepActionError`
- `YamlErrorMapper`: new branches for agent/ACL exceptions, `fromFailure()` bridge
- `evaluateTryCatchFinally`: catch scope now exposes `${error.type}`, `${error.message}`, `${error.step}`, `${error.detail}`
- `buildResultSource`: updated to use `yamlKey()` for consistency
- `AgentInvokeHandler`: categorized `Result.failed()` with detail maps
- Agent exception enrichment: `AgentTimeoutException.timeout()`, `AgentSessionLimitException.limit()`

Also moved platform#714 (TS Walker expression parity) to casehubio/casehub-pages#608, scoped as a full TS/Java parity audit.

Design review ran 3 rounds (standard), found 20 issues — all resolved. Key findings: null safety in InfrastructureError.toDetailMap (fixed), dual-path architecture documented (handler-catch vs exception-propagation), Result.Failure.detail added to preserve structured data through retry decorator.

## Epic #702 — YAML Playbook Polish

| # | Title | Scale | Complexity | Status |
|---|-------|-------|------------|--------|
| 698 | Enforce combined-key syntax | S | Low | Done |
| 703 | Playbook variable declarations | L | Med | Done |
| 699 | Type-safe expression resolution | XL | High | Done |
| 700 | `@` annotations with `@Inject` | XL | High | Done |
| 716 | Nested step-level annotations | S | Low | Done |
| 718 | Match/select annotation threading | XS | Low | Done |
| 710 | yaml-codegen expression format | XS | Low | Done |
| 711 | AssertPlugin migration evaluation | XS | Low | Done |
| 712 | Scope dual-registration | S | Med | Done |
| 713 | ConditionEvaluator unification eval | S | Med | Done |
| 706 | Typed error handling in catch blocks | M | Med | Done (this session) |
| 705 | JSON Schema for playbook documents | M | Med | Open — next |
| 708 | Playbook dry-run mode | M | Low | Open |
| 701 | Playbook imports via module system | L | Med | Open |

## Immediate Next Step

#705 — JSON Schema for playbook documents (M/Med).

## References

- Epic: casehubio/platform#702
- TS parity audit: casehubio/casehub-pages#608 (moved from platform#714)
- Remaining queue: #705, #708, #701
