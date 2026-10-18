# HANDOFF — casehub-platform

## Last Session

Completed epic #635 (LLM stack consolidation) — all three issues landed on main:

- **#636** — ResponseFormat record in agent-api (TEXT/JSON/jsonAny), wired through all
  backends. Schema as raw JSON string, backends parse at their boundary.
- **#637** — AgentProvider.invokeBlocking() default methods returning AgentInvocationResult
  (text, token counts, cost, timing metadata).
- **#638** — Full removal of agent-langchain4j-core and agent-langchain4j modules.
  3,081 lines deleted. LangChain4j dependency management removed from root pom.xml.
  agent-spring cleaned up. All docs updated (CLAUDE.md, ARC42STORIES, contributor guide,
  consumer guide, agent-api README).

Branch `issue-635-llm-consolidation` closed and stamped. Epic #635 closed.

**Post-close finding:** Engine has significant direct LangChain4j usage that overlaps
with AgentProvider — `ReActWorkerFunctionHandler` (full tool-use loop), `ChatModelProvider`
stack, `EmbeddingModel`. The deleted bridge couldn't have helped (empty capabilities, no
tool-use support). The real gap is AgentProvider's SPI: no tool specifications, no
tool-result feedback, no ReAct loop. Filed as **platform#640**.

## Immediate Next Step

Begin **#640** — audit and reconcile LangChain4j usage across engine, neocortex, and
platform. This is L/High complexity, cross-repo.

Design direction agreed: re-use LangChain4j's ChatModel and ReAct protocol. Platform
provides a real ChatModel implementation backed by native backends (Claude SDK, OpenAI
SDK, etc.). Engine gets ChatModel from platform, not its own wrappers. Key question:
how does Claude SDK (subprocess-based) bridge into ChatModel's synchronous tool-use
protocol?

## References

- platform#640 — audit issue (open)
- engine#1235 — engine ChatModelProvider migration (open, unblocked by #636/#637)
- Slot 214 has all three repos: engine, neocortex, platform
