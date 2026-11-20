# HANDOFF — casehub-platform

**Last worked:** #898, #902, #904 landed on main. 3 follow-up issues filed (#914–#916).
**Branch:** main (clean, all three branches landed and closed)
**Queue:** 7 items remaining, #910 is next

## Session summary

Three-issue session — all S/Low or S/Med, all landed on main as single squashed commits.

**#898 (S/Low) — feat:** REST endpoints for ServiceConnection, WebAuthn credential management, and social auth OAuth flows. Three `@McpDomain` endpoint classes in `authn/` module delegating to existing SPIs, with `@ContextParam` resolving actorId/tenancyId from `CurrentPrincipal`. graphql-generator APT produces 11 JAX-RS REST endpoints. Ownership guard added to `deleteCredential` during review.

**#902 (S/Med) — fix:** `PlaybookParser.rejectStepsWrapper()` now runs for all format variants (single-doc, legacy multi-doc, versioned). Schema gained `"not": {"required": ["steps"]}`. `AnnotationExtractor` updated to treat `---` as step-section boundary. 70 playbook files got `yaml-language-server` modelines.

**#904 (S/Low) — feat:** Structural pattern matching in `MatcherRegistry.matchRegex()` — when `matches` receives a map, it performs structural assertion using existing matchers as constraint vocabulary.

**Blog:** "Less Ceremony, More Signal" — covers all three issues.

**Filed:** #914 (WebAuthn SPI delete ownership, XS/Low), #915 (restore StepRunner pipeline coverage, XS/Low), #916 (Spring REST for authn endpoints, S/Low).

## Queue (7 items)

1. #910 — PostgreSQL partial unique indexes (XS/Low)
2. #911 — Contract test base for StaticCredentialStore (S/Low)
3. #912 — Credential grace period cleanup scheduler (S/Low)
4. #913 — Spring parity for mcp-server module (S/Med)
5. #914 — WebAuthn SPI delete ownership (XS/Low)
6. #915 — Restore StepRunner pipeline coverage (XS/Low)
7. #916 — Spring REST for authn endpoints (S/Low)

## References

- Blog: `docs/blog/2026-11-20-mdp02-less-ceremony-more-signal.md`
- Key files: `ConnectionEndpoint.java`, `WebAuthnEndpoint.java`, `SocialAuthEndpoint.java`, `MatcherRegistry.java`, `PlaybookParser.java`, `AnnotationExtractor.java`
