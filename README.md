# TamaMCP

Tama-focused MCP `2026-07-28` server primitives for Elixir applications.

`TamaMCP` exists so Tama can implement the current MCP server contract without
depending on a general-purpose MCP framework or carrying compatibility code for
older protocol eras. It will provide a small server and tool DSL, stateless
Streamable HTTP transport, task execution, task notifications, authorization
hooks, and adapter behaviours for application-owned persistence and clustered
delivery.

The package is pre-release. Only the protocol and extension identifiers are
implemented in the repository foundation; the runtime API described in the WIP
specification is not yet available.

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
  MCP Tasks, subscription streams, protocol responses, and adapter behaviours.
- `TamaOAuth` owns reusable OAuth and protected-resource protocol mechanics.
- Tama owns identities, authorization policy, rate limits, Ecto persistence,
  durable execution, task transitions, and graph results.
- Tama Link owns client compatibility, OAuth client behavior, local
  correlation, polling recovery, and downstream progress presentation.

See [the WIP specification](https://github.com/kritama/tama-mcp/blob/develop/wip/tama-mcp-specification.md)
for the complete contract and implementation acceptance criteria.

## Deliberate scope

The initial package supports:

- MCP protocol version `2026-07-28` only;
- server-side stateless Streamable HTTP;
- `server/discover`, `tools/list`, and `tools/call`;
- the `io.modelcontextprotocol/tasks` extension;
- `tasks/get`, `tasks/update`, and `tasks/cancel`;
- `subscriptions/listen` and task-status notifications; and
- application-supplied authorization, task-store, and notification-bus
  adapters.

It does not provide an MCP client, STDIO transport, legacy initialization or
session support, prompts, resources, sampling, elicitation, MCP Apps UI,
database persistence, or a web server.

## Dependencies

- `jason` encodes and decodes JSON.
- `plug` provides the framework-neutral HTTP boundary.
- `jsonschex` validates JSON Schema Draft 2020-12 tool contracts.
- `tama_oauth` supplies OAuth and protected-resource protocol primitives.
- `telemetry` exposes bounded runtime instrumentation.

The library deliberately does not depend on Phoenix, Ecto, Bandit, Cowboy,
Anubis MCP, or ex_mcp.

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
