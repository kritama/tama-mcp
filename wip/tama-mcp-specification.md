# TamaMCP 2026 Server Runtime Specification

Status: implementation handoff

This document is the authoritative design contract for the first complete
`tama_mcp` implementation. It defines the package boundary, supported protocol,
public API direction, HTTP behavior, tool execution, durable tasks,
notifications, OAuth composition, security, telemetry, testing, migration, and
release acceptance.

## 1. Decision

TamaMCP is a focused Elixir server library for MCP protocol version
`2026-07-28`. It will not wrap, fork, or depend on Anubis MCP or ex_mcp, and it
will not implement any older MCP protocol era.

Tama Link is the compatibility boundary between coding clients and Tama. It may
speak whatever downstream protocol a supported client requires, but its
upstream Tama adapter must speak MCP `2026-07-28`. Tama therefore does not need
legacy initialization, protocol sessions, `Mcp-Session-Id`, legacy task
augmentation, or client-specific fallbacks.

The package is intentionally not a general MCP SDK. Supporting exactly what
Tama needs is a product constraint, not an incomplete first approximation of a
broad framework.

## 2. Normative sources

Implementation must be checked against the published `2026-07-28` MCP
specification and the Tasks extension identified by
`io.modelcontextprotocol/tasks`.

Normative behavior comes from the protocol schemas and specifications, not
from the behavior of Anubis MCP, ex_mcp, Tama Link, or any single client SDK.
When prose and generated schema appear to disagree, record the exact upstream
revision and add a compatibility test before choosing behavior.

The library must pin protocol fixtures used by tests so an upstream draft
change cannot silently alter a released package. Updating those fixtures is a
reviewed protocol change and requires a changelog entry.

## 3. Goals

TamaMCP must:

1. implement MCP `2026-07-28` server semantics only;
2. provide an idiomatic compile-time server and tool DSL;
3. expose a Plug-compatible stateless Streamable HTTP endpoint;
4. validate JSON-RPC envelopes, protocol metadata, standard headers, tool
   inputs, and tool outputs at the boundary;
5. expose application identity and authorization data through a stable request
   context without leaking transport internals;
6. implement server-directed durable task creation and the Tasks extension;
7. expose task state through polling and task-status notifications;
8. provide adapter behaviours for authorization, durable task storage, clocks,
   identifiers, and clustered notification delivery;
9. remain independent of Phoenix, Ecto, any specific web server, and Tama
   application modules;
10. produce deterministic machine responses and bounded, redacted telemetry;
11. fail closed for unsupported protocol versions, missing capabilities,
    invalid headers, invalid schemas, and unauthorized task access; and
12. provide a reusable conformance suite that Tama can run against its composed
    server.

## 4. Non-goals

The initial package does not provide:

- MCP versions `2025-11-25` or earlier;
- `initialize`, `notifications/initialized`, or protocol session state;
- `Mcp-Session-Id`, session registries, sticky routing, or shared session
  persistence;
- the legacy HTTP GET notification stream, HTTP DELETE session termination, or
  resumable SSE event storage;
- `tasks/result`, `tasks/list`, or client-requested task augmentation;
- an MCP client or upstream adapter for Tama Link;
- STDIO, WebSocket, or legacy SSE transports;
- prompts, resources, completions, roots, sampling, elicitation, logging, or
  MCP Apps UI in the first release;
- Phoenix endpoints, Ecto schemas, migrations, repositories, queues, or graph
  execution;
- application users, actors, tenants, scopes, rate limits, origins, consent,
  token storage, or secret storage; or
- compatibility behavior selected from a client product name or user agent.

Adding one of these features requires an explicit scope decision. It must not
enter the package merely because another SDK implements it.

## 5. Topology and ownership

```text
downstream MCP client
        |
        | client-compatible submit / await surface
        v
    Tama Link
        |
        | MCP 2026-07-28 + Tasks + subscriptions
        v
      Tama HTTP endpoint
        |
        | TamaMCP Plug and runtime
        v
Tama authorization, durable task rows, PubSub, graph execution
```

| Component | Owns |
| --- | --- |
| TamaMCP | MCP wire protocol, JSON-RPC, schemas, DSL, request context, task protocol state, subscription streams, adapter behaviours |
| TamaOAuth | OAuth and protected-resource protocol mechanics |
| Tama | issuer/resource policy, principals, scopes, origins, rate limits, Ecto persistence, graph execution, durable results |
| Tama Link | OAuth client behavior, upstream task correlation, polling recovery, downstream compatibility and progress presentation |

TamaMCP may depend on TamaOAuth. TamaOAuth must not depend on TamaMCP. Neither
library may depend on the Tama application or Tama Link.

## 6. Package structure

The intended module layout is:

```text
TamaMCP
TamaMCP.Authorization
TamaMCP.Clock
TamaMCP.Context
TamaMCP.Error
TamaMCP.Identifier
TamaMCP.NotificationBus
TamaMCP.Protocol
TamaMCP.Response
TamaMCP.Server
TamaMCP.Task
TamaMCP.TaskStore
TamaMCP.Tool
TamaMCP.Transport.StreamableHTTP.Plug
```

Protocol codecs and dispatch implementation belong under internal modules and
must not become public application contracts. The public API must use
TamaMCP-owned values rather than maps shaped like a third-party library.

## 7. Server DSL

An application server should be declarative and compile its tool catalog at
build time:

```elixir
defmodule Example.Server do
  use TamaMCP.Server,
    name: "example",
    version: "1.0.0",
    instructions: "Use the available tools for bounded example work."

  tool Example.Tools.Inspect, name: "inspect"
  tool Example.Tools.Execute, name: "execute"
end
```

`use TamaMCP.Server` must validate required identity fields and reject duplicate
tool names during compilation. The catalog must have a stable deterministic
order independent of module compilation order.

The server DSL must expose only `2026-07-28`; applications cannot widen the
supported protocol list. The package version and application server version are
separate values.

## 8. Tool DSL and schemas

A tool should declare metadata, task policy, input schema, output schema, and a
single execution callback:

```elixir
defmodule Example.Tools.Execute do
  use TamaMCP.Tool,
    task: :required,
    scopes: ["example.execute"]

  input_schema do
    field :identifier, :string, required: true, min_length: 1
    field :content, :string, required: true, min_length: 1
  end

  output_schema do
    field :status, {:enum, ["completed", "failed"]}, required: true
  end

  @impl true
  def call(input, context) do
    # Application operation
  end
end
```

The exact callback return types must be finalized with the first tool runtime,
but they must distinguish synchronous completion, durable task creation, tool
errors, and protocol errors without raising for expected input or domain
failures.

The DSL is an ergonomic builder for ordinary JSON Schema Draft 2020-12 maps.
Every tool must also support a raw-schema escape hatch so the DSL cannot block
use of a valid schema keyword. Generated schemas must default object contracts
to `additionalProperties: false` unless the tool explicitly opts into unknown
keys.

Schemas must be compiled once and reused. Invalid schemas fail during server
startup or compilation rather than on the first request. Runtime input and
structured output are validated using `jsonschex`.

Tool annotations must be declared explicitly and emitted unchanged after
validation. TamaMCP must not infer destructive, idempotent, read-only, or
open-world behavior from a module or function name.

## 9. Request context

Every tool call receives `%TamaMCP.Context{}` containing only normalized,
request-scoped data:

- JSON-RPC request identifier;
- protocol version;
- MCP method and optional MCP name;
- client information and declared client capabilities;
- authenticated application principal;
- normalized claims and granted scopes;
- bounded request headers selected by the transport;
- remote address supplied by the host application;
- task identifier when executing as a durable task; and
- application assigns supplied by configured adapters.

Context must survive transfer into asynchronous task execution. This is a
security invariant: authorization claims, scopes, request identity, and the
caller binding must not disappear when a tool becomes a task.

Arbitrary Plug assigns and all raw request headers must not be copied into the
context. Applications explicitly select safe values.

## 10. HTTP transport

The first transport is a Plug implementing stateless Streamable HTTP for MCP
`2026-07-28`.

Each request is independent. The transport must not create a protocol session,
require affinity, persist a frame between requests, or emit
`Mcp-Session-Id`.

The endpoint accepts HTTP POST for supported JSON-RPC requests. It must enforce:

- bounded body size and read timeout;
- UTF-8 JSON;
- supported content and accept types;
- a single JSON-RPC message per request unless the normative schema later
  requires otherwise;
- `MCP-Protocol-Version: 2026-07-28`;
- required `Mcp-Method` and conditional `Mcp-Name` headers;
- exact agreement between standard headers and the JSON-RPC body;
- required per-request protocol metadata and client capabilities;
- request identifier type and JSON-RPC version; and
- an authorization decision on every request.

An unsupported or absent protocol version fails closed with the specified HTTP
status and JSON-RPC error. TamaMCP must never downgrade the request.

The host application remains responsible for its router, TLS termination,
trusted proxies, allowed origins, pre-authentication rate limits, endpoint
enablement, and web-server choice.

## 11. Discovery

`server/discover` advertises:

- supported version `2026-07-28` only;
- server name, version, and optional instructions;
- tools capability;
- subscriptions supported by the server; and
- the Tasks extension when a task store is configured.

Capabilities must describe the configured server truthfully. TamaMCP must not
advertise tasks or task notifications when the required adapters are absent.

Discovery output must be deterministic and suitable for protocol conformance
fixtures.

## 12. Tool listing and calling

`tools/list` returns a deterministically ordered catalog. Pagination is added
only if Tama's catalog grows beyond an explicitly configured bound.

`tools/call` must:

1. resolve one registered tool by exact name;
2. verify required client capabilities;
3. verify authorization and required scopes;
4. validate input against the compiled schema;
5. construct the normalized context;
6. execute synchronously or create a task according to the tool policy;
7. validate successful structured output; and
8. encode a specification-compliant result or JSON-RPC error.

Tool names are public compatibility APIs. Renaming or removing a tool is a
breaking package/application contract change.

## 13. Tasks extension

The package implements `io.modelcontextprotocol/tasks` for tool calls.

Task creation is server-directed. A client must declare the extension in its
per-request capabilities. A tool with `task: :required` returns a missing
required capability error when the client does not declare it; it must not
block until completion or silently execute synchronously.

The initial Tama App `message` tool is task-required. Bounded System inspection
tools are synchronous unless explicitly changed.

The supported methods are:

- `tasks/get` for the current detailed task state;
- `tasks/update` for responses to a task in `input_required`; and
- `tasks/cancel` for cooperative cancellation intent.

The package does not implement `tasks/result` or `tasks/list`.

### 13.1 Task identity and authorization

Task IDs must be opaque, globally unique, and generated with sufficient entropy
to prevent enumeration. They must not encode a database identifier, actor,
tenant, session, or timestamp in a reversible form.

There is no protocol session in 2026. Task lookup must therefore never use
`session_id`. Every task-related request is authenticated independently and the
task store must bind access to an application-defined owner key derived from the
validated principal and resource.

Unauthorized and nonexistent tasks should produce the same externally visible
error wherever the specification permits, preventing task-existence probing.

### 13.2 Task states

The protocol states are:

- `working`;
- `input_required`;
- `completed`;
- `failed`; and
- `cancelled`.

The task store must preserve timestamps, TTL, suggested polling interval,
status message, original request correlation, and the state-specific result,
error, or input requests required by the protocol.

A tool result with `isError: true` is still a completed tool call under the
Tasks extension. JSON-RPC execution failure uses task status `failed`. The
library must not conflate these two failure channels.

Terminal transitions are idempotent. Concurrent completion, cancellation,
expiry, and notification publication must not corrupt or regress a terminal
state.

### 13.3 Task store behaviour

`TamaMCP.TaskStore` defines the protocol-facing persistence contract. It must
support atomic creation, authorized lookup, compare-and-update transitions,
and cooperative cancellation intent.

The behaviour must not mention Ecto or require an in-memory worker to retrieve
a durable result. Tama will implement the behaviour with its database and
transaction boundaries.

Task-store errors must be bounded package values. Raw changesets, database
exceptions, or adapter-specific structs must never enter JSON responses.

## 14. Notifications and subscriptions

Task status notifications are part of the first production release.

A client opens a long-lived `subscriptions/listen` POST and requests specific
task IDs. The first stream message is
`notifications/subscriptions/acknowledged`, containing only the authorized
subset the server agreed to deliver.

Each subsequent `notifications/tasks` message carries the complete detailed
task state that `tasks/get` would return at that moment. The client may treat
notifications as its normal update path, but the durable task store remains the
source of truth.

The server must authenticate the listen request and authorize every requested
task ID. Authorization must be rechecked when appropriate for long-lived
streams and must fail closed when credentials expire or policy changes.

Tama publishes a notification only after the corresponding durable task
transition commits. Publication failure must not roll back or reinterpret the
task transition. On reconnect, Tama Link calls `tasks/get` to reconcile state,
then opens a new subscription.

There is no notification replay guarantee in v0.1. Correctness must never
depend on observing every notification.

The Tasks extension does not permit `notifications/progress` or
`notifications/message` as task notifications. Human-readable progress may use
the task `statusMessage`. Richer structured progress, if required, must use a
reviewed Tama-namespaced `_meta` field or a separately specified application
contract; it must not masquerade as a standard MCP field.

### 14.1 Notification bus behaviour

`TamaMCP.NotificationBus` decouples task commits from active subscription
streams. It must support:

- subscribing a process to an authorized set of task IDs;
- removing subscriptions when a stream closes;
- publishing a committed detailed task snapshot;
- bounded subscriber metadata; and
- operation across multiple application nodes when the adapter provides it.

The default adapter may be process-local for library tests. Tama will provide a
cluster-aware Phoenix PubSub adapter. TamaMCP itself must not depend on Phoenix.

Slow or disconnected subscribers must not block task transitions or exhaust an
unbounded mailbox. The stream applies bounded buffering and closes lagging
subscribers so they can recover through `tasks/get`.

## 15. Authorization and TamaOAuth

TamaMCP composes TamaOAuth rather than reimplementing OAuth.

The library defines an authorization behaviour invoked for every request. A
configured adapter returns a normalized principal, claims, scopes, and owner
key, or a bounded authorization error. The library uses those values for tool
visibility, scope enforcement, task ownership, subscriptions, and context
construction.

Tama owns:

- authorization server and protected-resource identities;
- allowed signing algorithms and key resolution;
- authenticated introspection configuration;
- lifecycle enablement;
- allowed origins and rate limits;
- mapping validated subjects to actors; and
- credential and signing-key custody.

TamaMCP must not accept identity from an unvalidated request field. It derives
authorization only from the configured adapter result.

Protected-resource metadata remains a Tama web route composed with TamaOAuth.
It is not hidden inside the MCP transport Plug.

## 16. Responses and errors

`TamaMCP.Response` represents a tool response independently of JSON encoding.
It supports content blocks, structured content, `isError`, and validated
metadata needed by Tama.

`TamaMCP.Error` represents JSON-RPC and package errors with a numeric code,
safe message, and JSON-safe data. It must include constructors for standard
parse, invalid request, method not found, invalid params, internal error,
unsupported protocol version, header mismatch, and missing capability errors.

Expected client, authorization, task-state, and domain failures return values;
they do not raise. Unexpected exceptions are captured at the outer runtime
boundary, logged with redaction, and returned as a generic internal error.

All encoded maps must be JSON-safe. Adapter structs, exceptions, changesets,
PIDs, references, and stack traces must never be serialized to clients.

## 17. Configuration

Server configuration is explicit and validated once. It includes:

- server identity and instructions;
- registered tools;
- request and stream timeouts;
- maximum body and schema sizes;
- authorization adapter and options;
- task store and options;
- notification bus and options;
- clock and identifier adapters; and
- telemetry prefix and safe metadata callback.

The library must not read Tama environment variables directly. Applications
load environment configuration and pass validated values to the server.

Production defaults must be bounded. Unlimited bodies, schemas, task TTLs,
subscription counts, buffers, or timeouts are not permitted.

## 18. Telemetry and logging

The package emits `:telemetry` events for:

- request start, stop, and exception;
- authorization success and failure;
- tool validation and execution;
- task creation and transition;
- task lookup and cancellation;
- subscription open, acknowledgement, close, and overflow; and
- notification publish and delivery failure.

Telemetry metadata must be bounded and safe by construction. It may include
server, method, tool name, protocol version, status, and classified reason. It
must not include bearer tokens, raw authorization headers, tool arguments,
structured results, full claims, signing keys, or arbitrary adapter errors.

The library uses `Logger` only for unexpected runtime failures and lifecycle
events that cannot be expressed adequately through telemetry. Applications own
log routing and filtering.

## 19. Testing and conformance

The package test suite must include:

1. JSON-RPC envelope and error fixtures;
2. `server/discover` capability fixtures;
3. standard header/body agreement and mismatch cases;
4. deterministic `tools/list` ordering;
5. JSON Schema Draft 2020-12 input and output validation;
6. synchronous tool success and error cases;
7. missing tool, scope, capability, and authorization cases;
8. server-directed task creation;
9. every valid and invalid task transition;
10. owner-bound `tasks/get`, `tasks/update`, and `tasks/cancel`;
11. process-restart retrieval without an in-memory worker;
12. subscription acknowledgement and task notification shapes;
13. publish-after-commit adapter behavior;
14. reconnect reconciliation through `tasks/get`;
15. slow-subscriber overflow and cleanup;
16. concurrent completion/cancellation/expiry races;
17. bounded input, metadata, error, and stream behavior;
18. telemetry redaction; and
19. protocol fixtures checked against pinned official schemas.

Tama must be able to import a package-provided contract test module and run the
same transport and adapter expectations against its real composed server.

Live acceptance is required with Tama Link using the official Go SDK release
that supports MCP `2026-07-28`. Acceptance must cover OAuth, task creation,
notifications, polling recovery, terminal success, terminal failure, restart,
and expired credentials.

## 20. Migration and implementation phases

### Phase 0: repository foundation

- Mix library, toolchain pin, dependencies, CI, documentation, and Git Flow;
- protocol and Tasks extension constants; and
- authoritative WIP specification.

### Phase 1: protocol core and synchronous tools

- context, response, and error values;
- server and tool DSL;
- Draft 2020-12 schema compilation and validation;
- stateless HTTP Plug, headers, JSON-RPC, and discovery; and
- synchronous System MCP tools and contract tests.

### Phase 2: durable Tasks extension

- task value and state transitions;
- task-store behaviour;
- server-directed task creation;
- `tasks/get`, `tasks/update`, and `tasks/cancel`; and
- conversion of Tama persistence away from Anubis task structs and
  session-scoped identity.

### Phase 3: subscriptions and task notifications

- notification-bus behaviour;
- `subscriptions/listen` stream and acknowledgement;
- authorized `notifications/tasks` delivery;
- Phoenix PubSub adapter in Tama; and
- reconnect, overflow, and multi-node tests.

### Phase 4: Tama integration

- migrate `/mcp/system` first as the synchronous canary;
- migrate `/mcp/app` with task-required `message`;
- preserve Tama OAuth, rate-limit, recipient, submission, and graph ownership;
- run focused MCP and full Tama precommit suites; and
- retain the Anubis endpoint only until the new path passes acceptance.

### Phase 5: Tama Link acceptance and dependency removal

- implement Tama Link's 2026-only upstream adapter;
- subscribe to task updates and retain `tasks/get` recovery;
- complete Codex, OpenCode, and inspector acceptance;
- remove Anubis from Tama and delete compatibility projections; and
- publish the supported TamaMCP, Tama, Tama Link, and protocol versions.

The old and new runtimes must not both mutate the same task unless an explicit
migration test proves safe ownership. A temporary route or configuration flag
may select one implementation during acceptance.

## 21. Acceptance criteria

The first production release is complete only when:

1. the package has no Anubis MCP or ex_mcp dependency;
2. only protocol `2026-07-28` is accepted and advertised;
3. `initialize`, `Mcp-Session-Id`, `tasks/result`, and `tasks/list` are rejected;
4. synchronous System tools pass the shared contract suite;
5. the App `message` tool requires the Tasks extension;
6. task state is durable and independent of a process or HTTP connection;
7. task access is bound to the validated caller on every request;
8. `tasks/get`, `tasks/update`, and cooperative cancellation conform to the
   pinned protocol fixtures;
9. `subscriptions/listen` acknowledges only authorized task IDs;
10. committed task transitions publish complete `notifications/tasks`
    snapshots;
11. dropped notifications and stream reconnects recover through `tasks/get`;
12. terminal results survive Tama and Tama Link restarts;
13. no credential, claim, tool input, result, or secret leaks through logs,
    telemetry, errors, or test snapshots;
14. multi-node notification tests and task-transition race tests pass;
15. Tama's focused MCP suite and full `mix precommit` pass;
16. Tama Link completes live OAuth, notification, polling-recovery, success,
    and failure flows; and
17. package documentation, Dialyzer, Credo, tests, and Hex build pass.

## 22. Dependency policy

Runtime dependencies are intentionally small:

- `jason` for JSON;
- `plug` for the HTTP boundary;
- `jsonschex` for Draft 2020-12 schema validation;
- `tama_oauth` for reusable authorization protocol mechanics; and
- `telemetry` for instrumentation.

TamaMCP must not add a web server, database, queue, Phoenix, or another MCP
implementation as a transitive runtime dependency. New dependencies require an
ownership, maintenance, security, and release assessment.

## 23. Branching and delivery

The repository uses Git Flow:

- `develop` is the integration and default branch;
- `main` contains production releases;
- `feature/*` and `fix/*` start from and merge into `develop`;
- `release/*` starts from `develop`, merges into `main`, then back into
  `develop`; and
- `hotfix/*` starts from `main` and merges into both `main` and `develop`.

Commits use Conventional Commits. Protocol fixtures, public tool schemas,
public modules, task semantics, and notification shapes are reviewed as public
API changes.
