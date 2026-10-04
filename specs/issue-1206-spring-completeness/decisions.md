# Decisions — Engine Spring Completeness (#1206)

## D1: Epic scope — all issues on one branch

**Choice:** Work all 7 child/blocking issues on a single branch using .plan queue
**Alternatives:**
- Bug-first (#1207 only) — smallest risk but most branches, loses context between sessions
- Foundation layer (#1207 + #1208) — smaller scope but requires follow-up branches for generators
**Rationale:** Related changes benefit from shared context; .plan queue manages ordering
**Trade-offs:** Larger PR, but squash and work-end handle that
**Sources:** casehubio/engine#1206 epic body
**Exploration:** quick
**Status:** captured

## D2: Work order

**Choice:** #1207 → #1208 → #1209 → #1210 → #1211 → #1095 → #1199
**Alternatives:**
- Blockers first (#1207 → #1095 → #1199 → rest) — unblocks dependency chain early but misses foundation
**Rationale:** Foundation first (clean leaks, extract cores) enables all subsequent generation work. #1095/#1199 blocker pair comes last when all prior extraction is complete.
**Trade-offs:** Blockers resolved late, but they depend on the foundation anyway
**Sources:** Issue dependency analysis, engine repo module survey
**Exploration:** quick
**Status:** captured

## D3: CDI event replacement pattern

**Choice:** Consumer<T> callback — replace Event<T> with Consumer<T> constructor param
**Alternatives:**
- ServiceLoader-style SPI — more explicit but more boilerplate per event type
- Keep CDI events — faster but violates zero-CDI core principle
**Rationale:** Proven platform pattern. Quarkus module bridges Consumer to CDI Event<T>, Spring auto-config bridges to ApplicationEventPublisher. Already validated in platform-core.
**Trade-offs:** Requires adapters in both Quarkus and Spring wiring modules
**Sources:** platform-core module pattern (Core Module Architecture table in CLAUDE.md)
**Exploration:** quick
**Status:** captured

## D4: Core extraction scope

**Choice:** Extract all 11 modules to -core counterparts
**Alternatives:**
- Essential 6 only (rest, work-adapter, queue, flow, a2a, mcp) — faster but leaves gaps
- Per-module assessment — flexible but loses planning predictability
**Rationale:** Most modules already have quarkus/ subpackages separating CDI wiring from logic, making extraction mechanical. Doing all 11 ensures consistent architecture.
**Trade-offs:** More work, but each extraction is small when quarkus/ separation already exists
**Sources:** IDE search showing quarkus/ subpackage pattern in a2a, actor-state, flow, mcp, queue, work-cloudevent, engine-ai
**Exploration:** quick
**Status:** captured

## D5: SPI interface location for @McpDomain migration

**Choice:** api/ module — keep all engine SPIs together
**Alternatives:**
- New rest-api/ module — cleaner REST/domain separation but adds a module for ~6 interfaces
**Rationale:** Consistent with platform pattern (platform-api holds all SPIs). Avoids module proliferation for a small number of interfaces.
**Trade-offs:** api/ module grows slightly, but it's already the SPI home
**Sources:** platform-api package structure, engine api/ module contents
**Exploration:** quick
**Depends on:** D2 (#1095 comes after core extraction)
**Status:** captured
