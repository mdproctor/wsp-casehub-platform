# HANDOFF — casehub-platform

## Last Session

**Date:** 2026-11-11
**Landed:** #798 (5 commits), #802 (2 commits) — all on main

### #798 — AST-based plugin call chain inference
Built `CallChainScanner` (TreePathScanner) with 6 recognition rules to infer SPI call chains from connector method bodies. Eliminates `@GeneratePlugin(capability, spi, accessor, spiMethod)` for most connector methods. Integrated into `GraphQLResolverProcessor.generatePluginSource()` with annotation-override precedence. Blog: "The Annotation the Code Already Knew."

### #802 — var-typed SPI resolution fix
Two root causes: (1) `VariableTree.getType()` behavior differs across JDKs — fixed with unified var/explicit type resolution. (2) `CAPABILITY_MISMATCH` cross-validation compared API operation names against SPI method names — removed (they're intentionally different). This was the actual cause of 97/121 method failures.

### Key findings
- `resolveVarPlatformType` path is untestable locally (this JDK resolves `var` to the inferred type). Connectors build is the integration test.
- `requireCapabilityMethodName` is populated but unused after removing CAPABILITY_MISMATCH. Could verify capability class against Jandex accessor return type (enhancement).

## Queue

| # | Title | Scale | Priority |
|---|-------|-------|----------|
| 803 | 34 methods still fail SPI resolution — identical pattern to working ones | M | High |
| 804 | Static default assigns String to Integer — type mismatch | XS | High |
| 805 | cursor param should be @Optional, not @Required | XS | Med |
| 806 | Wire pluginSubject and absorbSiblings from @GeneratePlugin | S | Med |
| 807 | Voice and messaging need different resolution patterns | S | Low |
| 808 | Hand-written plugin skip detection across modules | S | Med |

**Recommended start:** #803 + #804 + #805 bundled — all in CallChainScanner, two are XS fixes.
