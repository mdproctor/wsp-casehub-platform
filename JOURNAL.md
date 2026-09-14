# Design Journal — issue-296-generator-nested-paths-enum

## 2026-09-14 — Session 1: Design + generator + ACL migration

### Decisions

- D7 (RoundEnvironment scanning) eliminated — investigation showed batch 1 SPIs live in platform-api, not their runtime modules. Batch 2 follows: ACL/notification SPIs → platform-api, preference SPIs → preferences-editor-core.
- Batch DELETE endpoints (revokeBatch, removeDenyBatch) changed from DELETE to POST — DELETE with request body is non-standard HTTP.
- AclApi uses AclEntryRequest directly (drop AclEntryInput/ParentInput DTOs). registerParent uses String params to avoid ResourceId simple-type detection issues in APT context.

### Key finding

Generator JAR in local Maven repo must be rebuilt before modules using APT — stale annotationProcessorPaths JARs cause silent fallback to default behavior (cached generated sources mask the issue until clean rebuild).
