# casehub-platform Design

Zero-dependency foundational SPIs and mock implementations shared across all casehubio modules.
Publishes before everything else in the build order.

---

## Module Structure

Two-module structure enforced strictly: platform-api (Tier 1, zero production
dependencies — pure Java interfaces, records, and final classes) and platform
(Tier 3, Quarkus @DefaultBean mocks). platform-api must never acquire a Quarkus,
JPA, or casehubio import — violations cause cascading datasource failures in all
consumers. platform/ owns @DefaultBean @ApplicationScoped beans for every SPI,
each configurable via @ConfigProperty and displaceable by any non-default
@ApplicationScoped implementation in consumer deployments.

A third module, testing/ (casehub-platform-testing), ships @Alternative @Priority(1)
fixtures for identity SPIs: FixedCurrentPrincipal and InMemoryGroupMembershipProvider.
Follows the casehub-work-testing pattern: fixtures live in src/main/java of the testing
artifact, consumers declare test-scoped dependency, CDI selects automatically. No
quarkus-arc dependency — CDI API (provided) and Jandex only. Preference testing does
not require an in-memory fixture — MockPreferenceProvider.get(key) now returns typed
values via key.parse().

A fifth module, config/ (casehub-platform-config), ships ConfigFilePreferenceProvider as
@ApplicationScoped (no @DefaultBean). This displaces MockPreferenceProvider automatically
when on the classpath. pom.xml depends on platform-api, quarkus-arc, and snakeyaml
(Quarkus BOM managed). Jandex plugin enables CDI discovery as a JAR.

A sixth module, oidc/ (casehub-platform-oidc), ships OidcCurrentPrincipal as @RequestScoped
(no @DefaultBean). Follows the same optional-module pattern as config/: Jandex plugin,
quarkus-oidc compile dep. Displaces MockCurrentPrincipal automatically when on the classpath.
Consumers who do not add the dep are unaffected — quarkus-oidc is never transitive.

A seventh module, expression/ (casehub-platform-expression), ships the canonical Foundation-tier
JQ expression evaluator. JQEvaluator (@ApplicationScoped) compiles and caches JsonQuery instances
via ConcurrentHashMap, supports $secret and $config scope injection. Extracted from
casehub-engine-common so Foundation-tier repos (casehub-work, casehub-qhorus) can consume it
without an Orchestration-tier dependency. SecretManager and ConfigManager SPIs are pure Java
(Tier 1, platform-api). MockSecretManager and MockConfigManager (@DefaultBean) ship in
expression/ itself — not platform/ — so the module is self-contained when added to a classpath.
Consumer migration: casehubio/engine#320 (remove engine-common copy), casehubio/work#207
(replace JqConditionEvaluator).

## Path API

Path is a record with strict validation: segments must be non-blank, no leading,
trailing, or consecutive separators. Two construction paths are intentionally
distinct: Path.of(String...) takes explicit pre-validated segments (use for
programmatic construction), Path.parse(String) delegates to a PathParser strategy
whose separator is installation-wide config (casehub.platform.path.separator,
default /). This separation prevents round-trip mutation — Path.of("a/b") is
rejected; Path.parse("a/b") is the correct idiom for raw string input.
PathParserConfigurator (@Startup) wires the config-driven parser at application
start. Harness convention: Path.of("casehubio", "<app>", "<case-type>") for
SettingsScope construction — org segment, app segment, case-type segment — so the
inheritance chain resolves correctly up through devtown to casehubio.

PathParamConverter and PathParamConverterProvider are shipped in platform/ under
io.casehub.platform.converter. JAX-RS @Provider enables automatic Jandex discovery.
Consumer REST endpoints can declare @PathParam and @QueryParam of type Path without
manual string conversion. fromString() delegates to Path.parse(); toString() returns
Path.value() preserving the original stripped string.

## Preferences API

PreferenceKey<T extends Preference> is a record carrying namespace, name, defaultValue,
and a Function<String, T> parser. key.parse(raw) converts a config string (already
interpolated) to a typed preference value — the Drools get(String) factory pattern
colocated with the key definition. This enables MockPreferenceProvider.get(key) to
return typed values via MapPreferences.get() calling key.parse() on String values,
eliminating the need for a separate InMemoryPreferenceProvider test fixture. get(key)
returns null when no override is configured; getOrDefault(key) applies key.defaultValue()
automatically. Real business defaults live in the harness properties file (future config/
module); key.defaultValue() is a type-safe null guard only. The Function component breaks
record value equality — keys must be compared via key.qualifiedName(), not equals().
MapPreferences uses an instanceof guard before casting: a wrong-type map entry returns null
rather than ClassCastException. asMap() returns typed Java values (Integer, Long, Boolean,
Double, List, String) — not raw strings — so any pluggable ExpressionEvaluator receives
the correct type.

ConfigFilePreferenceProvider reads scope-aware YAML files at @PostConstruct (startup-only).
YAML format uses explicit scope entries (no key/scope ambiguity). Files processed left to
right — later wins per key+scope (chaining). ${VAR} interpolation (system property then env
var) applied after loading. resolve(scope) merges: unscoped YAML → scope hierarchy (root →
app → case-type) → SmallRye Config overrides (casehub.platform.preferences.defaults.*).
SmallRye overrides are unscoped — apply to all resolve() calls. Values stored as raw
strings; key.parse() converts on typed access via MapPreferences.get().

## Identity API

CurrentPrincipal is intentionally minimal: actorId(), groups(), and five defaults
(roles(), hasGroup(), actorType(), isSystem(), isAuthenticated()). roles() delegates
to groups() by convention — this documents the groups-as-roles contract and wires
directly to @RolesAllowed without an interface change when RBAC is implemented.
isAuthenticated() uses "anonymous" as the unauthenticated sentinel; "system" is the
default actorId in dev/test. Real implementations must be @RequestScoped backed by
SecurityIdentity; @RequestScoped beans injected into @ApplicationScoped REST resources
are handled safely by CDI client proxies. The mock is intentionally @ApplicationScoped
— it has no request context to read from. @ActivateRequestContext is required before
accessing CurrentPrincipal in reactive pipelines.

ActorType (HUMAN / AGENT / SYSTEM) is owned by platform-api, not casehub-ledger-api.
ActorTypeResolver.resolve(String actorId) applies a seven-rule priority chain: null or
blank → SYSTEM; "system" or "system:*" → SYSTEM; "agent:*" prefix → AGENT; versioned
persona format word:word@version (e.g. "claude:analyst@v1") → AGENT; A2A role "user" →
HUMAN; A2A role "agent" → AGENT; everything else → HUMAN. actorType() is the canonical
source of truth for actor classification; boolean derivatives must agree with it.
isSystem() delegates to actorType() == ActorType.SYSTEM — not an independent exact-match
check — so system:* scoped actors resolve consistently.

Two abstract methods added to CurrentPrincipal: tenancyId() and isCrossTenantAdmin().
Both are abstract — not interface defaults — so every implementor is forced at compile
time to declare a tenancy position. In single-tenant deployments the mock returns
TenancyConstants.DEFAULT_TENANT_ID (a fixed UUID, configurable via
casehub.tenancy.default-id); OidcCurrentPrincipal (casehub-platform-oidc) reads tenancyId
from a required JWT claim of the same name and crossTenantAdmin from an optional boolean
JWT claim (defaults false). Claim names are fixed platform contract — not configurable.
Anonymous identity (identity.isAnonymous() = true) returns sentinel values without touching
the JWT. isCrossTenantAdmin() defaults to false everywhere; the mock exposes it via
casehub.platform.principal.crossTenantAdmin for local simulation. A companion
TenancyConstants utility class in platform-api owns the two sentinels
(DEFAULT_TENANT_ID and PLATFORM_TENANT_ID) so any consumer can import constants
without depending on the identity SPI itself.

GroupMembershipProvider real implementations should also register as Quarkus
SecurityIdentityAugmentor. GroupMembershipProvider answers the inverse query (who is in
group X?); SecurityIdentityAugmentor answers the forward query (what groups is user X in?)
— both from the same data source. Augmenting SecurityIdentity.getRoles() with casehub
group memberships makes @RolesAllowed work with casehub groups without manual
CurrentPrincipal.hasGroup() checks at every call site. A GroupMembershipProvider backed
by OIDC/Keycloak Admin API is deferred — the JWT alone cannot answer inverse membership
queries; that requires a directory.

## Mock Implementation Pattern

Every SPI in platform-api gets a @DefaultBean @ApplicationScoped mock in platform/.
Mocks read all configuration via @ConfigProperty — no hardcoded values. Optional<T>
is used for fields where the config key may be absent (e.g. Optional<List<String>>
for groups, Optional<Map<String,String>> for preference defaults) because SmallRye
Config throws NoSuchElementException for absent keys on non-Optional types. @DefaultBean
yields to any non-default @ApplicationScoped bean, so consumer deployments displace
the mock by providing their own implementation — no exclusion config required.

PreferenceProvider is permanently read-only — no save() or update() will ever be added.
The write path is a separate preferences-editor module (future) that writes directly to
the backend; provider and editor never call each other. This separation holds across all
provider variants: config/ (YAML + env vars, read-only by nature), persistence-jpa/,
persistence-mongodb/. The config/ module is the Drools ChainedProperties equivalent —
each harness ships its own preferences YAML file using the platform's key/value types,
following the Drools pattern where any domain has its own properties file while sharing
the OptionKey<T> infrastructure.
