# HANDOFF — casehub-platform

**Last closed:** #807 (Plugin generator: voice and messaging resolution patterns)
**Landed:** `45dd3954` on main, published to origin
**Queue:** 8 items remaining

## This session

Made `@GeneratePlugin(spi)` functional in the graphql-generator APT. The attribute existed since the annotation was designed but was never consumed — extracted into `PluginMeta` and ignored. Now bypasses AST inference when specified, counts as annotation-guided resolution instead of fallback.

**Filed:** connectors#264 (consumer-side annotation placement), platform#844 (routing parameter auto-identification when spi is specified).

## Next in queue

Epic #827 Batch 2 (parallel): #833 (WS-4: Canonical form) or #835 (WS-6a: Generator fixes + plugin validation) — either can go first.

Or standalone: #838, #839, #840, #841, #842, #843, #765.
