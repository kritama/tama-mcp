# Problem 02 — Credo `RaiseInsideRescue` in `eval_literal!/1` (exception conversion inside `rescue`)

**Status:** Resolved (recorded per the "write it down when stuck" instruction).
**Component:** `TamaMCP.Tool.eval_literal!/1` (`lib/tama_mcp/tool.ex`), part of the
"default strict Credo passes" acceptance criterion.

## Problem

`eval_literal!/1` evaluates a schema-field expression and converts any failure into a
helpful `CompileError`:

```elixir
defp eval_literal!(expr) do
  {value, _env} = Code.eval_quoted(expr, [])
  value
rescue
  _ ->
    raise CompileError, description: "schema field arguments must be compile-time literals: ..."
end
```

Credo's `RaiseInsideRescue` check (default, `--strict`) flags the `raise` inside the
`rescue` block: "Use `reraise` inside a rescue block to preserve the original
stacktrace." The fix must **replace** the caught exception with a different, more
actionable `CompileError` while still satisfying the check.

## What I was stuck on

The exact Elixir 1.19 idiom for re-raising a *different* exception from inside a
`rescue` while preserving the stacktrace. These attempts all failed:

| Attempt | Result |
| --- | --- |
| `raise %CompileError{...}, from_raise: e` | `ArgumentError` — `from_raise:` is not a `raise/2` option here |
| `reraise %CompileError{...}` | `UndefinedFunctionError` — `reraise` is arity 2 |
| `reraise CompileError.exception("..."), Process.stacktrace()` | `FunctionClauseError` (`exception/1`) + `Process.stacktrace/0` undefined |

## Resolution

Inside a `rescue`/`catch` block, Elixir exposes the caught exception's stacktrace as
the special variable `__STACKTRACE__`. Re-raise the replacement exception with it:

```elixir
rescue
  _ ->
    reraise %CompileError{description: "schema field arguments must be compile-time literals: #{Macro.to_string(expr)}"},
            __STACKTRACE__
end
```

Verified: this raises a `CompileError` with the intended message and satisfies
Credo's `RaiseInsideRescue` (uses `reraise`).

## Takeaway

- `reraise/2` = `reraise(exception, stacktrace)`; the stacktrace in a rescue is
  `__STACKTRACE__`, not `Process.stacktrace/0` (which does not exist).
- Build the replacement exception as a struct literal (`%CompileError{description: ...}`),
  not via `CompileError.exception/1`.
