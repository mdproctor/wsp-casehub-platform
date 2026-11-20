---
layout: post
title: "Less Ceremony, More Signal"
date: 2026-11-20
entry_type: note
subtype: diary
projects: [casehubio/platform]
tags: [rest-generation, assertion-patterns, schema-enforcement, playbook-format]
---

# Less Ceremony, More Signal

Three changes landed today that share a thread: the platform was making developers write too much to say too little. A REST endpoint that just delegates to an SPI shouldn't need a hand-written JAX-RS class. An assertion that checks four fields shouldn't need four `assertThat` lines. A deprecated YAML key that the parser already rejects shouldn't survive in legacy format paths and schema validation.

## Eleven Endpoints, Zero Hand-Written REST

The authn module had SPIs for service connections, WebAuthn credentials, and social login — but no HTTP surface. Frontend components couldn't reach them without hand-wiring JAX-RS resources, path bindings, and security context plumbing.

We added three `@McpDomain` endpoint classes that delegate straight to the existing SPIs. The `graphql-generator` annotation processor produces the JAX-RS resources at compile time:

```java
@ApplicationScoped
@McpDomain("connections")
public class ConnectionEndpoint {

    @Inject ServiceConnectionProvider connectionProvider;

    @PlatformQuery("List all service connections for the current user")
    public List<ServiceConnection> listConnections(
            @ContextParam("actorId") String actorId,
            @ContextParam("tenancyId") String tenancyId) {
        return connectionProvider.listConnections(actorId, tenancyId);
    }
    // ...
}
```

`@ContextParam` is the key design choice. The actorId and tenancyId are resolved server-side from the authenticated `CurrentPrincipal` — they never appear in the generated REST signature. The client calls `GET /api/connections/list-connections` with no identity parameters. The generator handles the plumbing.

Eleven endpoints across three domains (connections, webauthn, social-auth), and the only code we wrote was the delegation methods. The REST resources, path bindings, and content negotiation are generated.

The WebAuthn `deleteCredential` endpoint needed an ownership guard — the SPI's `delete(credentialId)` doesn't take an actorId, so without a check, any authenticated user could delete any credential. Claude caught this during review. We added a `findByCredentialId` → ownership verify → delete sequence.

## One Assertion Instead of Four

Playbook test assertions were verbose:

```yaml
- assertThat: run.captures.balance.accountId
  equals: acc-100
- assertThat: run.captures.balance.currency
  equals: GBP
- assertThat: run.captures.balance.amount
  equals: 3245.67
```

Three assertions for one object. The shape of the data is obscured by the repetition. We extended the `matches` matcher so that when it receives a map instead of a string, it performs structural matching:

```yaml
- assertThat: run.captures.balance
  matches:
    accountId: acc-100
    currency: GBP
    amount: { greaterThan: 3000, lessThan: 4000 }
```

A literal value is shorthand for `equals`. A map value applies named matchers from the existing `MatcherRegistry` — `greaterThan`, `lessThan`, `not-null`, `contains`, all of them. No new assertion vocabulary; the structural form just composes what's already there.

The type-based dispatch is clean: in YAML, an integer or string is never a `Map`, so `instanceof Map` reliably distinguishes constraints from literals. The one limitation — you can't structurally match a field whose expected value is itself a map — is inherent to the design and clear from the error message.

## The Key That Survived Three Migrations

The `steps:` wrapper key was removed from the playbook format months ago. The Walker rejects it. The schema dropped it. We migrated every `.playbook.yaml` file.

But `PlaybookParser.rejectStepsWrapper()` only ran for versioned playbooks — those with `playbook:` front matter. Single-document playbooks and legacy multi-document formats returned from `assembleDocument()` before the check ran. The schema had `additionalProperties: true`, which silently accepted any unknown key.

We fixed both paths: `rejectStepsWrapper()` now runs for every format variant. The schema gained `"not": {"required": ["steps"]}` to actively reject the key in editor validation. And every playbook file got a `yaml-language-server` modeline pointing at the schema, so VS Code and IntelliJ flag violations at edit time.

The interesting discovery: the `AnnotationExtractor` pre-parser used `steps:` as a structural marker to distinguish document-level annotations from step-level ones. Rejecting `steps:` meant the annotation system couldn't track step annotations in the multi-document bare-list format. We taught it to treat `---` as a step-section boundary — when the extractor sees a document separator, everything after it is step territory.

Three changes, one principle: if the platform can derive it, the developer shouldn't have to write it. Generated REST from annotated SPIs. Structural assertions from composed matchers. Schema enforcement from a single modeline. Each one removes a layer of ceremony between intent and expression.
