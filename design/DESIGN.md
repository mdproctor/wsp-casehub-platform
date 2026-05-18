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

## Preferences API

PreferenceKey<T extends Preference> is a record carrying namespace, name, and
a compile-time defaultValue. get(key) returns null when no override is configured;
getOrDefault(key) applies key.defaultValue() automatically, eliminating null checks
at every call site. Defaults live on the Preference record (e.g. HumanApprovalThreshold.DEFAULT),
not on the Preferences interface — this keeps defaults discoverable alongside the key
definition. MapPreferences uses an instanceof guard before casting (not a raw cast):
a wrong-type map entry returns null rather than ClassCastException, which is the
correct contract when the mock populates the map with String values from config.
asMap() returns typed Java values (Integer, Long, Boolean, Double, List, String) —
not raw strings — so any pluggable ExpressionEvaluator receives the correct type.

## Identity API

CurrentPrincipal is intentionally minimal: actorId(), groups(), and four defaults
(roles(), hasGroup(), isSystem(), isAuthenticated()). roles() delegates to groups()
by convention — this documents the groups-as-roles contract and wires directly to
@RolesAllowed without an interface change when RBAC is implemented. isAuthenticated()
uses "anonymous" as the unauthenticated sentinel; "system" is the default actorId
in dev/test. Real implementations must be @RequestScoped backed by SecurityIdentity;
@RequestScoped beans injected into @ApplicationScoped REST resources are handled
safely by CDI client proxies. The mock is intentionally @ApplicationScoped — it has
no request context to read from. @ActivateRequestContext is required before accessing
CurrentPrincipal in reactive pipelines.

## Mock Implementation Pattern

Every SPI in platform-api gets a @DefaultBean @ApplicationScoped mock in platform/.
Mocks read all configuration via @ConfigProperty — no hardcoded values. Optional<T>
is used for fields where the config key may be absent (e.g. Optional<List<String>>
for groups, Optional<Map<String,String>> for preference defaults) because SmallRye
Config throws NoSuchElementException for absent keys on non-Optional types. @DefaultBean
yields to any non-default @ApplicationScoped bean, so consumer deployments displace
the mock by providing their own implementation — no exclusion config required.
