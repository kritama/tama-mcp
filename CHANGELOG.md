# Changelog

All notable changes to this project will be documented in this file.

The project follows Semantic Versioning and uses Conventional Commits.

## [Unreleased]

### Added

- Initial Elixir library foundation.
- MCP `2026-07-28` and Tasks extension identifiers.
- Architecture and implementation specification.
- Compile-time server and synchronous tool DSLs with Draft 2020-12 schemas.
- Stateless Streamable HTTP support for `server/discover`, `tools/list`, and
  `tools/call`.
- Per-request authorization, scope-aware tool visibility, normalized request
  contexts, bounded errors, and telemetry.
- Vendored Phase 1 wire fixtures and reusable `TamaMCP.Conformance` validators.
- Explicit JSON `null` support for structured tool results.
- An application-owned validator cache behaviour with versioned TamaMCP cache
  keys and compile-time serialized tool and protocol validator artifacts.

### Security

- Explicitly reject `Mcp-Session-Id` and legacy initialization methods.
- Validate successful responses against the pinned MCP schema and prevent
  adapter data from entering unbounded transport errors or telemetry.
- Validate complete method-specific requests and schema-declared
  `Mcp-Param-*` header agreement before tool execution, including exact numeric
  comparison of equivalent integer representations in headers and JSON bodies.
- Bound every encoded successful result and reject adapter-specific structs
  from public response and error data.
- Accept empty raw output schemas while rejecting explicitly declared JSON
  Schema dialects other than Draft 2020-12.
- Normalize authorization exits and throws without exposing adapter failure
  details.
- Tie synchronous tool workers to their request lifetime and execution deadline.
- Combine repeated list-valued `Accept` fields while retaining strict handling
  for single-valued transport headers.
- Reject unsafe `MCP-Protocol-Version` and `Mcp-Method` header characters before
  version negotiation or header/body comparison.
- Validate OAuth scope-token syntax and reject oversized insufficient-scope
  challenges during transport initialization.
