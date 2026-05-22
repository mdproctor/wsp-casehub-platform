# Design Journal — issue-24-apps-api

### 2026-05-22 · §Module Structure

Platform#24 (casehub-platform-apps-api) was evaluated and closed. Design decision: SlaBreachPolicy and supporting types (BreachDecision, SlaBreachContext, BreachedTask, BreachType) belong in casehub-work-api, not casehub-platform. casehub-work-api adds casehub-platform-api as a compile dependency (for Path and Preferences in SlaBreachContext) — this is explicitly permitted per ADR-0007. casehub-platform-apps-api remains a valid future home for truly cross-cutting application SPIs; none have been identified yet. Full type API design in casehubio/work#213; wiring in casehubio/work#212.
