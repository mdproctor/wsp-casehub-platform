# HANDOFF — casehub-platform

**Last worked:** #987 — ManualOption flow (complete, landing pending)
**Done items:** #986 (recoverable failure), #987 (manual option flow) — both done on their branches, awaiting work-end landing
**Next in queue:** #979 — per-namespace threshold and ambiguity

## This session

Implemented #987: ManualOption flow — user-provided capability resolution in playbooks. Builds directly on #986's recoverable failure mechanism.

### What was built

- **`UserInputProvider`** — `@FunctionalInterface` SPI for synchronous user prompting during playbook execution
- **`RecoveryAction.PromptUser`** — fourth sealed variant in the command pattern (alongside RunPlaybook, Resolved, Unrecoverable)
- **`RecoveryOutcome.outputVars`** — new field + `recoveredWithOutput()` factory for the no-retry prompt path
- **`UnmetRequirementHandler`** — returns `PromptUser` when manual option has `promptText`, falls back to `Unrecoverable` when it doesn't
- **`PlaybookRunnerCore`** — 8-arg constructor with `UserInputProvider`, `attemptRecovery` handles `PromptUser`, step loop merges `${manual.<key>}` variables without retry
- **CDI/Spring wiring** — optional `UserInputProvider` injection in `PlaybookBeans` and `PlaybookAutoConfiguration`

### Key design decisions

1. **Manual input = resolution, no retry** — unlike provider path where setup playbook changes the world, user input IS the resolution; step is not re-evaluated
2. **Command pattern extended** — `PromptUser` is a runner instruction like `RunPlaybook`, not handler-internal prompting
3. **Prompt metadata from connector** — the connector that defines the capability owns the prompt text and variable name, not platform code

### Code review findings

4 notes, all cosmetic — no Fix or File items. `context.putAll(metadata)` could shadow keys (informational map), `outputVars().isEmpty()` as discriminator is implicit, minor `variableName` default source inconsistency.

### Next session should

1. Run `work end` to land #986 and #987 (both done, squash-reviewed)
2. Then `work start #979` or `work next` for the next item

## References

- Design spec: `specs/issue-987-manual-option-flow/2026-11-26-manual-option-flow-design.md`
- Decisions: `specs/issue-987-manual-option-flow/decisions.md`
- Plan: `plans/2026-11-26-manual-option-flow.md`
- Blog: `blog/2026-11-26-mdp03-manual-option-flow.md`
- Key files: `yaml-step-runtime/.../UserInputProvider.java`, `RecoveryAction.java`, `PlaybookRunnerCore.java`, `UnmetRequirementHandler.java`
