# Decisions — #432 block-level forEach/loop on YamlImport

## D1: Stamped alias separator

**Choice:** Dash (`-`) — `region-us-east`
**Alternatives:**
- Double underscore (`region__us-east`) — unambiguous but ugly
- Tilde (`region~us-east`) — uncommon, unusual in YAML identifiers
**Rationale:** Industry consensus: dots for hierarchy (Helm `mychart.labels`, Ansible FQCN), dashes for composition (K8s `release-name-service`, CloudPosse null-label). Our case is composition (alias + forEach value = one identity at one level). Dot is already taken for module-to-node hierarchy (`alias.nodeId`).
**Trade-offs:** If the iteration value contains dashes, the alias boundary is ambiguous to humans. The system doesn't need to parse it back — the alias is an opaque identifier after Phase 1.
**Sources:** Helm conventions, CloudPosse null-label, Ansible FQCN, K8s DNS-1123
**Exploration:** deep-analysis
**Status:** captured

## D2: Pre-expansion as separate phase

**Choice:** Phase 1 pre-expansion creates N stamped YamlImport copies before ModuleExpander runs. ModuleExpander and ForEachExpander are unchanged.
**Alternatives:**
- Integrate forEach handling into ModuleExpander — tangles two concerns (module flattening + iteration expansion)
- Let ForEachExpander handle imports — ForEachExpander operates on nodes, not imports; mixing types
**Rationale:** Clean separation of concerns. Each phase has one job: Phase 1 expands imports, Phase 2 flattens modules, Phase 3 expands nodes. No existing code changes.
**Trade-offs:** Three-phase expansion is more complex to reason about than two-phase. But each phase is simpler.
**Sources:** ForEachExpander.java, ModuleExpander.java, YamlGraphRecorder.java
**Exploration:** quick
**Status:** captured

## D3: loop is model-only in yaml-core

**Choice:** Add `loop` field to YamlImport. yaml-core parses and carries the LoopDirective. Runtime consumption is a desiredstate/orchestration concern.
**Alternatives:**
- Implement runtime loop execution in yaml-core — yaml-core is zero-dep, no runtime context
- Defer loop field entirely — loses the symmetry, would require a second YamlImport change later
**Rationale:** Same pattern as LoopDirective on nodes — yaml-core models the directive, the orchestration runtime executes it. Adding the field now avoids a second breaking change to YamlImport.
**Trade-offs:** None — carrying data is free.
**Sources:** LoopDirective.java, yaml-core zero-dep constraint
**Exploration:** quick
**Status:** captured
