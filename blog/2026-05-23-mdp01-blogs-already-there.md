---
layout: post
title: "The blogs were already there"
date: 2026-05-23
type: phase-update
entry_type: note
subtype: log
projects: [casehub-platform]
tags: [blogging, publishing, routing]
---

The session opened with a question I'd been ignoring: had any of the
casehub-platform blog entries actually made it to mdproctor.github.io?
I brought Claude in to check. We looked at the `_notes/` directory on
the Pages repo. All twelve entries were there — every one from
2026-05-19 through 2026-05-22, already published from previous sessions.
I'd expected a gap. Instead, nothing to fix.

That left one loose end. If `publish-blog` were run as a standalone
command — outside of `work-end`, which already knows to pass
`$WORKSPACE/blog/` — it would scan `docs/_posts/` by default and find
nothing. This workspace keeps blog entries in `blog/`. The auto-publish
path at work-end was fine; standalone wasn't.

We added a one-line `blog-routing.yaml` to the workspace root, extending
the global config and leaving a comment about the source path. Small
thing, but publish-blog picks it up and the routing is now explicit.

I also parked issue #8 — a preferences editor admin UI — I'm not doing
UI work at the moment. The next real work is the GroupMembership OIDC
provider, or confirming whether engine#329 was already fixed before I
filed it.
