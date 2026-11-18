# HANDOFF — casehub-platform

**Last worked:** 4 issues closed (#849, #851, #867, #869), 3 new issues filed, code review clean
**Landed:** `2d6f3b6a` on main (6 commits)
**Queue:** 5 items remaining, #870 is next active

## This session

Swept through S/XS issues spanning the generator, module system, capture scoping, and language documentation.

**Implemented:**

1. **#849 — Streaming + @ContextParam intersection** — Fixed `GraphQLResolverProcessor.generatePluginSource()`: the streaming+subject branch now nests `hasNonHttpContextParams` to add `__principal` to the `process()` method signature. Also removed erroneous subject-param skip from the delegate call that dropped it from the SPI method invocation.

2. **#851 — Module system demonstration restored** — Split the simplified `modules.playbook.yaml` into a module definition file (`composition/modules/status-panel.yaml`) and an importing playbook demonstrating typed parameters, default values, output chaining, and conditional imports. Fixed `FileSystemModuleLoader` to deduplicate module files when the same module is imported multiple times with different aliases.

3. **#867 — Reserved capture names** — Added `RESERVED_CAPTURE_NAMES` validation in Walker (compile-time) and YamlTestExecutor (runtime). `capture: result` now rejected with a clear error naming the collision. The reserved set (`result`, `error`, `each`, `var`, `params`, `module`, `events`) is defined once in `StepKeywords` and referenced by both. Renamed `capture: result` → `capture: output` across 25 files.

4. **#869 — Parallel concurrency documentation** — Added `parallel:` (list and map forms), `race:`, and `try/catch/finally` subsections to the YAML language guide. Documented `concurrency`, `cancel-remaining`, `advance-after`, and `collection-timeout` with types, defaults, and examples.

**Code review:** 0 CRITICAL, 1 WARNING (fixed: duplicated `RESERVED_CAPTURE_NAMES` constant → extracted to `StepKeywords`), 3 NOTEs (all advisory, no code changes needed).

**Blog:** "The Name the Framework Already Owns" — variable scoping collisions, reserved naming enforcement, why the fix belongs at compile time not at the collision point.

**Issues filed:** #873 (PlaybookRunnerCore duplicate capture registration, XS/Low), #874 (streaming plugin without subject + ContextParam, XS/Low), #875 (module conditional import testing, S/Low)

## Resuming #870

**Next issue:** #870 — LocationIndex import expansion (S/Med)

LocationIndex currently only tracks mappings from the initial parse. When `expandImports` processes module imports, the expanded content (stamped sections, parameter-resolved values) has no location tracking. Extending LocationIndex to cover expanded content requires threading it through `ModuleExpander` and `PlaybookModuleBridge`.

## Queue (5 items)

1. #870 — LocationIndex import expansion (S/Med) ← next
2. #871 — Background trace integration (S/Med)
3. #873 — PlaybookRunnerCore duplicate capture registration (XS/Low)
4. #874 — Streaming plugin without subject ContextParam intersection (XS/Low)
5. #875 — Module conditional import testing (S/Low)
