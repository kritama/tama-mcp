# Contributing

## Development checks

Install the pinned Erlang and Elixir versions with `mise`, then run:

```console
mix deps.get
mix precommit
mix dialyzer --plt
mix dialyzer --no-check
mix docs
mix hex.build
```

`mix precommit` checks formatting, compilation with warnings treated as errors,
Credo strict mode, and tests.

## Git Flow

This repository uses `develop` as the integration and default branch and
`main` as the production branch.

- Start `feature/*` and `fix/*` branches from `develop`.
- Start `release/*` branches from `develop`; merge them into `main` and then
  merge `main` back into `develop`.
- Start `hotfix/*` branches from `main`; merge them into both protected
  branches.

Use Conventional Commits. Changes to protocol fixtures, public modules, DSL
syntax, tool schemas, task semantics, or notification shapes require tests and
an update to the WIP specification or released documentation.

## Project constraints

- Support MCP `2026-07-28` only.
- Do not add Anubis MCP or ex_mcp as dependencies.
- Keep Phoenix, Ecto, web servers, persistence, and application policy outside
  the library.
- Treat official protocol schemas as normative and pin reviewed fixtures.
- Keep task retrieval durable and authorization-bound, never session-bound.
