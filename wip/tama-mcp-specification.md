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

Implementation must be checked against these immutable upstream revisions:

| Contract | Immutable revision | Required artifacts |
| --- | --- | --- |
| MCP core `2026-07-28` | [`modelcontextprotocol/modelcontextprotocol@5f5440bb26a62e2cf3440b92da5a667efa03b267`](https://github.com/modelcontextprotocol/modelcontextprotocol/tree/5f5440bb26a62e2cf3440b92da5a667efa03b267) | `docs/specification/2026-07-28`, `schema/2026-07-28/schema.json`, and `schema/2026-07-28/examples` |
| Tasks extension `io.modelcontextprotocol/tasks` | [`modelcontextprotocol/ext-tasks@0d0a6bd4c258b35caa3c810a1dd506cf105b1501`](https://github.com/modelcontextprotocol/ext-tasks/tree/0d0a6bd4c258b35caa3c810a1dd506cf105b1501) | `specification/2026-07-28/tasks.md` and `schema/2026-07-28/schema.json` |

The MCP core revision is the commit addressed by the upstream `2026-07-28`
release tag. The Tasks revision is the commit that locked its versioned
`2026-07-28` specification and schema. Implementers must not use an upstream
`main`, `latest`, `draft`, overview page, or SDK implementation as a normative
substitute for these revisions.

Normative behavior comes from the protocol schemas and specifications, not
from the behavior of Anubis MCP, ex_mcp, Tama Link, or any single client SDK.
When prose and generated schema appear to disagree, record the exact upstream
revision and add a compatibility test before choosing behavior.

The library must vendor the required schemas and example-derived fixtures under
`priv/protocol/2026-07-28/core` and `priv/protocol/2026-07-28/tasks`. A manifest
must record the repository, full commit SHA, source path, and SHA-256 checksum
for every vendored artifact. Tests must read only the vendored copies. An
upstream change therefore cannot silently alter a released package.

The precedence order is:

1. the pinned core or Tasks schema for wire shapes and constants;
2. the corresponding pinned versioned prose for behavioral requirements;
3. this document for the narrower Tama product profile; and
4. pinned examples for conformance fixtures.

An SDK, unversioned documentation page, or live implementation is evidence for
interoperability but is not normative. If pinned schema and pinned prose appear
to disagree, the implementation must stop, record the conflict, choose one
behavior explicitly in this document, and add both positive and negative
fixtures. Updating a pin is a reviewed protocol change and requires a changelog
entry.

The following protocol errors are fixed by the pinned core schema:

| Condition | HTTP status | JSON-RPC code |
| --- | --- | --- |
| missing, malformed, or body-mismatched standard request header | `400 Bad Request` | `-32020` (`HeaderMismatch`) |
| required client capability was not declared for this request | `400 Bad Request` | `-32021` (`Missing Required Client Capability`) |
| requested protocol version is unsupported | `400 Bad Request` | `-32022` (`Unsupported Protocol Version`) |
| recognized endpoint but unsupported JSON-RPC method | `404 Not Found` | `-32601` (`Method not found`) |

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
TamaMCP.TaskRunner
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

  @impl TamaMCP.Tool
  def call(input, context) do
    {:ok, TamaMCP.Response.success(structured_content: %{"status" => "completed"})}
  end
end
```

`use TamaMCP.Tool` is a compile-time macro. It imports the schema builder,
accumulates validated metadata in module attributes, and generates stable
introspection functions for the tool definition, input schema, output schema,
annotations, scopes, and task policy. The generated values are ordinary maps
and TamaMCP structs; the macro must not require Ecto or emit a second runtime
type system.

The tool callback contract is:

```elixir
@callback call(input :: map(), context :: TamaMCP.Context.t()) ::
            {:ok, TamaMCP.Response.t()}
            | {:error, TamaMCP.Error.t()}
```

`{:ok, Response.success(...)}` represents a successful tool result.
`{:ok, Response.tool_error(...)}` represents a completed tool call whose
`CallToolResult.isError` is `true`; this remains a completed task when executed
asynchronously. `{:error, Error.t()}` represents a JSON-RPC execution failure
and maps an asynchronous task to `failed`. Expected tool and domain failures do
not raise. Unexpected exceptions are caught by the outer runtime boundary and
converted to a redacted internal error.

Durable task creation is not a tool callback return variant. The runtime selects
synchronous or task execution from the tool's task policy and the capabilities
on the current request:

- `:disabled` always executes synchronously;
- `:required` creates a task when the Tasks capability is present and returns
  `-32021` when it is absent; and
- `:optional` lets a configured server policy choose a task when the capability
  is present, and otherwise executes synchronously.

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

### 10.1 Common HTTP envelope

Every request example below uses:

~~~http
POST /mcp/app HTTP/1.1
Authorization: Bearer <access-token>
Content-Type: application/json
Accept: application/json, text/event-stream
MCP-Protocol-Version: 2026-07-28
Mcp-Method: <body method>
~~~

`Mcp-Name` is additionally required for `tools/call`, where it equals
`params.name`, and for `tasks/get`, `tasks/update`, and `tasks/cancel`, where it
equals `params.taskId`. All standard header values must agree exactly with
their body sources after applying the pinned Base64 sentinel decoding rules.

Every request `params` object includes:

~~~json
"_meta": {
  "io.modelcontextprotocol/protocolVersion": "2026-07-28",
  "io.modelcontextprotocol/clientInfo": {
    "name": "tama-link",
    "version": "0.1.0"
  },
  "io.modelcontextprotocol/clientCapabilities": {
    "extensions": {
      "io.modelcontextprotocol/tasks": {}
    }
  }
}
~~~

Capabilities are per request. The server must not infer them from discovery or
an earlier request. Examples below use application JSON responses except
`subscriptions/listen`, which always opens an SSE stream.

### 10.2 `server/discover`

Request headers set `Mcp-Method: server/discover` and omit `Mcp-Name`:

~~~json
{
  "jsonrpc": "2.0",
  "id": "discover-1",
  "method": "server/discover",
  "params": {
    "_meta": {
      "io.modelcontextprotocol/protocolVersion": "2026-07-28",
      "io.modelcontextprotocol/clientInfo": {
        "name": "tama-link",
        "version": "0.1.0"
      },
      "io.modelcontextprotocol/clientCapabilities": {}
    }
  }
}
~~~

~~~http
HTTP/1.1 200 OK
Content-Type: application/json

{
  "jsonrpc": "2.0",
  "id": "discover-1",
  "result": {
    "resultType": "complete",
    "supportedVersions": ["2026-07-28"],
    "capabilities": {
      "tools": {},
      "extensions": {
        "io.modelcontextprotocol/tasks": {}
      }
    },
    "_meta": {
      "io.modelcontextprotocol/serverInfo": {
        "name": "tama",
        "version": "1.0.0"
      }
    },
    "ttlMs": 0,
    "cacheScope": "private"
  }
}
~~~

The Tasks extension is omitted when the task store or task runner is not
configured. TamaMCP uses the conservative discovery cache defaults shown above
unless the host explicitly configures another valid policy.

### 10.3 `tools/list`

Request headers set `Mcp-Method: tools/list` and omit `Mcp-Name`:

~~~json
{
  "jsonrpc": "2.0",
  "id": "tools-1",
  "method": "tools/list",
  "params": {
    "_meta": {
      "io.modelcontextprotocol/protocolVersion": "2026-07-28",
      "io.modelcontextprotocol/clientInfo": {
        "name": "tama-link",
        "version": "0.1.0"
      },
      "io.modelcontextprotocol/clientCapabilities": {}
    }
  }
}
~~~

~~~http
HTTP/1.1 200 OK
Content-Type: application/json

{
  "jsonrpc": "2.0",
  "id": "tools-1",
  "result": {
    "resultType": "complete",
    "tools": [
      {
        "name": "message",
        "description": "Send a message to Tama",
        "inputSchema": {
          "type": "object",
          "properties": {
            "message": {
              "type": "string",
              "minLength": 1
            }
          },
          "required": ["message"],
          "additionalProperties": false
        },
        "outputSchema": {
          "type": "object",
          "properties": {
            "status": {
              "type": "string"
            }
          },
          "required": ["status"],
          "additionalProperties": false
        }
      }
    ],
    "ttlMs": 0,
    "cacheScope": "private"
  }
}
~~~

### 10.4 `tools/call`

The task-required `message` call sets `Mcp-Method: tools/call` and
`Mcp-Name: message`:

~~~json
{
  "jsonrpc": "2.0",
  "id": "call-1",
  "method": "tools/call",
  "params": {
    "_meta": {
      "io.modelcontextprotocol/protocolVersion": "2026-07-28",
      "io.modelcontextprotocol/clientInfo": {
        "name": "tama-link",
        "version": "0.1.0"
      },
      "io.modelcontextprotocol/clientCapabilities": {
        "extensions": {
          "io.modelcontextprotocol/tasks": {}
        }
      }
    },
    "name": "message",
    "arguments": {
      "message": "Summarize the current project state."
    }
  }
}
~~~

~~~http
HTTP/1.1 200 OK
Content-Type: application/json

{
  "jsonrpc": "2.0",
  "id": "call-1",
  "result": {
    "resultType": "task",
    "taskId": "d59d7f2a-933e-44f4-8c28-4d28e9f0d937",
    "status": "working",
    "statusMessage": "The message is queued for processing.",
    "createdAt": "2026-09-11T10:00:00Z",
    "lastUpdatedAt": "2026-09-11T10:00:00Z",
    "ttlMs": 86400000,
    "pollIntervalMs": 1000
  }
}
~~~

A synchronous tool uses the same request envelope but returns a normal
`CallToolResult`:

~~~json
{
  "jsonrpc": "2.0",
  "id": "call-2",
  "result": {
    "resultType": "complete",
    "content": [
      {
        "type": "text",
        "text": "Tama is available."
      }
    ],
    "structuredContent": {
      "status": "available"
    },
    "isError": false
  }
}
~~~

### 10.5 `tasks/get`

The request sets `Mcp-Method: tasks/get` and
`Mcp-Name: d59d7f2a-933e-44f4-8c28-4d28e9f0d937`:

~~~json
{
  "jsonrpc": "2.0",
  "id": "task-get-1",
  "method": "tasks/get",
  "params": {
    "_meta": {
      "io.modelcontextprotocol/protocolVersion": "2026-07-28",
      "io.modelcontextprotocol/clientInfo": {
        "name": "tama-link",
        "version": "0.1.0"
      },
      "io.modelcontextprotocol/clientCapabilities": {
        "extensions": {
          "io.modelcontextprotocol/tasks": {}
        }
      }
    },
    "taskId": "d59d7f2a-933e-44f4-8c28-4d28e9f0d937"
  }
}
~~~

~~~http
HTTP/1.1 200 OK
Content-Type: application/json

{
  "jsonrpc": "2.0",
  "id": "task-get-1",
  "result": {
    "resultType": "complete",
    "taskId": "d59d7f2a-933e-44f4-8c28-4d28e9f0d937",
    "status": "completed",
    "statusMessage": "The message completed successfully.",
    "createdAt": "2026-09-11T10:00:00Z",
    "lastUpdatedAt": "2026-09-11T10:00:05Z",
    "ttlMs": 86400000,
    "pollIntervalMs": 1000,
    "result": {
      "resultType": "complete",
      "content": [
        {
          "type": "text",
          "text": "The project foundation is complete."
        }
      ],
      "structuredContent": {
        "status": "completed"
      },
      "isError": false
    }
  }
}
~~~

### 10.6 `tasks/update`

The request sets `Mcp-Method: tasks/update` and the task ID as `Mcp-Name`:

~~~json
{
  "jsonrpc": "2.0",
  "id": "task-update-1",
  "method": "tasks/update",
  "params": {
    "_meta": {
      "io.modelcontextprotocol/protocolVersion": "2026-07-28",
      "io.modelcontextprotocol/clientInfo": {
        "name": "tama-link",
        "version": "0.1.0"
      },
      "io.modelcontextprotocol/clientCapabilities": {
        "extensions": {
          "io.modelcontextprotocol/tasks": {}
        }
      }
    },
    "taskId": "d59d7f2a-933e-44f4-8c28-4d28e9f0d937",
    "inputResponses": {
      "approval": {
        "action": "accept",
        "content": {
          "approved": true
        }
      }
    }
  }
}
~~~

~~~http
HTTP/1.1 200 OK
Content-Type: application/json

{
  "jsonrpc": "2.0",
  "id": "task-update-1",
  "result": {
    "resultType": "complete"
  }
}
~~~

The acknowledgement is eventually consistent. It does not promise that a
subsequent `tasks/get` has already left `input_required`.

### 10.7 `tasks/cancel`

The request sets `Mcp-Method: tasks/cancel` and the task ID as `Mcp-Name`:

~~~json
{
  "jsonrpc": "2.0",
  "id": "task-cancel-1",
  "method": "tasks/cancel",
  "params": {
    "_meta": {
      "io.modelcontextprotocol/protocolVersion": "2026-07-28",
      "io.modelcontextprotocol/clientInfo": {
        "name": "tama-link",
        "version": "0.1.0"
      },
      "io.modelcontextprotocol/clientCapabilities": {
        "extensions": {
          "io.modelcontextprotocol/tasks": {}
        }
      }
    },
    "taskId": "d59d7f2a-933e-44f4-8c28-4d28e9f0d937"
  }
}
~~~

~~~http
HTTP/1.1 200 OK
Content-Type: application/json

{
  "jsonrpc": "2.0",
  "id": "task-cancel-1",
  "result": {
    "resultType": "complete"
  }
}
~~~

This response acknowledges cancellation intent only. It does not assert that
the task has reached `cancelled`.

### 10.8 `subscriptions/listen`

The request sets `Mcp-Method: subscriptions/listen`, omits `Mcp-Name`, and
requests task IDs only after declaring the Tasks capability:

~~~json
{
  "jsonrpc": "2.0",
  "id": "listen-1",
  "method": "subscriptions/listen",
  "params": {
    "_meta": {
      "io.modelcontextprotocol/protocolVersion": "2026-07-28",
      "io.modelcontextprotocol/clientInfo": {
        "name": "tama-link",
        "version": "0.1.0"
      },
      "io.modelcontextprotocol/clientCapabilities": {
        "extensions": {
          "io.modelcontextprotocol/tasks": {}
        }
      }
    },
    "notifications": {
      "taskIds": [
        "d59d7f2a-933e-44f4-8c28-4d28e9f0d937"
      ]
    }
  }
}
~~~

The response is a long-lived stream:

~~~http
HTTP/1.1 200 OK
Content-Type: text/event-stream
Cache-Control: no-cache

data: {"jsonrpc":"2.0","method":"notifications/subscriptions/acknowledged","params":{"_meta":{"io.modelcontextprotocol/subscriptionId":"listen-1"},"notifications":{"taskIds":["d59d7f2a-933e-44f4-8c28-4d28e9f0d937"]}}}

data: {"jsonrpc":"2.0","method":"notifications/tasks","params":{"_meta":{"io.modelcontextprotocol/subscriptionId":"listen-1"},"taskId":"d59d7f2a-933e-44f4-8c28-4d28e9f0d937","status":"completed","statusMessage":"The message completed successfully.","createdAt":"2026-09-11T10:00:00Z","lastUpdatedAt":"2026-09-11T10:00:05Z","ttlMs":86400000,"pollIntervalMs":1000,"result":{"resultType":"complete","content":[{"type":"text","text":"The project foundation is complete."}],"structuredContent":{"status":"completed"},"isError":false}}}

data: {"jsonrpc":"2.0","id":"listen-1","result":{"resultType":"complete","_meta":{"io.modelcontextprotocol/subscriptionId":"listen-1"}}}

~~~

The acknowledgement must be the first event for `listen-1`. Every later
notification on that stream carries the same
`io.modelcontextprotocol/subscriptionId`. The final JSON-RPC response is sent
only for graceful closure; an abrupt transport close has no final response.

## 11. Discovery

`server/discover` advertises:

- supported version `2026-07-28` only;
- server name, version, and optional instructions;
- tools capability;
- any in-scope core notification flags the server can actually deliver; and
- the Tasks extension when both a task store and task runner are configured.

Capabilities must describe the configured server truthfully. Task polling may
be advertised without a notification bus because task notifications are
optional in the extension. Without a notification bus, a task-ID
`subscriptions/listen` request acknowledges no task IDs. With a notification
bus, it acknowledges only IDs that pass the authorization checks in section 14.

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

TamaMCP applies the following narrower transition profile:

| Current state | Permitted next states |
| --- | --- |
| new task | `working` |
| `working` | `input_required`, `completed`, `failed`, `cancelled` |
| `input_required` | `working`, `completed`, `failed`, `cancelled` |
| `completed` | none |
| `failed` | none |
| `cancelled` | none |

The pinned extension permits a task result to be seeded in another state, but
TamaMCP always creates tasks as `working` so persistence and execution have one
deterministic entry point. A metadata update that retains `working` or
`input_required` is permitted and is not a state transition. It must still use
compare-and-update semantics and advance `lastUpdatedAt`.

An exact replay of an already-committed terminal state and payload is an
idempotent no-op. A terminal payload mutation, a change from one terminal state
to another, or a transition from a terminal state back to a non-terminal state
is rejected.

`tasks/cancel` records cooperative cancellation intent. It does not itself
promise or perform a transition to `cancelled`; the runner may still commit
`completed` or `failed` if execution wins the race. Expiry may transition a
non-terminal task to `failed` with a bounded expiration error after its TTL.

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

### 13.4 Task runner behaviour

`TamaMCP.TaskRunner` defines the application-owned handoff from a validated
task-producing tool call to durable execution:

~~~elixir
@callback start(
            tool :: module(),
            input :: map(),
            context :: TamaMCP.Context.t(),
            options :: keyword()
          ) ::
            {:ok, TamaMCP.Task.t()}
            | {:error, TamaMCP.Error.t()}
~~~

The runner must return `{:ok, task}` only after:

1. the task is durably created;
2. an authorized `tasks/get` can resolve it;
3. the durable execution handoff has been accepted; and
4. the returned task is in `working`.

The adapter owns the atomicity between task creation and durable dispatch. A
Tama implementation may, for example, insert its task/submission row and its
queue entry in one database transaction. TamaMCP does not depend on Ecto or a
queue. Returning `{:error, error}` asserts that no task handle was exposed and
no unreconciled externally visible task was left behind.

The runner later invokes the same tool `call/2` callback used for synchronous
execution. A success or tool error is stored as a `completed` task containing
the complete `CallToolResult`; a `TamaMCP.Error` or unexpected redacted
exception is stored as `failed`. The runner updates task state through the
task-store contract and publishes only after the state commit succeeds.

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
task ID before acknowledging the stream. The normalized authorization decision
must provide an expiry deadline when the credential has one. A stream must
close no later than the earlier of credential expiry or its configured maximum
lifetime.

Authorization is rechecked:

1. before acknowledgement, including owner binding for every requested task;
2. before delivering every task notification;
3. at least once per configured recheck interval while the stream is idle; and
4. immediately when the host adapter signals credential or policy invalidation.

Any failed stream recheck closes the stream before another task snapshot is
sent. If authorization fails for one subscribed task during delivery, the
entire stream closes so the client must reauthenticate, call `tasks/get` to
reconcile, and open a new stream whose acknowledgement contains the currently
authorized subset. There is no silent continuation with a stale acknowledged
set.

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
- task runner and options;
- notification bus and options;
- clock and identifier adapters; and
- telemetry prefix and safe metadata callback.

The library must not read Tama environment variables directly. Applications
load environment configuration and pass validated values to the server.

The initial production defaults are:

| Configuration key | Default | Meaning |
| --- | ---: | --- |
| `max_body_bytes` | `1_048_576` | maximum encoded UTF-8 request body |
| `body_read_timeout_ms` | `5_000` | maximum time spent reading the request body |
| `request_timeout_ms` | `30_000` | synchronous tool execution deadline |
| `max_schema_bytes` | `262_144` | maximum canonical JSON size of each input or output schema |
| `max_tools_per_server` | `256` | maximum registered tool definitions |
| `default_task_ttl_ms` | `86_400_000` | default task lifetime of 24 hours |
| `max_task_ttl_ms` | `604_800_000` | maximum task lifetime of 7 days |
| `default_poll_interval_ms` | `1_000` | task polling guidance |
| `max_task_ids_per_subscription` | `100` | maximum task IDs requested on one stream |
| `notification_buffer_capacity` | `100` | maximum queued task snapshots per stream |
| `stream_keepalive_interval_ms` | `15_000` | SSE keepalive comment interval |
| `stream_authorization_recheck_ms` | `60_000` | maximum idle time between authorization checks |
| `stream_max_lifetime_ms` | `3_600_000` | maximum stream lifetime before graceful reconnect |
| `max_status_message_bytes` | `2_048` | maximum encoded task status message |
| `max_error_data_bytes` | `8_192` | maximum encoded public error data |
| `max_safe_metadata_bytes` | `16_384` | maximum encoded selected context/telemetry metadata |

All sizes are measured after UTF-8 or canonical JSON encoding as applicable.
All intervals are positive integer milliseconds. Host applications may lower
the limits. Raising one requires explicit configuration and tests at the new
boundary. `:infinity`, `nil` as an unlimited sentinel, negative values, and zero
limits are invalid. Although the Tasks schema permits a null TTL, the TamaMCP
profile does not emit unlimited tasks.

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

### 19.1 Fixture contract

The repository must keep immutable upstream artifacts in `priv/protocol` and
Tama-specific wire fixtures in `test/fixtures/protocol/2026-07-28`. The latter
must include at least:

| Method or flow | Required positive fixtures | Required negative fixtures |
| --- | --- | --- |
| `server/discover` | request and configured capability response | unsupported version and header/body disagreement |
| `tools/list` | request and deterministic single-page response | invalid metadata and exceeded catalog bound |
| `tools/call` | synchronous success, tool error, and task creation | missing tool, invalid arguments, scope denial, missing Tasks capability, output-schema failure |
| `tasks/get` | all five detailed task variants | unknown/unauthorized task and header/body task-ID disagreement |
| `tasks/update` | complete and partial input responses | invalid task, invalid response shape, and update outside `input_required` |
| `tasks/cancel` | accepted cooperative cancellation | invalid task and cancellation race with each terminal state |
| `subscriptions/listen` | acknowledgement, task notification, graceful close, and reconnect | missing capability, unauthorized task subset, expired credential, stale policy, and overflow close |

Each HTTP fixture contains request headers, request JSON, expected HTTP status,
expected response content type, and response JSON or ordered SSE events. Every
fixture must validate against the vendored core and Tasks schemas where a
schema exists. The suite must also assert header presence, Base64 sentinel
decoding, header/body equality, acknowledgement-first ordering, subscription ID
tagging, and the absence of undeclared notification types.

The examples in section 10 are the human-readable form of this fixture
contract. If a checked fixture changes, the example must change in the same
commit.

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
- compile-time server and tool DSL macros;
- Draft 2020-12 schema compilation and validation;
- stateless HTTP Plug, headers, JSON-RPC, and discovery; and
- synchronous System MCP tools and contract tests.

### Phase 2: durable Tasks extension

- task value and state transitions;
- task-store behaviour;
- task-runner behaviour and atomic durable dispatch;
- server-directed task creation;
- `tasks/get`, `tasks/update`, and `tasks/cancel`; and
- conversion of Tama persistence away from Anubis task structs and
  session-scoped identity.

### Phase 3: subscriptions and task notifications

- notification-bus behaviour;
- `subscriptions/listen` stream and acknowledgement;
- authorized `notifications/tasks` delivery;
- expiry, idle, delivery-time, and policy-invalidation authorization checks;
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
5. the App `message` tool requires the Tasks extension and its configured task
   runner atomically creates and dispatches durable work;
6. task state is durable and independent of a process or HTTP connection;
7. task access is bound to the validated caller on every request;
8. the explicit task transition matrix, `tasks/get`, `tasks/update`, and
   cooperative cancellation conform to the pinned protocol fixtures;
9. `subscriptions/listen` acknowledges only authorized task IDs and closes on
   expiry, failed periodic recheck, delivery-time denial, or policy
   invalidation;
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
