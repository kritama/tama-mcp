# Problem 03 — Dialyzer warnings left after removing the three `@dialyzer` suppressions

Date: 2026-09-11

Applies to: the "full cleanup" step of the `review-01.md` remediation — removing the
three inline `@dialyzer {:nowarn_function, ...}` suppressions so `mix dialyzer --no-check`
passes with **zero** suppressions.

## Goal

Remove all three suppressions and fix the underlying issues honestly (no `@dialyzer`,
no `.credo.exs`, no relaxed checks):

1. `lib/tama_mcp/tool.ex` — `@dialyzer {:nowarn_function, [field: 2, field: 3]}` on the
   `field/2,3` misuse guard.
2. `lib/tama_mcp/transport/streamable_http/runtime.ex` — `@dialyzer {:nowarn_function,
   [build: 1]}` on `Runtime.build/1`.
3. `lib/tama_mcp/transport/streamable_http/plug.ex` — `@dialyzer {:nowarn_function,
   [init: 1]}` on `Plug.init/1` (delegates to `Runtime.build/1`).

## What is already resolved in this step

Removing all three at once produced **four** warnings: `no_return` (tool.ex), `pattern_match`
(runtime.ex), and two `invalid_contract` (runtime.ex `build/1` and plug.ex `init/1`).

The **two `invalid_contract` are fixed** by making `Runtime.t()` match what Dialyzer can
actually prove from `keyword()` inputs (every value in `build/1` starts as `term()`):

- `server`/`authorization`/`clock`/`identifier`/`task_store`/`task_runner`/
  `notification_bus`: `module()` → `atom()` (a user-supplied module read from Plug init
  options cannot be proven `module()`; the runtime validators are the real guarantee).
- `safe_metadata`: `{(term(), map() -> map()) | nil}` → `(term(), term() -> any()) | nil`.
- `context_headers`: `[String.t()]` → `[binary()]`.
- Added `fetch_module!/2` (guards `is_atom/1 and not is_nil/1`) and used it to read
  `server` and `authorization`, so their value type is `atom()` rather than `term()`.

After that, both `invalid_contract` warnings are gone.

## What is left (two warnings)

`mix dialyzer --no-check` currently reports (with no `@dialyzer` anywhere in `lib/`):

```
Total errors: 3, Skipped: 1, Unnecessary Skips: 0

lib/tama_mcp/tool.ex:205:7:no_return
  Function field/2 has no local return.

lib/tama_mcp/transport/streamable_http/runtime.ex:1:pattern_match
  The pattern can never match the type.
  Pattern: false
  Type: true
```

(Note the counter oddity: it says **3** errors / **1** skipped, but only **2** warning
blocks are printed and there is no `@dialyzer` left to skip anything. Possibly the
`no_return` for the default-arg `field/2` and the hand-written `field/3` are counted
separately with one de-duplicated as "skipped". I have not been able to confirm.)

### Item A — `tool.ex:205 no_return` (fix identified, not yet applied/verified)

`field/2,3` is an always-raises misuse guard:

```elixir
def field(_name, _type, _opts \\ []) do
  raise CompileError,
    description: "field/3 must be called inside an input_schema/2 or output_schema/2 block"
end
```

The warning is on the **generated** `field/2` (from the `_opts \\ []` default), which calls
`field/3` (always `no_return()`), so `field/2` "has no local return".

My intended fix is an explicit spec:

```elixir
@spec field(atom(), term(), keyword()) :: no_return()
def field(_name, _type, _opts \\ []) do
  raise CompileError, description: "..."
end
```

**Open question:** does a single `@spec field/3 :: no_return()` also silence the generated
`field/2` warning, or does the default-arg wrapper `field/2` need its own spec? I have not
verified this yet because I stopped to document the pattern_match first.

### Item B — `runtime.ex:1 pattern_match` (BLOCKED — cannot locate)

This is the real blocker. It is a `false`-vs-`true` pattern-match warning (an `if`/`unless`
branch whose condition Dialyzer believes is the literal `true`), but Dialyzer attributes it
to `runtime.ex:1` (the `defmodule` line), so I cannot tell which function/line it is in.

Facts established:

- It is **new**: the baseline (with the three suppressions) reported `Total errors: 0`, so
  this warning only appeared after my `@type t` + `fetch_module!` change.
- It is **not** in `build/1`: re-adding only the `@dialyzer` on `build/1` left the
  `pattern_match` in place.
- I tried suppressing every helper except `build/1`
  (`fetch_module`, `validate_server`, `validate_authorization`, `validate_tool_policies`,
  `validate_catalog_size`, `validate_safe_metadata`, `validate_context_headers`,
  `validate_limits`) to see if it vanished; the filtered run returned no matches, which
  *suggests* it is in one of those helpers, but the output was ambiguous so I did not
  rely on it.

Main hypothesis: `fetch_module!/2` narrows `server`/`authorization` to a **non-nil `atom()`**
before `build/1` calls `validate_server!/1` / `validate_authorization!/1`. Those validators
begin with:

```elixir
unless is_atom(server) and not is_nil(server) and Code.ensure_loaded?(server)
       and function_exported?(server, :tools, 0) and ... do
  raise ArgumentError, ...
end
```

With `server` already known to be a non-nil atom, `is_atom(server)` and `not is_nil(server)`
are each the literal `true`. My reasoning says the *rest* of the `and` chain
(`Code.ensure_loaded?/1`, `function_exported?/3`) is still `boolean()`, so the whole
condition should be `boolean()` (branch reachable), **not** the literal `true` that the
warning reports — so I cannot reconcile the reasoning with the warning. That mismatch is
exactly where I am stuck.

## Questions / where I need help

1. **Localization:** how do I get Dialyzer/dialyxir to report the exact function and line for
   a `pattern_match` that is otherwise attributed to the module (`runtime.ex:1`)? Is there a
   `:dialyzer` option or dialyxir flag for more precise `pattern_match` locations?
2. **Root fix:** given the narrowing, is the intended fix to restructure
   `validate_server!/1` / `validate_authorization!/1` (drop the now-redundant
   `is_atom/1`/`is_nil/1` checks because `fetch_module!/2` already guarantees a non-nil
   atom), or to change how `fetch_module!/2` is typed/called? I do not want to add a
   suppression.
3. **Counter:** does the `Total errors: 3, Skipped: 1` (with no `@dialyzer` present) indicate
   a third hidden warning I should be looking for, or is it just Dialyzer de-duplicating the
   `field/2`/`field/3` `no_return`?

## Current file state for this step

- `lib/tama_mcp/tool.ex`: `@dialyzer [field: 2, field: 3]` removed (comment updated).
  `field/2,3` still unmodified otherwise (Item A spec not yet added).
- `lib/tama_mcp/transport/streamable_http/runtime.ex`: `@dialyzer [build: 1]` removed;
  `@type t` module fields changed to `atom()` (and `safe_metadata`/`context_headers` relaxed
  as above); `fetch_module!/2` added and used for `server`/`authorization`. No `@dialyzer`
  remains (the bisection suppression was reverted).
- `lib/tama_mcp/transport/streamable_http/plug.ex`: `@dialyzer [init: 1]` removed; `init/1`
  unchanged (`Runtime.build(opts)`).

## Verification state

- `mix compile --warnings-as-errors`: passes (exit 0).
- `mix credo --strict`: passes, no issues (all Credo findings from earlier in this session are fixed).
- `MIX_ENV=test mix test`: 2 doctests, 35 tests, 0 failures.
- `mix dialyzer --no-check`: **fails** with the two warnings above (Item A + Item B).
