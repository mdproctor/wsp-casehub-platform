## D1: Generator module structure

**Choice:** Separate plugins + generator-common
**Alternatives:**
- Unified multi-goal plugin — cleaner consumer pom (one plugin block) but requires migrating all 8 consumer repos from `casehub-platform-spring-generator` to a new artifact name, and bundles unrelated dependency trees
**Rationale:** Matches established convention (spring-generator, graphql-generator, callback-generator are already separate). Doesn't break existing consumers. generator-common eliminates duplication while keeping each plugin's dependency tree minimal.
**Trade-offs:** Consumer `-spring` modules need 2-4 plugin declarations instead of one. More modules in the platform repo (5 vs 2).
**Sources:** spring-generator/pom.xml (existing Maven plugin pattern), graphql-generator (existing APT pattern, confirms separate-module convention), platform-spring/pom.xml (consumer plugin usage)
**Exploration:** quick
**Status:** captured
