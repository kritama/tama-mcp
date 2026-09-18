# TamaMCP

Tama-focused MCP `2026-07-28` server primitives for Elixir applications.

`TamaMCP` exists so Tama can implement the current MCP server contract without
depending on a general-purpose MCP framework or carrying compatibility code for
older protocol eras.

The package is pre-release. Phase 1 provides the server and tool DSL, stateless
Streamable HTTP transport, per-request authorization, discovery, deterministic
tool listing, synchronous tool execution, schema validation, bounded telemetry,
and reusable protocol conformance helpers. Phase 2 adds durable task contracts,
server-directed task creation, task polling and mutation methods, and the full
task conformance matrix. Phase 3 adds bounded subscription streams, authorized
task notifications, stream reauthorization, and a process-local reference
notification adapter. Tama's application-owned persistence, runner, and
clustered notification adapters remain a separate integration phase.

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
  protocol responses, task values and transitions, durable task adapter
  contracts, cache keys and compiled validator artifacts, subscription streams,
  and the notification adapter contract.
- `TamaOAuth` owns reusable OAuth and protected-resource protocol mechanics.
- Tama owns identities, authorization policy, rate limits, the validator cache
  engine, Ecto persistence, durable execution, task transitions, and graph
  results.
- Tama Link owns client compatibility, OAuth client behavior, local
  correlation, polling recovery, and downstream progress presentation.

See [the WIP specification](https://github.com/kritama/tama-mcp/blob/develop/wip/tama-mcp-specification.md)
for the complete contract and implementation acceptance criteria.

## Deliberate scope

The implemented package supports:

- MCP protocol version `2026-07-28` only;
- server-side stateless Streamable HTTP;
- `server/discover`, `tools/list`, `tools/call`, `tasks/get`, `tasks/update`,
  `tasks/cancel`, and `subscriptions/listen`;
- authorization-aware tool visibility and scope enforcement;
- application-supplied authorization decisions and safe context values;
- server-directed durable execution for task-required tools and explicit
  application selection for task-optional tools;
- owner-bound task lookup, input-response submission, and cooperative
  cancellation through application adapters;
- bounded request execution, successful results, errors, headers, subscription
  buffers, and telemetry; and
- reusable conformance validation against the vendored core and Tasks schemas.

It does not provide an MCP client, STDIO transport, legacy initialization or
session support, prompts, resources, sampling, elicitation, MCP Apps UI,
database persistence, a clustered notification adapter, or a web server. Task
support is advertised only when a complete durable store and runner are
configured. Task polling remains available without a notification adapter; a
listen request then acknowledges an empty task set.

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

Schema fields support primitives, enums, arrays, open objects, nullable
composition, and raw Draft 2020-12 fragments. Use an `object` declaration when
the nested object's fields are known; declared objects reject unknown keys by
default:

```elixir
input_schema do
  object :thread, required: true do
    field(:identifier, :string, required: true, min_length: 1)
  end
end
```

Use named variants when structured tool results have multiple root object
shapes. Variants preserve declaration order in `anyOf`, require unique names,
and independently default to `additionalProperties: false`:

```elixir
output_schema do
  variant :success do
    field(:schema_version, :string, required: true)
    field(:result, {:nullable, :object}, required: true)
    field(:messages, {:array, :object}, required: true)
  end

  variant :tool_error do
    field(:schema_version, :string, required: true)
    field(:error, :object, required: true)
  end
end
```

Nested objects and variants may set `allow_unknown_keys: true`. Output variant
blocks contain two to sixteen variants and cannot be mixed with root field or
object declarations. Schema construction and validation artifacts remain
compile-time only; applications do not need Ecto or another runtime type
system.

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
and explicit application assigns. Authentication runs before transport
validation on every HTTP request. Long-lived streams additionally use
`c:TamaMCP.Authorization.reauthorize/3`; adapters may register an immediate
policy signal with `c:TamaMCP.Authorization.register_invalidation/3`.

## Durable tasks

A tool declares `task: :required` or `task: :optional` in `use TamaMCP.Tool`.
Task-capable transports configure both application-owned adapters:

```elixir
forward "/mcp", TamaMCP.Transport.StreamableHTTP.Plug,
  server: Example.Server,
  authorization: Example.Authorization,
  cache: Example.Cache,
  task_store: Example.TaskStore,
  task_store_options: [repo: Example.Repo],
  task_runner: Example.TaskRunner,
  task_runner_options: [supervisor: Example.TaskSupervisor]
```

The runner's `c:TamaMCP.Task.Runner.start/4` callback is the atomic durability
boundary: before returning a task handle it must persist a `TamaMCP.Task` and
accept its execution handoff. `TamaMCP.Task.Store` owns owner-bound lookup,
compare-and-update transitions, atomic one-time acceptance of outstanding input
responses, and durable idempotent cooperative-cancellation intent. Store
notifications and worker signals occur only after their corresponding state
commit; no-op input and cancellation replays do not signal workers. The default
UTC clock and opaque UUID generator can be replaced for application or test
needs. Optional tools remain synchronous unless `:task_selector` explicitly
selects durable execution; task-disabled tools do not consult the selector.

The cache adapter implements `TamaMCP.Cache`. TamaMCP compiles tool validators
while compiling each tool module, precompiles its fixed protocol validators,
embeds their serialized artifacts, and owns versioned cache keys and
restoration. The host adapter owns storage, concurrency, expiry, distribution,
and any additional serialization required by its cache engine. Cached validator
values are opaque Erlang terms and may contain functions.

## Task subscriptions

Configure a `TamaMCP.Notification` alongside the durable task adapters to
accept task IDs on `subscriptions/listen`. The package includes
`TamaMCP.Notification.Local` for tests and single-node development:

```elixir
children = [
  {TamaMCP.Notification.Local, name: Example.Notification}
]

forward "/mcp", TamaMCP.Transport.StreamableHTTP.Plug,
  server: Example.Server,
  authorization: Example.Authorization,
  cache: Example.Cache,
  task_store: Example.TaskStore,
  task_runner: Example.TaskRunner,
  notification: TamaMCP.Notification.Local,
  notification_options: [server: Example.Notification]
```

After a visible task transition commits, application-owned store or runner
code calls `TamaMCP.Notification.publish_committed/2` with the committed
task and the task-store options supplied by TamaMCP. Publication is a lossy
hint: failure never rolls back the task. Streams reauthorize before delivery
and while idle, close at credential expiry or their configured lifetime, and
close slow consumers when their bounded queue overflows. Clients reconcile
every interruption with owner-bound `tasks/get`; Phase 3 provides no replay or
resumable SSE log.

## Conformance

`TamaMCP.Conformance` validates complete core and Tasks requests and responses
against the immutable upstream schemas in
`priv/protocol/2026-07-28`. Its bundled wire fixtures exercise discovery,
authorization-aware listing, synchronous and task creation results, task
lookup/update/cancellation, tool errors, malformed metadata, scope denial,
standard and schema-declared header agreement, unsupported versions, explicit
null output, output-schema failure, and rejection of protocol sessions. The
task set contains 23 HTTP fixtures and 11 static task-profile fixtures covering
all five states, invalid cross-state payloads, recovery, capability and owner
denials, cancellation races, and unsupported task methods. Successful task
responses validate the complete JSON-RPC envelope independently from the nested
Tasks result.

The subscription set adds seven deterministic JSON/SSE fixtures for
acknowledgement, authorized delivery, reconnect, capability denial, credential
expiry, policy invalidation, and overflow. `TamaMCP.Conformance` compares
ordered SSE events and validates each event against the pinned core and Tasks
schemas.

Host applications can call `TamaMCP.Conformance.validate/3` for individual
values, `TamaMCP.Conformance.validate_schema_fixtures/3` for the static task
profile, or `TamaMCP.Conformance.run/3` with a request callback, their cache
adapter, and an application fixture set. Task HTTP fixtures may include bounded
setup metadata that an application contract adapter uses to prepare the
required durable state before issuing the wire request.

Application adapters can run the same acceptance harnesses TamaMCP uses for
its own reference adapters: `TamaMCP.Conformance.Store.check/2` verifies the
durable task-store contract, and `TamaMCP.Conformance.Notification.check/2`
verifies the notification delivery contract. Each harness is callable from a
plain ExUnit suite and raises `TamaMCP.Conformance.Failure` naming the
violated callback and behaviour rule.

## Dependencies

- `jason` encodes and decodes JSON.
- `plug` provides the framework-neutral HTTP boundary.
- `jsonschex` validates JSON Schema Draft 2020-12 tool and protocol contracts.
- `tama_oauth` supplies OAuth and protected-resource protocol primitives.
- `telemetry` exposes bounded runtime instrumentation.

The library deliberately does not depend on Phoenix, Ecto, Bandit, Cowboy,
Anubis MCP, ex_mcp, or a validator cache engine.

## Installation

Add the published Hex package to your dependencies:

```elixir
def deps do
  [
    {:tama_mcp, "~> 0.1.1"}
  ]
end
```

For local development against a sibling checkout of this repository, a path
dependency can be used instead; it is not a supported way to consume the
package:

```elixir
def deps do
  [
    {:tama_mcp, path: "../tama-mcp"}
  ]
end
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
