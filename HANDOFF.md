# HANDOFF — casehub-platform

**Last worked:** #928 (trailing dots/hyphens) — landing on main.
**Branch:** `issue-928-trailing-dots-hyphens` — work-end in progress.
**Active item:** #929 (sanitized-group-collision) — next in queue.

## Session summary

Single-issue session — #928 fix for TemplateExtractor variable name validation.

**#928 (XS/Low) — fix:** Tightened `VALID_VAR_NAME` regex from `[a-zA-Z][a-zA-Z0-9.\-]*` to `[a-zA-Z]([a-zA-Z0-9]*[.\-][a-zA-Z0-9]+)*[a-zA-Z0-9]*`. Rejects trailing dots (`${abc.}`), trailing hyphens (`${abc-}`), and consecutive separators (`${a..b}`, `${a--b}`, `${a.-b}`, `${a-.b}`). Improved error message to describe the constraint in human-readable terms. 6 new tests, 47 total passing.

**Code review:** Clean — two minor items addressed inline (added hyphen-dot test, improved error message wording).

## Queue state

| # | Issue | Status |
|---|-------|--------|
| #928 | trailing-dots-hyphens | done, landing |
| #929 | sanitized-group-collision | queued |
| #930 | yaml-protocol-parsing | queued |
| #931 | PlaybookRunnerCore-run-overload | queued |

## Attention for next session

1. **#929 is next** — guard against sanitized group name collisions (e.g. `a.b0DOT0c` and `a0DOT0b.c` both sanitize to the same group name). XS/Low — add a check after sanitizing.
2. **#930** — YAML protocol definition parsing. S/Low — parse a `templates:` section into `ProtocolDefinition`.
3. **#931** — PlaybookRunnerCore run overload.
