# Design Journal — issue-429-yaml-type-system

## 2026-09-24 — Type system polish + block-level iteration

**Completed:** #429 (yaml-core type system polish), #432 (block-level forEach/loop on YamlImport)

### #429 — Type system polish

Unified three parallel type vocabularies (CsvColumnType, ParameterType, proposed ValueType) into one. The key insight was that ObjectVariableSource/withObjectScope/resolveTyped were built but completely unused in production — no backward compatibility constraints. This freed us to add source-controlled container semantics (allowContainerReturn + drillOnly) without fighting existing behavior.

The forEach type loss (toString on line 49 of VariableSource.forEachContext) was the original bug. The fix — registering an ObjectVariableSource.drillOnly alongside the VariableSource for CSV rows — is a two-line change in ForEachExpander. But the design around it (the scalar-only rule for bare references, the dual-registration pattern) required careful analysis of every resolution path.

Design review (standard, 3 dimensions, $94.80) found 51 issues and strengthened the spec significantly — added TypedSchema interface, error context wrapping, duplicate column detection, and the YAML parser pre-typing caveat.

### #432 — Block-level iteration

The 2x2 gap (step vs block × compile-time vs runtime) was identified during the type system brainstorm. ForEachDirective and LoopDirective both decorate individual nodes; modules define blocks but accept neither. The fix: forEach and loop on YamlImport, with a new ImportExpander as Phase 1 pre-expansion.

The dash-separator decision was validated by web research: industry consensus across Helm, K8s, Ansible, and CloudPosse is dots for hierarchy, dashes for composition. Our stamped aliases (region-us-east) follow the composition convention.

A 4-arg convenience constructor on YamlImport avoided modifying 44+ existing call sites — cleaner than mass-updating tests.

### Next: #433 — Dynamic step catalog

L-scale new subsystem. YAML-declared step definitions with schema-validated inputs/outputs and six invoke bindings (MCP, REST, GraphQL, Python, agent, process). Bridges the gap between @StepPlugin (compile-time safety, requires recompilation) and operationally editable step vocabularies. Primary use case: FSI operational playbooks.
