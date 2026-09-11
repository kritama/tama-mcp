# Solution 02 — validate literal AST before evaluating it

Date: 2026-09-11

Applies to: `wip/tama-mcp-specification/problems-02.md`

## Decision

The implementer's `reraise/2` resolution is syntactically valid, and a focused
`mix credo --strict lib/tama_mcp/tool.ex` run confirms that it removes
`RaiseInsideRescue`. It does not resolve the underlying DSL problem and should
not be retained.

Reopen Problem 02. Replace the rescue/reraise approach with an explicit
`Macro.quoted_literal?/1` check before `Code.eval_quoted/3`. Once non-literal AST
is rejected before evaluation, remove the rescue entirely.

Official reference:
[`Macro.quoted_literal?/1`](https://hexdocs.pm/elixir/Macro.html#quoted_literal?/1).

## Why the current resolution is incomplete

The current function still evaluates the expression first:

```elixir
{value, _env} = Code.eval_quoted(expr, [])
```

It raises a replacement `CompileError` only when evaluation fails. Therefore a
non-literal expression that evaluates successfully is accepted as though it
were a literal.

This was confirmed against the current checkout. The following schema
declaration compiles successfully:

```elixir
input_schema do
  field(:value, String.to_atom("string"))
end
```

The resulting input schema contains `%{"type" => "string"}`. The function call
was executed at compile time even though the error contract says field
arguments must be compile-time literals.

That behavior has four problems:

1. successful arbitrary expressions bypass the intended literal-only contract;
2. compile-time function calls may have side effects or depend on mutable
   environment state, making tool definitions less deterministic;
3. failures inside valid-looking expressions are all mislabeled as
   "must be compile-time literals," hiding the real failure; and
4. the replacement `%CompileError{}` has no caller file/line, while the reused
   stacktrace points into evaluation rather than clearly identifying the DSL
   declaration.

`reraise/2` preserves the supplied stack frames. It does not preserve a causal
chain containing both the original exception and the replacement exception.
Using it with a different exception merely satisfies Credo mechanically here.

## Required semantics

The implementation must decide between two different contracts:

- **literal syntax**, where strings, numbers, atoms, lists, tuples, maps, and
  other Elixir literal forms are accepted; or
- **arbitrary compile-time expressions**, where calls, variables, and mutable
  environment lookups may execute during compilation.

The module documentation, diagnostics, and `review-01.md` specify literal
syntax. Implement that contract. Do not silently broaden it to arbitrary
compile-time evaluation.

`Macro.quoted_literal?/1` is the standard predicate for this boundary. It
recursively recognizes quoted literal values and rejects calls and variables.
Only after it returns `true` should the literal AST be converted into its value.

## Recommended implementation

Rename `eval_literal!/1` to describe the contract rather than the mechanism,
and pass the macro caller environment so compile errors point at application
code:

```elixir
defp literal_value!(expr, caller, label) do
  unless Macro.quoted_literal?(expr) do
    raise CompileError,
      file: caller.file,
      line: caller.line,
      description: "#{label} must be a literal, got: #{Macro.to_string(expr)}"
  end

  {value, _binding} = Code.eval_quoted(expr, [], caller)
  value
end
```

There is deliberately no `rescue`. For AST accepted by
`Macro.quoted_literal?/1`, evaluation is limited to materializing that literal.
If the compiler itself unexpectedly cannot materialize an accepted literal,
the original exception should surface rather than being incorrectly classified
as user-supplied non-literal syntax.

Thread `__CALLER__` through each macro path:

```elixir
defmacro input_schema(opts \\ [], do: block) do
  fields = collect_fields(block, __CALLER__)
  schema_opts = literal_value!(opts, __CALLER__, "input_schema options")

  # Validate schema_opts before emitting the module attribute.
  # ...
end

defmacro output_schema(opts \\ [], do: block) do
  fields = collect_fields(block, __CALLER__)
  schema_opts = literal_value!(opts, __CALLER__, "output_schema options")

  # ...
end

defmacro raw_input_schema(schema_ast) do
  schema = literal_schema!(schema_ast, "raw_input_schema", __CALLER__)

  quote do
    @tama_mcp_input_schema {:raw, unquote(Macro.escape(schema))}
  end
end
```

Update the internal call chain consistently:

```text
input_schema/output_schema
  -> collect_fields(block, caller)
  -> parse_field_args(args, caller)
  -> literal_value!(expression, caller, label)

raw_input_schema/raw_output_schema
  -> literal_schema!(expression, name, caller)
  -> literal_value!(expression, caller, label)
```

The exact option extraction in the illustrative snippet should follow the
separate DSL-hardening work. The important part for Problem 02 is that every
value advertised as literal crosses the same predicate before evaluation.

## Error location

Using only `caller.line` is acceptable initially and is already better than the
current location-less `%CompileError{}`. A refined helper may prefer the
expression or enclosing `field` call's `:line` metadata when present:

```elixir
defp source_line({_, meta, _}, caller) when is_list(meta) do
  Keyword.get(meta, :line, caller.line)
end

defp source_line(_expr, caller), do: caller.line
```

Do not add another rescue merely to customize the location. Construct the
`CompileError` before evaluation when the predicate rejects the AST.

## Module attributes and aliases

Under a literal-only contract, a module attribute reference such as `@schema`
is syntax for reading a value, not itself a quoted literal. It should be
rejected unless the public DSL explicitly promises module-attribute support.

Do not call unrestricted `Macro.expand/2` as a general workaround: expansion
can invoke macros and reintroduce compile-time execution. If module attributes
are required later, add a narrow, documented path that reads only an already
defined attribute and then validates the resulting term as a non-empty,
JSON-safe schema map. Cover that feature with dedicated positive and negative
tests.

Aliases inside ordinary schema maps are not needed for the current JSON Schema
contract. Struct literals recognized by Elixir may still be rejected later by
the existing schema/JSON-safety validation if they are not valid JSON Schema
values.

## Required tests

Add focused Tool DSL tests. The current transport and Server tests do not cover
this semantic boundary.

### Accepted literals

- atom field names;
- primitive type atoms;
- `{:enum, [...]}` and `{:array, ...}` literal tuples;
- literal keyword options;
- nested literal maps/lists for raw schemas; and
- direct literal input and output schemas.

### Rejected expressions

- a successful remote call such as `String.to_atom("string")`;
- a local or imported function call;
- a variable reference;
- string concatenation or another operator expression;
- a module attribute, unless explicitly supported; and
- a function call that would have a side effect.

For the side-effect case, use a test helper whose function sends a message or
increments an Agent. Assert that compilation raises before the helper is ever
called. This proves the implementation validates AST rather than merely
converting failures after execution.

### Diagnostics

- assert `CompileError` rather than a rescued runtime exception;
- assert the message names the field/schema component and prints the rejected
  expression;
- assert the error file and line identify the DSL declaration; and
- avoid assertions over the entire stacktrace.

## Verification

The literal-predicate version was tested in an isolated copy of the checkout:

- `mix format --check-formatted lib/tama_mcp/tool.ex` passed;
- the existing suite passed with 2 doctests and 22 tests; and
- focused strict Credo no longer reported `RaiseInsideRescue`.

The current implementer's version also passes focused Credo and the current 26
focused tests, but those tests do not catch the successful-non-literal case;
the runtime probe above confirms the semantic gap.

After adding the missing tests, run the project-required checks:

```console
mix precommit
mix dialyzer --no-check
```

Build the PLT first with `mix dialyzer --plt` if it is not current. This change
must not introduce `.credo.exs`, a disabled Credo check, or an inline Dialyzer
suppression.

## Acceptance criteria

Problem 02 is resolved only when:

- non-literal AST is rejected before any evaluation;
- successful function calls can no longer masquerade as literals;
- the broad rescue/reraise block is gone;
- literal schema forms continue to compile;
- diagnostics point to the caller's file and line;
- side-effect tests prove rejected expressions are never executed;
- focused and full strict Credo pass without project-specific suppression; and
- the complete required test and Dialyzer checks pass.
