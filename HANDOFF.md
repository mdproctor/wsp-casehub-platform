# HANDOFF — casehub-platform

**Last worked:** #925 (dotted variable names) — landed on main.
**Branch:** `main` — all work landed.
**Active item:** #928 (trailing dots/hyphens validation) — not started.

## Session summary

Three-issue session — template extraction arc: optional segments, governance protocol integration, and dotted variable names. All landed.

**#923 (S/Med) — feat:** Optional segment syntax in `TemplateExtractor`. Bracket syntax `[...]` becomes `(?:...)?` regex groups. Variables inside unmatched optional segments are absent from the result map (not empty string). Escaped brackets `\[` `\]` treated as literals. Nested brackets rejected at compile time.

**#924 (M/Med) — feat:** Wired `TemplateExtractor` and `TemplateRegistry` into the governance protocol runtime. Three new types in `coordination-core/protocol/`: `ProtocolDefinition` (record: name + ordered template map), `ProtocolEvaluator` (ConcurrentHashMap-backed, thread-safe, register/evaluate/deregister), `ProtocolMatchResult` (sealed: Matched/Unmatched). Deleted hollow `PlaybookProtocolEvaluator` skeleton.

**#925 (S/Low) — feat:** Dotted and hyphenated variable names in `TemplateExtractor`. `${context.user}` and `${my-var}` now work. Internally sanitized to Java regex-safe group names (`0DOT0`, `0HYPHEN0`) since Java regex named groups only accept `[a-zA-Z][a-zA-Z0-9]*` — underscores are not valid either (discovered empirically).

**Code review finding fixed:** Removed unused `groupToOriginal` field from `TemplateExtractor` — the field was populated but never read; `sanitizeGroupName()` is a pure function called at both compile and extract time.

**Blog:** "Wiring the Protocol Runtime" — optional segments, dotted names, and the protocol evaluator.

**Issues filed:** #928 (trailing dots/hyphens), #929 (sanitized group name collisions), #930 (YAML protocol definition parsing).

## Queue state

| # | Issue | Status |
|---|-------|--------|
| #928 | trailing-dots-hyphens | active, not started |
| #929 | sanitized-group-collision | queued |
| #930 | yaml-protocol-parsing | queued |

## Attention for next session

1. **#928 is next** — tighten `VALID_VAR_NAME` regex to reject trailing dots and hyphens (`${abc.}`, `${abc-}`). XS/Low — straightforward regex fix + tests.
2. **#929** — guard against sanitized group name collisions. XS/Low — add a check after sanitizing.
3. **#930** — YAML protocol definition parsing. S/Low — parse a `templates:` section into `ProtocolDefinition`.
