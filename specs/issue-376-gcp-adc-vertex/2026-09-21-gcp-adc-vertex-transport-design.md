# GCP-ADC Auth Method — Vertex AI Transport for Claude Backend

## Problem

The seed catalog supports `authMethod: gcp-adc` as a field value, but nothing creates a
Claude backend instance configured for Vertex transport. When a model entry specifies
`authMethod: gcp-adc`, the `claude` backend still tries direct API auth.

The existing infrastructure handles most of the lifecycle:
- `VertexClient` (VendorClient) can validate GCP ADC credentials and list Vertex models
- `ManifestProcessor` seeds `LlmCredentialStore` from `agent-config.yaml` providers
- `BackendInstanceCoordinator` iterates credential stores and matches to factories
- `CLIOptions` has an `env` field passed to the Claude CLI subprocess

The gap: no `BackendInstanceFactory` creates a Claude backend for Vertex credentials, and
`ClaudeAgentClient` has no way to inject environment variables.

## Design

### 1. ClaudeAgentClient — env var support (agent-claude-core)

Add `Map<String, String> env` as a constructor parameter to `ClaudeAgentClient`.

Refactor `buildEventStream()` and `openSession()` to build `CLIOptions` explicitly via
`CLIOptions.builder()` (which exposes `.env()`) instead of the `ClaudeClient.async()`
fluent builder (which does not). Then use `ClaudeClient.async(CLIOptions)` to create the
async client.

Before:
```java
ClaudeClient.AsyncSpec builder = ClaudeClient.async()
    .workingDirectory(Path.of(System.getProperty("user.dir")))
    .systemPrompt(config.systemPrompt());
properties.binaryPath().ifPresent(builder::claudePath);
ClaudeAsyncClient sdkClient = builder.build();
```

After:
```java
CLIOptions cliOptions = CLIOptions.builder()
    .systemPrompt(config.systemPrompt())
    .env(this.env)
    .build();
ClaudeAsyncClient sdkClient = ClaudeClient.async(cliOptions)
    .workingDirectory(Path.of(System.getProperty("user.dir")))
    .claudePath(properties.binaryPath().orElse(null))
    .build();
```

The existing CDI-produced `ClaudeAgentClient` passes `Map.of()` — zero behavior change for
the default Claude backend. The factory passes Vertex env vars.

`ClaudeAgentProperties` is unchanged. `ClaudeAgentProvider` gains a second constructor
accepting `Map<String, String> env` for factory use.

### 2. ClaudeVertexBackendFactory (agent-claude)

```java
@ApplicationScoped
public class ClaudeVertexBackendFactory implements BackendInstanceFactory {

    @Override
    public String backendKey() { return "claude"; }

    @Override
    public boolean handles(String credentialRef, Map<String, String> credentials) {
        return credentialRef.contains("vertex")
            && credentials.containsKey("project-id");
    }

    @Override
    public BackendInstance create(String credentialRef, Map<String, String> credentials) {
        String projectId = credentials.get("project-id");
        String region = credentials.getOrDefault("region", "us-central1");
        String instanceId = deriveInstanceId(credentialRef);

        Map<String, String> env = Map.of(
            "CLAUDE_CODE_USE_VERTEX", "1",
            "ANTHROPIC_VERTEX_PROJECT_ID", projectId,
            "ANTHROPIC_VERTEX_REGION", region
        );

        var properties = new DefaultClaudeAgentProperties();
        var client = new ClaudeAgentClient(properties, env);
        var backend = new ClaudeAgentProvider(client);
        return new BackendInstance(instanceId, backend);
    }

    String deriveInstanceId(String credentialRef) {
        if ("cloud-vertex".equals(credentialRef)) return "vertex";
        return credentialRef.replace("cloud-", "");
    }
}
```

`DefaultClaudeAgentProperties` is a simple record providing sensible defaults (same
timeout, max sessions as the CDI-configured properties). This is the same pattern as
`OpenAiDirectBackendFactory` which creates `OpenAiAgentBackend` with inline config.

At startup, `BackendInstanceCoordinator` discovers the factory, iterates credential refs
from `LlmCredentialStore`, and when it finds `cloud-vertex` with `{project-id, region}`,
calls `create()`. The result is registered as `claude/vertex` — a second Claude backend
instance alongside the CDI-discovered `claude/default`.

### 3. Seed catalog Vertex entries (platform)

Add optional `apiModelId` and `instanceId` fields to `seed-catalog.yaml`. Update
`SeedCatalogModelSource.parseModel()` to read them (fall back to `id` for `apiModelId`,
`null` for `instanceId` — backward-compatible).

Add Vertex variants for the current-generation Claude models:

```yaml
# --- Anthropic via Vertex AI ---
- id: claude-sonnet-5-vertex
  apiModelId: claude-sonnet-5
  backendKey: claude
  instanceId: vertex
  vendor: anthropic
  family: claude
  displayName: Claude Sonnet 5 (Vertex)
  tier: STANDARD
  capabilities: [text, vision, tool-use, code, reasoning]
  contextWindow: 200000
  maxOutput: 16384
  locality: CLOUD
  costTier: HIGH
  authMethod: gcp-adc

- id: claude-haiku-4-5-vertex
  apiModelId: claude-haiku-4-5
  backendKey: claude
  instanceId: vertex
  vendor: anthropic
  family: claude
  displayName: Claude Haiku 4.5 (Vertex)
  tier: FAST
  capabilities: [text, vision, tool-use, code]
  contextWindow: 200000
  maxOutput: 8192
  locality: CLOUD
  costTier: LOW
  authMethod: gcp-adc

- id: claude-opus-5-vertex
  apiModelId: claude-opus-5
  backendKey: claude
  instanceId: vertex
  vendor: anthropic
  family: claude
  displayName: Claude Opus 5 (Vertex)
  tier: FLAGSHIP
  capabilities: [text, vision, tool-use, code, reasoning]
  contextWindow: 200000
  maxOutput: 32768
  locality: CLOUD
  costTier: PREMIUM
  authMethod: gcp-adc
```

The `instanceId: vertex` binds these descriptors to the factory-created Vertex backend
instance, so the router resolves them to the correct transport.

### 4. Credential seeding (already works)

Users configure Vertex credentials in `agent-config.yaml`:

```yaml
providers:
  - vendor: vertex
    credential:
      project-id: env:GOOGLE_CLOUD_PROJECT
      region: env:GOOGLE_CLOUD_REGION
```

`ManifestProcessor.processProviders()` resolves `env:` refs via `ManifestCredentialResolver`,
stores as `cloud-vertex` in `LlmCredentialStore`. `VertexClient` declares
`requiredFields: ["project-id", "region"]` which `buildVendorRequirements()` picks up.
No changes needed.

## Data flow

```
agent-config.yaml (providers: [{vendor: vertex, ...}])
  → ManifestProcessor.processProviders()
    → LlmCredentialStore.store("platform", "cloud-vertex", {project-id, region})

BackendInstanceCoordinator.onStartup()
  → LlmCredentialStore.listRefs("platform") → ["cloud-vertex"]
  → ClaudeVertexBackendFactory.handles("cloud-vertex", {project-id, region}) → true
  → ClaudeVertexBackendFactory.create(...)
    → ClaudeAgentClient(properties, env={CLAUDE_CODE_USE_VERTEX=1, ...})
    → ClaudeAgentProvider(client)
    → BackendInstance("vertex", provider)
  → BackendInstanceRegistry.register(claude/vertex)

User requests model "claude-sonnet-5-vertex"
  → ModelRegistry.resolveById("claude-sonnet-5-vertex")
    → ModelDescriptor{backendKey=claude, instanceId=vertex, apiModelId=claude-sonnet-5}
  → BackendInstanceRegistry.resolve("claude", "vertex")
    → Vertex-configured ClaudeAgentProvider
  → AgentSessionConfig rewritten with apiModelId="claude-sonnet-5"
  → CLI subprocess launched with CLAUDE_CODE_USE_VERTEX=1 env vars
```

## Testing

- **ClaudeAgentClient** — unit test: verify CLIOptions env vars are set when env map is
  non-empty; verify Map.of() produces no env vars (backward compat)
- **ClaudeVertexBackendFactory** — unit test: handles() true/false for various credential
  shapes; create() produces correct env map; deriveInstanceId() behavior
- **SeedCatalogModelSource** — unit test: apiModelId/instanceId parsed when present,
  defaults when absent
- **Integration** — BackendInstanceCoordinatorTest: factory registers vertex instance when
  vertex credentials present in store

## Files changed

| Module | File | Change |
|--------|------|--------|
| agent-claude-core | ClaudeAgentClient.java | Add env constructor param, refactor to CLIOptions builder |
| agent-claude-core | ClaudeAgentProvider.java | Add env-accepting constructor |
| agent-claude | ClaudeVertexBackendFactory.java | New — BackendInstanceFactory impl |
| agent-claude | DefaultClaudeAgentProperties.java | New — default properties record for factory use |
| agent-claude | Quarkus CDI producer | Pass Map.of() for existing ClaudeAgentClient |
| platform | SeedCatalogModelSource.java | Read optional apiModelId, instanceId fields |
| platform | seed-catalog.yaml | Add 3 Vertex model entries |

## References

- BackendInstanceFactory.java — SPI contract
- BackendInstanceCoordinator.java:52-76 — startup factory iteration
- OpenAiDirectBackendFactory.java — existing factory pattern
- CLIOptions.java — env field (Map<String, String>)
- ClaudeClient.AsyncSpecWithOptions — CLIOptions-based builder
- VertexClient.java — existing VendorClient for Vertex (requiredFields, listModels)
- ManifestProcessor.java:47-59 — provider credential seeding
- casehubio/platform#376
