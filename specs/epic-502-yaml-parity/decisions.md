# Decisions — platform#402 Error Reporting Model

## D1: Error model location

**Choice:** `io.casehub.yaml.core.error` package in yaml-core
**Alternatives:**
- New yaml-error module — adds a module for pure Java types that fit yaml-core's zero-dep constraint
- yaml-plugin-api — errors are runtime concerns, not plugin contracts
**Rationale:** yaml-core is zero-dep and all consumers already depend on it. Error types are pure Java records and sealed interfaces — no external dependency needed.
**Trade-offs:** Widens yaml-core's surface, but error reporting is a core concern of the orchestration layer.
**Sources:** yaml-core/pom.xml (zero-dep verification), CLAUDE.md module table
**Exploration:** quick
**Status:** captured

## D2: Retrofit vs boundary mapping

**Choice:** Wrap at boundary — existing exceptions stay unchanged, a `YamlErrorMapper` translates them to `YamlError` at the point errors are surfaced
**Alternatives:**
- Retrofit exceptions — extend common base class carrying error model. Tighter coupling.
- Both — base class for new exceptions, boundary mapper for existing. Gradual migration.
**Rationale:** Clean separation. Internal code keeps throwing what it throws. The error model is a presentation concern, not an internal concern. Avoids touching 7 existing exception classes and their callers.
**Trade-offs:** Error context must be threaded to the boundary rather than being attached at the throw site. Acceptable since StepContext already carries resolver and deadline context.
**Sources:** DeadlineExceededException.java, ChannelClosedException.java, StepError.java
**Exploration:** quick
**Status:** captured

## D3: Source location strategy

**Choice:** Attach at parse time — Jackson-aware code (yaml-jackson, desiredstate deployment) attaches `SourceLocation` to parsed structures. yaml-core defines the record but never creates one. Consumers pass it through `StepContext`.
**Alternatives:**
- Step name only — skip line numbers, use step names and file paths. Simpler, covers 90%.
- Deferred — nullable SourceLocation field now, implement Jackson tracking later.
**Rationale:** YAML authors need line numbers to find failures in multi-hundred-line files. The zero-dep constraint is preserved because yaml-core only defines the SourceLocation record — Jackson integration lives in yaml-jackson.
**Trade-offs:** Requires StepContext to carry SourceLocation, adding a field to a widely-used type. Threading burden is real but manageable since StepContext is already threaded through the evaluation pipeline.
**Sources:** StepContext.java, yaml-jackson/pom.xml, YamlDesiredStateProcessor.java (existing Jackson parse site)
**Exploration:** quick
**Status:** captured

## D4: Actionable guidance

**Choice:** Structured context only — error types carry step name, decorator context, root cause, source location. Rendering and guidance are consumer concerns.
**Alternatives:**
- Include guidance — remediation hint templates per error category. Immediately useful but hints go stale.
- Optional guidance SPI — nullable guidance field + pluggable GuidanceProvider. Flexible but adds an SPI.
**Rationale:** A CLI, an MCP tool response, and a web UI need different guidance. The error model should carry facts, not opinions. Guidance belongs in the rendering layer.
**Trade-offs:** YAML authors don't get hints out of the box — consumers must implement their own. Acceptable because the structured context (step name, decorator, root cause) is already more useful than a raw stack trace.
**Sources:** Issue #402 error message format example
**Exploration:** quick
**Status:** captured
