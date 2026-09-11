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

### Security

- Explicitly reject `Mcp-Session-Id` and legacy initialization methods.
- Validate successful responses against the pinned MCP schema and prevent
  adapter data from entering unbounded transport errors or telemetry.
- Validate complete method-specific requests and schema-declared
  `Mcp-Param-*` header agreement before tool execution.
