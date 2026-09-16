## D1: SPI interface location

**Choice:** All SPI interfaces go in qhorus `api/` module — it's already documented as "Extension API module (SPI contracts, no runtime deps)."
**Alternatives:**
- `runtime-core/` — exists but is for framework-neutral implementations, not API contracts
**Rationale:** Follows qhorus's own module taxonomy. `api/` already contains store interfaces, SPI contracts, and service facades.
**Trade-offs:** None.
**Exploration:** quick
**Status:** captured

## D2: Number of SPI interfaces

**Choice:** One interface per domain — `ChannelsApi`, `MessagingApi`, `GovernanceApi`, `ComplianceApi`. Query + Mutation methods on the same interface.
**Alternatives:**
- Separate query/mutation interfaces per domain — more granular but doubles the interface count for no practical benefit (the generator handles both)
**Rationale:** Follows the platform pattern (AclApi, PreferenceApi, CallbackApi all combine query + mutation). One interface = one domain = one generated resolver + one generated REST resource.
**Trade-offs:** None.
**Exploration:** quick
**Status:** captured

## D3: Compliance domain name

**Choice:** Rename from `qhorus` to `compliance` during migration.
**Alternatives:**
- Keep `qhorus` — inconsistent with channels/messaging/governance naming convention
**Rationale:** Every other qhorus domain is named after its capability. `qhorus` names the product, which is already implied by the package. All 13 methods are prefixed with `compliance`.
**Trade-offs:** Existing MCP clients referencing `qhorus` domain need updating. Acceptable since the entire generation pipeline is being rebuilt.
**Exploration:** quick
**Status:** captured

## D4: Special case handling

**Choice:** Keep `ChannelsSubscriptionResolver` and `ChannelsModelEnricher` hand-written. Only migrate Query + Mutation resolvers.
**Alternatives:**
- Migrate subscriptions too — not supported by the generator (`Multi<>` streaming has no REST equivalent)
- Migrate ModelEnricher — it implements `ModelEnricher`, not a query/mutation SPI
**Rationale:** The generator produces GraphQL resolvers + REST resources from `@PlatformQuery`/`@PlatformMutation`. Subscriptions and ModelEnricher don't fit this model.
**Trade-offs:** 2 of 9 files remain hand-written. This is expected and correct.
**Exploration:** quick
**Status:** captured

## D5: Implementation bean location

**Choice:** Implementation beans stay in the module where the resolver currently lives — `graphql/` for channels/messaging/governance, `compliance-report/` for compliance.
**Alternatives:**
- Move all to `runtime/` — separates concerns but moves code away from its dependencies
**Rationale:** The implementation beans need the same dependencies the resolvers currently use (ChannelReader, MessageDispatcher, etc.). Moving them would require re-wiring imports across modules.
**Trade-offs:** None.
**Depends on:** D1 (SPI interfaces in api/, implementations stay in their current module)
**Exploration:** quick
**Status:** captured
