# Problem 01 — `tool/2` cannot require tool modules to be pre-compiled across files

**Status:** Unresolved (has a working mitigation, not a clean fix).
**Component:** `TamaMCP.Server` DSL (`tool/2` / `__tool__/3`) + Mix `elixirc_paths` compilation order.
**Introduced by:** splitting `test/support/fixtures.ex` into per-concern files
(`tools.ex`, `authorization.ex`, `server.ex`) compiled via `elixirc_paths(:test)`,
per `review-01.md` step 1.

## Symptom

When the test-support server references tool modules that live in a *different*
support file, compiling the `:test` env fails:

```
== Compilation error in file test/support/server.ex ==
** (CompileError) module TamaMCP.TestSupport.Tools.Echo is not a compiled TamaMCP tool (missing tool_metadata/0).
    lib/tama_mcp/server.ex:107: TamaMCP.Server.__tool__/3
    test/support/server.ex:9: (module)
```

The same `TamaMCP.TestSupport.Server` + tools compile cleanly when they are in the
*same* file (the original single `fixtures.ex`, loaded with `Code.require_file/1`).

## Root cause

`tool/2` is a macro that runs `TamaMCP.Server.__tool__/3` at **expansion time** and
performs `Code.ensure_loaded?(tool_module)`. That call can only return `true` if the
tool module's `.beam` has already been produced.

The Mix/Elixir compiler (`Code.compile_files`, which is what `elixirc_paths` compiles
through) compiles the files in a batch and does **not** guarantee that a module
referenced only through a DSL macro's argument is compiled before the module that
references it. The reason the dependency is not enforced:

- `tool/2` calls `Macro.expand/2`, turning the `TamaMCP.TestSupport.Tools.Echo` alias
  into a bare atom, and the `__before_compile__`-generated catalog re-emits that atom
  inside a data literal (`Macro.escape(catalog)`).
- A module atom sitting inside a data literal is not treated as a hard compile-order
  dependency. The only construct that forces a guaranteed "compile `X` before `Y`"
  ordering is `@behaviour X`, and tools are not behaviours.

So the relative compile order of `server.ex` and `tools.ex` is not what the strict
check requires, and `Code.ensure_loaded?(Echo)` is `false` when `server.ex` expands.

Verified from the actual project:

| Layout | `__tool__` check | Result |
| --- | --- | --- |
| Single `fixtures.ex` (`Code.require_file`) | strict | compiles, 22 tests pass |
| Split files + `elixirc_paths(:test)` | strict | **compile error** (above) |
| Split files + `elixirc_paths(:test)` | best-effort | compiles, 24 tests pass |

## Why it cannot be fixed cleanly

- **Cannot force ordering from the DSL.** The referencing (server) module cannot
  declare a hard compile-order dependency on an arbitrary set of tool modules through
  the macro. The only guaranteed mechanism (`@behaviour`) does not apply — a tool is
  a callable tool, not a behaviour the server implements.
- **Cannot rely on file naming / path.** The batch order is not alphabetical or
  path-based in a way that puts `tools.ex` before `server.ex`.
- **`Code.ensure_loaded!/1` is not a fix.** It only converts the failure into a
  different error; the ordering guarantee is still missing.
- **Deferring the check into `__before_compile__` does not help.** That callback runs
  during the *same* compilation of the server file, i.e. still before the tool file's
  `.beam` exists in the failing order.

## Current mitigation (in place)

`TamaMCP.Server.__tool__/3` is **best-effort**: it validates a tool module
(`tool_metadata/0`, `call/2`) **only if the module is already loaded**, and otherwise
records the registration and defers correctness to runtime:

```elixir
if Code.ensure_loaded?(tool_module) do
  unless function_exported?(tool_module, :tool_metadata, 0) do
    raise CompileError, ...
  end
end
```

This makes the split support files compile and the full test suite pass.

**Trade-off:** a typo'd or non-tool module (`tool(WrongModule, name: "x")`) no longer
produces a clear compile-time error; it only surfaces when the runtime is built.
`TamaMCP.Transport.StreamableHTTP.Runtime.build/1` currently calls `entry.module.task_policy/0`
on each catalog entry, so an invalid module fails at runtime with an *opaque*
`UndefinedFunctionError` rather than a clean, actionable error.

## Options to close it properly (not yet done)

1. **Add a clean runtime validation** in `Runtime.build/1` (e.g. `validate_tool_modules!/1`)
   that checks each catalog entry's module exports `tool_metadata/0`, `call/2` and
   `task_policy/0` and raises a clear `ArgumentError`. Pairs well with the current
   best-effort check; recommended.
2. **Revert to a single support file** (original behavior). Loses the review-01
   organization goal.
3. **Stop using the DSL in test support** and build the runtime config directly in the
   tests. Stops exercising the `tool/2` DSL in the suite.
