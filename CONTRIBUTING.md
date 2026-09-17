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

## Releases

Releases follow the Git Flow release cycle. CI runs on pull requests and
`develop` pushes; a single release workflow runs on `main` pushes and publishes
only when a new version lands.

```console
git flow release start 0.1.0
```

On the `release/*` branch:

- set the new version in `mix.exs`; and
- finalize `CHANGELOG.md` with a `## [<version>]` section.

Open a pull request from `release/*` to `main`. Merging it triggers one full
verification run (`hex.audit`, `precommit`, Dialyzer, `docs`, `hex.build`).
When the workflow succeeds and the merge commit introduces a version without an
existing `v<version>` tag, it creates the tag, publishes the package and
documentation to Hex, and creates a GitHub release from the matching
`CHANGELOG.md` section. The `hex` environment records a deployment with its
final status for every workflow run. `main` is then ready to merge back into
`develop`:

```console
git flow release finish 0.1.0
```

Merges to `main` that do not change the package version run the same checks but
publish nothing.

## Project constraints

- Support MCP `2026-07-28` only.
- Do not add Anubis MCP or ex_mcp as dependencies.
- Keep Phoenix, Ecto, web servers, persistence, and application policy outside
  the library.
- Treat official protocol schemas as normative and pin reviewed fixtures.
- Keep task retrieval durable and authorization-bound, never session-bound.
