# TamaMCP Phase 1 review 01

Date: 2026-09-11

Review target: the uncommitted working tree on
`feature/phase1-protocol-core`, based on `d33f49d` (`origin/develop`).

## Decision

The Phase 1 implementation is not ready to commit or hand off. The overall
direction matches the specification, but the current tree has release-blocking
protocol, safety, typing, packaging, and test gaps. It also changes Credo policy
to make the implementation pass instead of bringing the implementation back to
the repository's existing strict-Credo convention.

The implementation should be corrected without inline Dialyzer suppressions.
The two runtime suppressions conceal a real contract mismatch; the tool DSL
suppression is avoidable with an honest no-return API or, preferably, by
removing the unnecessary public guard function.

## Review baseline

The review used these repository contracts as authoritative:

- `AGENTS.md`;
- `wip/tama-mcp-specification.md`, especially sections 8-10 and 15-21;
- the vendored MCP `2026-07-28` core schema and Tasks extension;
- the pinned Elixir 1.19.5 toolchain in `mise.toml`; and
- the established Tama and Memovee Mix conventions.

The following checks were run against the current tree:

| Check | Result |
| --- | --- |
| `mix precommit` | Passed: 2 doctests and 22 tests |
| `mix dialyzer --no-check` | Passed only with three inline `@dialyzer` suppressions |
| isolated Dialyzer run without suppressions | Failed with 3 warnings |
| `mix docs` | Passed |
| `mix hex.build` | Passed mechanically, but omitted all `priv/protocol` artifacts |
| `mix test --cover` | Failed: 66.37% total versus the default 90% threshold |
| `git diff --check` | Passed |

Passing `mix precommit` is therefore not sufficient evidence for Phase 1
acceptance in the current tree.

## Configuration analysis

### Why `.credo.exs` was created

The file is the stock output of `mix credo.gen.config` with only three policy
changes:

1. global cyclomatic complexity is relaxed from 9 to 12;
2. global nesting depth is relaxed from 2 to 3; and
3. `Credo.Check.Warning.RaiseInsideRescue` is disabled.

Removing the file and running the repository's existing
`mix credo --strict` command reports 12 findings:

- five deeply nested functions;
- six functions above the default complexity limit; and
- the broad rescue/new-raise in `TamaMCP.Tool.eval_literal!/1`.

The affected modules are `Plug`, `Request`, `Tool`, `Server`, and `Schema`.
These findings align with the manual review: `Plug` is 769 lines, request
validation and dispatch are nested, and compile-time DSL work is concentrated
in one module.

Tama and Memovee both run `credo --strict` without a repository `.credo.exs`.
There is no TamaMCP-specific lint requirement that needs a custom file today.
The generated file should be removed, the default limits restored, and the
reported functions refactored. If a future project-specific exception is
genuinely needed, it should be a minimal configuration with a narrow rationale,
not a generated 227-line snapshot of Credo defaults.

The disabled rescue warning is also avoidable. `eval_literal!/1` claims to
accept literals but calls `Code.eval_quoted/2`, which can execute arbitrary
compile-time expressions, rescues every exception, and discards its original
cause. Validate literal AST explicitly (for example with
`Macro.quoted_literal?/1`) and eliminate the broad rescue.

Conclusion: `.credo.exs` currently functions as a shortcut around actionable
design feedback and should not be retained in this form.

### Why `test_pattern: "*_test.exs"` appears

This line is not redundant under the pinned Elixir 1.19.5 toolchain. Mix 1.19
changed `:test_pattern` from `*_test.exs` to the broader `*.{ex,exs}` and uses
load/ignore filters to classify discovered files. Removing the override in the
current tree produces this warning:

```text
the following files do not match any of the configured
:test_load_filters / :test_ignore_filters:

test/support/fixtures.ex
```

This is why projects created on older Elixir versions often do not show the
setting. The behavior is documented in the official
[`mix test` configuration](https://hexdocs.pm/mix/Mix.Tasks.Test.html#module-configuration).

The override silences a real discovery warning, but it is not the best local
convention. Tama and Memovee both compile test support through:

```elixir
elixirc_paths: elixirc_paths(Mix.env())

defp elixirc_paths(:test), do: ["lib", "test/support"]
defp elixirc_paths(_env), do: ["lib"]
```

TamaMCP should follow that convention, remove `test_pattern`, and remove the
manual `Code.require_file/2` from `test/test_helper.exs`. Before doing so,
`test/support/fixtures.ex` must be split by module/dependency (tools,
authorization adapter, then server). An isolated conversion to the established
`elixirc_paths(:test)` convention exposed the current compile-order coupling:
the server in the same support file tries to verify tool modules before that
file has finished compiling.

Conclusion: the setting has a real Elixir 1.19 explanation, but the underlying
test-support layout should be fixed rather than opting the project back into
the pre-1.19 discovery pattern.

### Why the Dialyzer ignores exist

With all three inline annotations removed, Dialyzer reports:

```text
lib/tama_mcp/tool.ex:199:7:no_return
Function field/2 has no local return.

lib/tama_mcp/transport/streamable_http/plug.ex:49:invalid_contract
Plug.init/1 success typing does not match Runtime.t().

lib/tama_mcp/transport/streamable_http/runtime.ex:70:invalid_contract
Runtime.build/1 success typing does not match Runtime.t().
```

The causes and correct resolutions differ:

- `Tool.field/2` is generated by the default argument on an always-raising
  misuse guard. It is not imported by `use TamaMCP.Tool`, and schema blocks are
  parsed as AST, so the public function is not required for the DSL. Prefer
  deleting it and letting an out-of-context `field` call fail as an undefined
  DSL form. If the custom diagnostic is retained, define `field/2` and
  `field/3` separately with `no_return()` specs. That exact form was verified
  in isolation to eliminate the warning without a suppression; a default
  argument only gives the generated `field/2` wrapper an uncovered no-return
  warning.
- `Runtime.build/1` declares a narrow `%Runtime{}` type but fetches mostly
  unconstrained terms from a keyword list. Its `unless` validators return
  `:ok` and do not refine the values that are later inserted into the struct.
  Several advertised options are not validated at all. This is a real boundary
  design/type mismatch, not a false positive. Each validator should return the
  normalized value from guarded clauses, and `build/1` should construct the
  struct only from those returned values. Unsupported future-phase options
  should be removed until their behaviours exist, or validated completely.
- `Plug.init/1` merely delegates to `Runtime.build/1`; its warning is the same
  unresolved return-contract problem propagated one level outward. Fixing the
  runtime boundary removes the reason for both suppressions.

The `plt_file: {:no_warn, "priv/plts/dialyzer.plt"}` Mix setting is different:
it controls warnings about PLT-file availability and does not suppress source
diagnostics. Tama and Memovee use the same setting. The problematic ignores are
the three source annotations.

## Blocking findings

### [P1] A task-required tool is executed synchronously

Evidence: `lib/tama_mcp/transport/streamable_http/plug.ex:425-437` only checks
that the client declares the Tasks extension; `:required` then follows the same
direct `module.call/2` path as a synchronous tool at lines 462-544.
`Runtime.validate_tool_policies!/2` merely checks that `task_runner` is non-nil,
without a TaskRunner behaviour or task execution path.

A runtime probe with `task: :required`, a declared Tasks capability, and
`task_runner: :not_a_runner` returned a normal `resultType: "complete"` response
whose content proved that the tool ran synchronously.

This violates section 8: `:required` must create a durable task and must never
execute synchronously. During Phase 1, reject any runtime containing a
`:required` tool regardless of a placeholder option. Do not accept Phase 2
adapter options until the corresponding behaviours and atomic path exist.

### [P1] Request and body limits are declared but not enforced end to end

Evidence:

- `request_timeout_ms` is defined only in `Runtime.default_limits/0`; direct
  `module.call/2` execution has no deadline.
- `drain_body/3` passes the full `max_body_bytes` allowance on every recursive
  `read_body/2` call and appends `acc <> data` on every `{:more, ...}` result
  without checking the accumulated size until a final `{:ok, ...}`.
- `body_read_timeout_ms` is applied separately to each read, not as a total
  body-read deadline.

A streaming or slow request can therefore consume more memory/time than the
documented limits, and a synchronous tool can occupy a request indefinitely.
Implement an accumulated byte budget, a monotonic total read deadline, and the
specified synchronous execution timeout. Add exact-boundary, one-byte-over,
multi-chunk, slow-read, and hung-tool tests.

### [P1] The request context drops the caller binding and corrupts selected headers

Evidence:

- `Authorization.Decision` has `owner_key`, but `TamaMCP.Context` has no such
  field and `build_context/7` drops it. This contradicts section 9's security
  invariant that the caller binding survive asynchronous transfer.
- `selected_headers/2` stores the whole `{header, value}` tuple as the map
  value. A runtime probe returned
  `%{"x-safe" => {"x-safe", "expected-value"}}`, not
  `%{"x-safe" => "expected-value"}`.
- `Context.assigns` is always `%{}` and no adapter/configuration path supplies
  the application assigns promised by section 9.

Add the normalized owner key to the context now, destructure selected header
tuples correctly, define duplicate-header behavior, and either implement the
explicit safe-assigns source or remove the unsupported field/claim until its
phase is implemented.

### [P1] Response validation can emit protocol-invalid results

Evidence: `TamaMCP.Response.valid_block?/1` accepts every JSON-safe map whose
`type` is not `"text"`. A direct probe confirms that
`%{"type" => "not-an-mcp-content-block"}` returns `:ok`. Text blocks check only
the `text` member and do not verify that the complete block is JSON-safe.

The vendored `ContentBlock` schema permits only text, image, audio, resource
link, and embedded resource shapes. Phase 1 must validate complete tool results
against the pinned `CallToolResult` schema (plus the declared output schema)
before encoding. Hand-maintaining a looser second validator will drift.

Also define protected result metadata ownership. `with_result_meta/2` currently
lets tool-supplied `_meta` override the canonical server-info key because the
existing tool metadata wins the merge.

### [P1] Error size and JSON-RPC shape are not enforced

Evidence:

- `max_error_data_bytes` is never read outside `Runtime.default_limits/0`.
- adapter-provided error data is checked for JSON encodability but never bounded;
- request/header-derived error messages can include unbounded values; and
- `Error.parse(nil)` and `Error.internal(nil)` construct a value outside
  `Error.t()` and encode JSON-RPC `message` as `null`. A direct probe produced
  `%{"code" => -32603, "message" => nil}` even though JSON-RPC requires a
  string message.

Centralize error normalization/encoding at the transport boundary. Enforce the
configured canonical JSON byte bound, require a non-empty bounded message, and
drop or replace invalid data deterministically. Constructor specs and returned
structs must agree.

### [P1] The Hex package omits the vendored normative contract

Evidence: `mix hex.build` lists only `lib`, `.formatter.exs`, `mix.exs`, README,
changelog, and license. `mix.exs:41` excludes `priv`, so none of the 165
manifested protocol artifacts is shipped.

Section 2 requires the pinned schemas, examples, prose, and manifest to be
vendored. Include the required `priv/protocol/2026-07-28` paths in the package
file list, then inspect the built tarball and add a package-content regression
test or release check.

### [P1] Phase 1 conformance tests are materially incomplete

The suite contains one 362-line transport test module and no
`test/fixtures/protocol/2026-07-28` directory. The manifest test proves only
that each file matches the checksum written next to it; it does not pin the
expected repositories/commits/artifact inventory, nor validate Tama wire
fixtures against the official schemas.

Coverage is 66.37%, with the core implementation modules between 53% and 77%.
There are no focused suites for Server/Tool compilation failures, schema DSL
boundaries, Runtime option validation, response/error encoding, configured
context headers, timeout/body limits, telemetry redaction, Base64 sentinel
cases, duplicate headers, or output-schema/protocol-schema failures.

Implement section 19's Phase 1 fixture matrix. Split tests by owned component,
compile invalid DSL examples dynamically, validate every request/response
fixture against the vendored schema, and make coverage a deliberate project
gate rather than relying on the current minimal `precommit` pass.

## Additional correctness and maintainability findings

### [P2] Authentication is not invoked for every request

`handle/3` performs method, media-type, header, body, and envelope rejection
before `handle_authenticated/4`. GETs and malformed POSTs never call the
authorization adapter, contrary to sections 10 and 15's explicit
"authorization decision on every request" contract. Decide and document the
precise ordering, then test adapter invocation exactly once for every accepted
and rejected request category.

### [P2] Schema validators are compiled twice and can become stale

`compile_tool_schema!/3` compiles a schema for validation and discards the
compiled value. `input_validator/1` and `output_validator/1` compile it again
on first request and store it under the generic persistent-term key
`{module, :input | :output}`.

This does not satisfy "compiled once and reused," adds first-request work, can
collide with unrelated persistent-term users, and retains a stale validator
after a module/schema reload because the key does not include schema identity.
Move compilation into one dedicated owner and key any cache by a namespaced
schema digest, with explicit reload behavior. Prefer generating immutable
compiled data with the tool when the compiled representation safely supports
it.

### [P2] The schema DSL silently accepts malformed declarations

The DSL currently:

- silently overwrites duplicate field names through `Map.new/1`;
- ignores field arguments after the third because `parse_field_args/1` reads
  only `List.first(rest, [])`;
- produces a `MatchError` instead of a useful compile error for too few field
  arguments;
- ignores unknown field options and does not require boolean `:required`;
- accepts repeated input/output schema declarations by last-write-wins module
  attributes; and
- rejects a valid mixed integer/float numeric enum such as `[1, 2.5]`.

Introduce explicit declaration structs/tuples with exhaustive arity and option
validation, reject duplicates at compile time, and unit-test every invalid
form. Keep the raw-schema escape hatch for all valid Draft 2020-12 schemas.

### [P2] Runtime configuration advertises fields it does not validate or use

`Runtime.t()` claims modules, keyword lists, atom lists, and string lists, but
`build/1` accepts raw `Keyword.get/3` values for most fields. Phase 2/3 adapter
options are exposed before their behaviours exist. Most configured limits are
also dead in Phase 1.

Keep a small Phase 1 runtime containing only supported settings. Add future
settings alongside their behaviours and normalization tests. This will reduce
the Dialyzer surface and prevent configurations that initialize successfully
but cannot work.

### [P2] Wire-policy mappings and rejection plumbing are duplicated

`Plug.error_status/1` and `Plug.error_reason/1` repeat numeric constants that
already belong to `Protocol`/`Error`, while most handlers repeat the same
`send_error` plus telemetry-map construction. This makes it easy for an error
code, HTTP status, reason, and telemetry status to diverge.

Give `TamaMCP.Error` one bounded classification function returning its HTTP
status and safe reason, and introduce a small transport rejection helper. Do
not hide dispatch semantics behind generic metaprogramming; centralize only the
repeated policy.

## Module decomposition

The large modules should be split along ownership boundaries, not merely by
line count.

### `TamaMCP.Transport.StreamableHTTP.Plug` (769 lines)

Keep `Plug` as the public adapter with `init/1`, `call/2`, the outer exception
boundary, and top-level orchestration. Extract:

- `BodyReader` for media negotiation, content length, byte budgeting, and the
  total read deadline;
- `Dispatcher` for `server/discover`, `tools/list`, and `tools/call` routing;
- `ToolExecutor` for task-policy choice, scope/input/output checks, execution
  deadlines, and context creation;
- `Encoder` for pinned-schema validation, JSON-RPC envelopes, HTTP status, and
  bounded errors; and
- `Telemetry` for safe event construction and metadata bounding.

This split directly addresses four default Credo complexity/nesting findings
and makes the safety boundaries independently testable.

### `TamaMCP.Transport.StreamableHTTP.Request` (349 lines)

Separate JSON-RPC envelope/metadata parsing from standard HTTP header parsing
and comparison. Both should return one small normalized request or one
classified error. Keep Base64 sentinel decoding with the header component and
test it independently with the pinned fixtures.

### `TamaMCP.Tool` (448 lines)

Keep the public behaviour and `__using__/1` entry point in `Tool`. Move
declaration parsing/validation and before-compile generation to an internal
`Tool.Compiler`. Keep ordinary JSON Schema building/compilation in `Schema` (or
a narrowly named `Schema.Compiler`) so the macro does not own runtime caching.

### Test modules

Split `plug_test.exs` by request parsing, discovery, listing, calling, body
limits, authorization, response encoding, and telemetry. Split
`test/support/fixtures.ex` into compiler-friendly files and compile the support
tree via the established `elixirc_paths(:test)` convention.

## Recommended remediation order

1. Remove `.credo.exs`, `test_pattern`, manual support loading, and all inline
   Dialyzer suppressions; split test support and restore the established
   project conventions.
2. Narrow and fully normalize the Phase 1 Runtime so Dialyzer passes without
   ignores.
3. Reject `:required` task policies until the actual Phase 2 durable path
   exists.
4. Fix context ownership/header shape and implement real body/tool deadlines.
5. Centralize bounded error/result encoding and validate emitted wire values
   against the vendored schemas.
6. Fix validator lifecycle and harden the compile-time DSL.
7. Add the section 19 Phase 1 fixtures and focused unit/contract tests.
8. Include `priv/protocol` in the Hex package and rerun the complete required
   checks: `mix precommit`, PLT build, `mix dialyzer --no-check`, `mix docs`,
   `mix hex.build`, fixture validation, package-content inspection, and
   coverage.

Do not move to durable Tasks implementation while these Phase 1 boundaries are
unresolved; the current context and task-policy shortcuts would otherwise
become persistence and authorization bugs.
