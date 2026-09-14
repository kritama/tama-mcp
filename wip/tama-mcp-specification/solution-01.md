# Solution 01 — establish the tool-module compile dependency explicitly

Date: 2026-09-11

Applies to: `wip/tama-mcp-specification/problems-01.md`

## Decision

Keep the split `test/support` files and `elixirc_paths(:test)` convention. Do
not revert to manual `Code.require_file/2`, do not depend on file ordering, and
do not weaken `TamaMCP.Server.tool/2` to best-effort validation.

Replace `Code.ensure_loaded?/1` with `Code.ensure_compiled!/1` at the point
where the `tool/2` macro validates the expanded tool module. Then retain strict
compile-time validation of the tool contract before recording the catalog
entry.

This is the Elixir-supported solution for this exact situation. Parallel
compilation can encounter a module that belongs to the same project but has not
been compiled yet. `Code.ensure_loaded?/1` only answers whether a module can be
loaded now. `Code.ensure_compiled!/1` tells the parallel compiler that the
caller cannot continue until that module is compiled and loaded.

Official reference:
[`Code.ensure_compiled!/1`](https://hexdocs.pm/elixir/Code.html#ensure_compiled!/1).

## Correction to the problem analysis

The following conclusions in `problems-01.md` are incorrect:

- `@behaviour` is not the only way to establish compile ordering.
- expanding an alias to an atom does not make a compile dependency impossible;
  the macro can establish it explicitly with `Code.ensure_compiled!/1`.
- deferring validation to runtime is not required.

There is also a small timing distinction in the current code. `tool/2` does not
directly call `__tool__/3` while the macro function itself is expanding. It
emits a call to `TamaMCP.Server.__tool__/3` in the quoted server module body.
That call still runs while the server is being compiled, but
`Code.ensure_loaded?/1` does not wait for another file in the parallel compiler.

Elixir documents `ensure_compiled!/1` as the uncommon but intended operation
for macros that need callback or contract information from another module in
the same project. It waits for the dependency and reports an unavailable
module or compiler cycle instead of silently continuing.

## Recommended implementation

Perform validation in the `tool/2` macro after `Macro.expand/2` and before
emitting the module-attribute update. The shape should be:

```elixir
defmacro tool(module_ast, opts) do
  name = validate_tool_name!(opts)
  tool_module = expand_tool_module!(module_ast, __CALLER__)

  validate_tool_module!(__CALLER__, tool_module)

  quote bind_quoted: [tool_module: tool_module, name: name] do
    @tama_mcp_server_tools [{name, tool_module} | @tama_mcp_server_tools]
  end
end

defp validate_tool_module!(caller, tool_module) do
  Code.ensure_compiled!(tool_module)

  required_exports = [
    tool_metadata: 0,
    task_policy: 0,
    definition: 0,
    input_validator: 0,
    output_validator: 0,
    call: 2
  ]

  missing =
    Enum.reject(required_exports, fn {name, arity} ->
      function_exported?(tool_module, name, arity)
    end)

  if missing != [] do
    formatted = Enum.map_join(missing, ", ", fn {name, arity} -> "#{name}/#{arity}" end)

    raise CompileError,
      file: caller.file,
      line: caller.line,
      description:
        "module #{inspect(tool_module)} is not a compiled TamaMCP tool; " <>
          "missing #{formatted}. Define it with `use TamaMCP.Tool` before " <>
          "registering it on #{inspect(caller.module)}"
  end

  :ok
end
```

The existing name/module-AST validation can remain inline if extracting
`validate_tool_name!/1` and `expand_tool_module!/2` would be premature. They are
shown as helpers to keep `tool/2` below the default Credo complexity limit.

The important behavior is:

1. expand and validate the module expression;
2. call `Code.ensure_compiled!/1` exactly once;
3. validate every export used by the Phase 1 runtime;
4. record the catalog entry only after validation succeeds; and
5. keep duplicate-name validation in `__before_compile__/1`.

The helper can be private. The current public `__tool__/3` function and the
quoted call to it are no longer necessary when validation happens directly in
the macro.

## Why strict export validation should remain

Checking only `tool_metadata/0` and `call/2` preserves the old diagnostic but
does not verify everything the current transport invokes. The Phase 1 runtime
also calls `task_policy/0`, `definition/0`, `input_validator/0`, and
`output_validator/0`. Validate that complete runtime-facing contract at the
DSL boundary so a malformed catalog cannot compile successfully and fail later
with `UndefinedFunctionError`.

If the list becomes shared by other boundaries, move the predicate/list to one
internal owner such as `TamaMCP.Tool.Compiler`; do not duplicate export lists
between `Server` and `Runtime`.

A future refinement could generate a versioned marker such as
`__tama_mcp_tool__/0` from `use TamaMCP.Tool`. That would distinguish a genuine
TamaMCP tool from a module that happens to implement the same functions. It is
not required to solve Problem 01, so it should be added only with a clear
public/internal contract decision and tests.

## Do not use the current mitigation

Remove the best-effort form:

```elixir
if Code.ensure_loaded?(tool_module) do
  # maybe validate
end
```

It makes behavior depend on incidental compiler/load state: the same invalid
server can fail at compile time, pass compilation, or fail at runtime depending
on which module happened to compile first. That is nondeterministic and breaks
the specification's compile-time DSL guarantee.

Runtime catalog validation may still exist as defense in depth for hot-code
replacement or externally supplied server modules, but it must not replace the
strict compile-time check. If retained, it should call one shared validation
predicate and raise a bounded, explicit `ArgumentError`; it should never be the
first place a normal `tool/2` registration is checked.

## Dependency-cycle rule

`Code.ensure_compiled!/1` intentionally exposes real compile cycles. Keep the
dependency direction one way:

```text
application server module -> application tool modules -> TamaMCP contracts
```

A tool module must not require the application server module to be compiled in
order to define its callback or schema. If that reverse dependency appears,
extract the shared value into a third module rather than weakening the compile
check or imposing file order.

Do not use alphabetical file names, sequential compiler settings, manual
requires, sleeps, or retries as cycle/order workarounds.

## Required tests

Add focused Server DSL tests in a dedicated file rather than relying only on
transport tests.

### Positive compilation

- Keep tools and server in separate files under `test/support`.
- From a clean test build, assert that `mix test` compiles the support files and
  the server catalog contains the expected modules in deterministic name order.
- Run the check with normal parallel compilation; do not set
  `--max-requires 1` or otherwise serialize it.

### Negative compilation

Use uniquely named modules compiled from strings/quoted forms so tests do not
pollute or collide with the static support modules.

- A missing module must fail during server compilation via
  `Code.ensure_compiled!/1`.
- A compiled module without the TamaMCP tool exports must raise a `CompileError`
  at the `tool` declaration.
- A module with metadata but without `call/2` must fail at compile time.
- A partially spoofed module missing any other runtime-used export must fail at
  compile time.
- A valid tool in another file must compile and be retrievable through
  `server.tool/1`.
- Duplicate tool names must continue to fail during `__before_compile__/1`.

Assertions should check the error category and actionable message, not an
entire compiler stack trace.

### Clean-build verification

Run at least:

```console
MIX_ENV=test mix clean
mix test --force
mix precommit
mix dialyzer --no-check
```

The PLT must already have been built with `mix dialyzer --plt` as required by
`AGENTS.md`. No `@dialyzer` suppression should be introduced for this change.

## Verified result

This solution was tested in an isolated copy of the current checkout. The
best-effort `Code.ensure_loaded?/1` checks were replaced with one
`Code.ensure_compiled!/1` call followed by strict export checks, and validation
was moved directly into `tool/2` before the catalog attribute was updated.

A clean parallel test compilation then succeeded:

```text
Compiling 15 files (.ex)
Generated tama_mcp app
2 doctests, 22 tests, 0 failures
```

No implementation file in the actual checkout was changed while preparing
this solution.

## Acceptance criteria

Problem 01 is closed only when all of the following are true:

- `test/support` remains on `elixirc_paths(:test)` and stays split by concern;
- `test_pattern` and manual `Code.require_file/2` are not restored;
- `tool/2` establishes the dependency with `Code.ensure_compiled!/1`;
- missing and malformed tool modules fail deterministically at compile time;
- normal parallel clean compilation succeeds without file-order controls;
- Runtime is not the primary tool-registration validator;
- default strict Credo passes without a custom suppression; and
- Dialyzer passes without inline ignores.
