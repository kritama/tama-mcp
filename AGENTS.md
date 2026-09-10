# TamaMCP agent instructions

This is an Elixir library implementing a focused MCP `2026-07-28` server
runtime.

## Required checks

- Run `mix precommit` after changes and fix all failures.
- Run focused tests while iterating.
- Build the Dialyzer PLT with `mix dialyzer --plt`, then run
  `mix dialyzer --no-check` for changes to public types or behaviours.
- Run `mix docs` and `mix hex.build` when changing package metadata or public
  documentation.

## Architecture constraints

- Implement MCP `2026-07-28` only. Do not add legacy initialization, sessions,
  `Mcp-Session-Id`, `tasks/result`, or `tasks/list`.
- Do not depend on Anubis MCP or ex_mcp.
- Keep the package server-only; Tama Link owns client compatibility.
- Keep Phoenix, Ecto, databases, queues, and web servers outside the package.
- Compose `tama_oauth`; do not reimplement OAuth or application authorization
  policy.
- Treat durable task storage and clustered notification delivery as adapter
  behaviours.
- Authenticate every request and bind task access to the validated owner. Do
  not use protocol sessions for task ownership.
- Publish task notifications only after durable state commits. Notifications
  are hints; `tasks/get` is the recovery source of truth.
- Keep JSON responses, errors, logs, and telemetry bounded and free of secrets
  or adapter-specific structs.

Read `wip/tama-mcp-specification.md` before implementing protocol behavior.
