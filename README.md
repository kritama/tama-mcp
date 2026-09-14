# TamaMCP

Tama-focused MCP `2026-07-28` server primitives for Elixir applications.

`TamaMCP` exists so Tama can implement the current MCP server contract without
depending on a general-purpose MCP framework or carrying compatibility code for
older protocol eras.

The package is pre-release. Phase 1 provides the server and tool DSL, stateless
Streamable HTTP transport, per-request authorization, discovery, deterministic
tool listing, synchronous tool execution, schema validation, bounded telemetry,
and reusable protocol conformance helpers. Durable tasks and subscriptions are
the next implementation phases and are not advertised by the current runtime.

## Boundary

```text
Codex / OpenCode / Pi
        |
        | client-compatible MCP
        v
    Tama Link
        |
        | MCP 2026-07-28 only
        v
       Tama
        |
        | TamaMCP server runtime
        v
 durable tasks and graph execution
```

- `TamaMCP` owns MCP JSON-RPC validation, the server/tool DSL, stateless HTTP,
  protocol responses, cache keys and compiled validator artifacts, and the
  future Tasks and subscription adapter contracts.
- `TamaOAuth` owns reusable OAuth and protected-resource protocol mechanics.
- Tama owns identities, authorization policy, rate limits, the validator cache
  engine, Ecto persistence, durable execution, task transitions, and graph
  results.
- Tama Link owns client compatibility, OAuth client behavior, local
  correlation, polling recovery, and downstream progress presentation.

See [the WIP specification](https://github.com/kritama/tama-mcp/blob/develop/wip/tama-mcp-specification.md)
for the complete contract and implementation acceptance criteria.

## Deliberate scope

The implemented Phase 1 package supports:

- MCP protocol version `2026-07-28` only;
- server-side stateless Streamable HTTP;
- `server/discover`, `tools/list`, and `tools/call`;
- authorization-aware tool visibility and scope enforcement;
- application-supplied authorization decisions and safe context values;
- bounded request execution, successful results, errors, headers, and telemetry; and
- reusable conformance validation against the vendored core schema.

It does not provide an MCP client, STDIO transport, legacy initialization or
session support, prompts, resources, sampling, elicitation, MCP Apps UI,
database persistence, or a web server. Phase 1 also rejects task-required tools,
the Tasks methods, and subscriptions until their durable adapters exist.

## Server example

```elixir
defmodule Example.Tools.Echo do
  use TamaMCP.Tool, task: :disabled, scopes: ["example.echo"]

  input_schema do
    field(:message, :string, required: true, min_length: 1)
  end

  output_schema do
    field(:message, :string, required: true)
  end

  @impl true
  def call(%{"message" => message}, _context) do
    {:ok,
     TamaMCP.Response.success(
       content: [TamaMCP.Response.text(message)],
       structured_content: %{"message" => message}
     )}
  end
end

defmodule Example.Server do
  use TamaMCP.Server, name: "example", version: "1.0.0"

  tool(Example.Tools.Echo, name: "echo")
end
```

Mount the transport with authorization and cache adapters:

```elixir
forward "/mcp", TamaMCP.Transport.StreamableHTTP.Plug,
  server: Example.Server,
  authorization: Example.Authorization,
  cache: Example.Cache,
  context_headers: ["x-request-id"]
```

The authorization adapter implements the
`c:TamaMCP.Authorization.authenticate/2` callback and returns a
`TamaMCP.Authorization.Decision`. The decision carries the
authenticated principal, owner key, claims, granted scopes, credential expiry,
and explicit application assigns. Authentication runs once before transport
validation on every HTTP request.

The cache adapter implements `TamaMCP.Cache`. TamaMCP compiles tool validators
while compiling each tool module, precompiles its fixed protocol validators,
embeds their serialized artifacts, and owns versioned cache keys and
restoration. The host adapter owns storage, concurrency, expiry, distribution,
and any additional serialization required by its cache engine. Cached validator
values are opaque Erlang terms and may contain functions.

## Conformance

`TamaMCP.Conformance` validates complete Phase 1 requests and responses against
the immutable upstream schema in `priv/protocol/2026-07-28`. Its bundled wire
fixtures exercise discovery, authorization-aware listing, synchronous success,
tool errors, malformed metadata, scope denial, standard and schema-declared
header agreement, unsupported versions, explicit null output, output-schema
failure, and rejection of protocol sessions.

Host applications can call `TamaMCP.Conformance.validate/3` for individual
values or `TamaMCP.Conformance.run/3` with a request callback, their cache
adapter, and an application fixture set.

## Dependencies

- `jason` encodes and decodes JSON.
- `plug` provides the framework-neutral HTTP boundary.
- `jsonschex` validates JSON Schema Draft 2020-12 tool and protocol contracts.
- `tama_oauth` supplies OAuth and protected-resource protocol primitives.
- `telemetry` exposes bounded runtime instrumentation.

The library deliberately does not depend on Phoenix, Ecto, Bandit, Cowboy,
Anubis MCP, ex_mcp, or a validator cache engine.

## Installation

Until the first Hex release, use a sibling path for local development:

```elixir
def deps do
  [
    {:tama_mcp, path: "../tama-mcp"}
  ]
end
```

After publication:

```elixir
{:tama_mcp, "~> 0.1.0"}
```

## Development

Install the pinned toolchain and fetch dependencies:

```console
mise install
mix deps.get
```

Run the regular project checks:

```console
mix precommit
```

Run static analysis and package checks separately:

```console
mix dialyzer --plt
mix dialyzer --no-check
mix docs
mix hex.build
```

## Branching

TamaMCP uses Git Flow with `develop` as the integration branch and `main` as
the production branch. Feature and fix work starts from `develop`; release
branches merge into `main` and back into `develop`; hotfixes start from `main`
and are merged back into both protected branches.

## License

Licensed under the [Apache License 2.0](LICENSE).
