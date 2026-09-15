# HANDOFF — casehub-platform

## Last Session

Completed #288 (cloud model sources) end-to-end: brainstorm (8 decisions, light decision review with revisions), design spec (light spec review, 12 findings addressed — separate modules for Vertex/Bedrock, priority-sorted refresh, cache alignment, CloudModelSource interface), 7-task implementation plan, all 7 tasks implemented with TDD. Issue closed.

Key deliverables landed on branch:
- `CloudModelSource` interface extending `ModelSource` with `status()` method
- `CloudSourceStatus` record with `State` enum (ACTIVE/INACTIVE/ERROR) + factory methods
- `AnthropicCloudModelSource` + `OpenAiCloudModelSource` — wrap existing VendorClients, priority 5, last-known-good caching
- `VertexCloudModelSource` + `BedrockCloudModelSource` — inject via `Instance<VendorClient>`, graceful when module absent
- New module `llm-config-vertex/` — `VertexClient` with Google ADC auth (`google-auth-library-oauth2-http`)
- New module `llm-config-bedrock/` — `BedrockClient` with manual SigV4 signing (`software.amazon.awssdk:auth`)
- `CloudSourceCredentialBootstrap` — env var detection (`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`), `LlmCredentialStore` seeding at platform scope
- `cloudSourceStatus()` query on `LlmConfigApi` for onboarding guidance
- `ModelRegistryRefresher` — priority-sorted refresh (seed=0 before cloud=5 before configured=10)
- HttpClient reuse fix in AnthropicClient, OpenAiClient, GoogleClient
- 75+ tests across all modules, full build green

## Immediate Next Step

Brainstorm #289 (local model sources — Ollama + HuggingFace discovery and lifecycle). Queue advanced, #289 is active.

## Queue

Branch `issue-288-cloud-model-sources` has 4 issues queued: #288 (done), #289 (active), #290, #292.

## Key Design Decisions

- Cloud sources use plain `apiModelId` (same as seed catalog) — priority resolution handles overlap
- Vertex/Bedrock VendorClients in separate modules for classpath isolation (Quarkus build-time bean discovery + optional SDK deps = fragile)
- Credential bootstrap seeds store from env vars but doesn't overwrite wizard-configured credentials
- Discovery-invocation disconnect acknowledged: Vertex/Bedrock models route through Claude backend (direct API), not cloud platform endpoints — dedicated AgentBackends tracked as downstream

## References

- Spec: `specs/issue-288-cloud-model-sources/2026-09-12-cloud-model-sources-design.md`
- Plan: `plans/2026-09-12-cloud-model-sources.md`
- Decision review: `/Users/mdproctor/reviews/casehub-platform/issue-288-decision-20260912-143409/`
- Spec review: `/Users/mdproctor/reviews/casehub-platform/issue-288-cloud-model-sources-20260912-151559/`
- Epic #285: LLM model registry
