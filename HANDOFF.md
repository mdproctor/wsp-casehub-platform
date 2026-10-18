# HANDOFF — casehub-platform

## Last Session

Completed #636 (ResponseFormat — structured JSON output) and #637 (invokeBlocking
convenience API). ResponseFormat added to agent-api as a zero-Jackson record (schema
as raw JSON string), wired through all four backends, LangChain4j bridge updated to
use native format instead of text-prepending. invokeBlocking is a default method on
AgentProvider returning AgentInvocationResult. Queue advanced to #638.

## Immediate Next Step

Begin #638 — deprecate and remove agent-langchain4j-core module. Requires cross-repo
consumer analysis before touching code.

## References

- `.plan` — queue at position 2/3, #638 active
- `specs/issue-635-llm-consolidation/` — design specs for #636 and #637
- `plans/2026-10-18-response-format.md` — implementation plan for #636
- `JOURNAL.md` — session narrative
