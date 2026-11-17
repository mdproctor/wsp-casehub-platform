# HANDOFF — casehub-platform

**Last closed:** #835 (WS-6a: Generator fixes + plugin validation)
**Landed:** `d9416ed0` on main, published to origin
**Queue:** 16 items remaining (2 new from this session)

## This session

Fixed three generator/plugin validation bugs blocking typed playbooks. Epic #827 Batch 2.

**Code (2 commits):**
- `PluginScanner.extractParam`: String→Number/float coercion, case-insensitive enum valueOf fallback, coercion failure logging
- `PluginScanner.scanAndRegister`: wraps `@Plugin` actions in `ValidatingAction` with `coerceParams` pre-pass — String values from YAML interpolation are coerced before type validation runs
- `GraphQLResolverProcessor.generatePluginSource`: `@ContextParam` params now injected via `CurrentPrincipal` as an execute method parameter (resolved by `ServiceRegistry.lookup`). HTTP-only context params (`httpHeaders`, `queryParams`, `requestUrl`) pass `null` in plugin context
- `derivePluginName`: collision-aware overload — short names by default, full domain path (`connectors-voice-speak`) only when two domains collide. Two-pass compile-time detection across APT round
- `CompositePluginRegistry.register`: upgraded from INFO to WARNING on name collision
- `PluginScanner.mapType`: enums mapped to `ParameterType.STRING` (was OBJECT — caused validation rejection)

**Blog:** "The Generator's Last Mile" — generator blind spots: skipped context, non-injective naming, path-dependent validation

**Filed:** #848 (streaming plugins bypass validation and coercion, S/Med), #849 (streaming + ContextParam intersection, XS/Low)

**Pre-existing failures confirmed:** StepTraceCollectorTest + PlaybookDryRunTest (#846) and RunPlaybookTests state machine tests — all fail on main identically. #838 tracks the root cause.

## Next in queue

Epic #827 continues: #830 (WS-3: Trust model for playbook authoring, M/High) or #834 (WS-5: Rules headers and lint, S/Med). Both are topic changes from generator work — fresh session.

Standalone candidates: #838, #839, #840, #841, #842, #843, #765, #848, #849.
