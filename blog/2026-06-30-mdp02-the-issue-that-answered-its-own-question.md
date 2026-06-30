---
layout: post
title: "The Issue That Answered Its Own Question"
date: 2026-06-30
type: phase-update
entry_type: note
subtype: diary
projects: [casehub-platform]
tags: [scim, did-resolution, identity]
---

Sometimes the most useful thing you can do with a filed issue is close it.

During the ScimDIDResolver design review, we filed an enhancement: what if the resolver could query SCIM by DID extension attribute directly, instead of requiring an actorId? The SCIM filter would look like `urn:ietf:params:scim:schemas:extension:casehub:2.0:Agent:did eq "{did}"` — and suddenly you could resolve any DID through SCIM without knowing who claimed it.

The issue body already contained its own skepticism. "SCIM filter support for custom extension attributes is SCIM-server-dependent. Not all SCIM servers support filtering on extension schema attributes." We filed it anyway, because deferred is not the same as rejected.

Coming back to it fresh, the research confirmed what the skepticism suspected. RFC 7644 technically allows filtering on fully qualified extension URNs. But "technically allows" and "works in production" are different things. Some SCIM server lexers choke on the colon-separated URN prefix in filter expressions and return `invalidFilter`. AWS IAM Identity Center restricts enterprise extension filtering. The Evolveum SCIMREST framework requires connectors to explicitly declare which extension attributes support filtering — it's opt-in, not automatic.

The deeper problem isn't SCIM compatibility though. It's that the use case doesn't exist. The composite resolver chain runs WebDIDResolver and KeyDIDResolver before ScimDIDResolver. Both handle the null-actorId case — did:web fetches over HTTPS, did:key decodes from the DID string itself. ScimDIDResolver is the fallback for actors whose DIDs are provisioned in an identity provider and aren't published anywhere else. For that scenario, you always have the actorId. That's the whole point.

We briefly explored whether the real motivation might be capability-based agent discovery — finding agents by what they can do rather than by name. But that's an EndpointRegistry concern, not a DID resolution concern. SCIM provisions identity. It's not an agent directory.

The issue answered its own question. We closed it.
