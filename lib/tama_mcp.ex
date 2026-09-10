defmodule TamaMCP do
  @moduledoc """
  Tama-focused MCP 2026-07-28 server primitives.

  `TamaMCP` is deliberately server-only and implements one MCP protocol era.
  It does not provide legacy session compatibility, an MCP client, application
  persistence, or application authorization policy.
  """

  @doc """
  Returns the only MCP protocol version implemented by this package.

  ## Examples

      iex> TamaMCP.protocol_version()
      "2026-07-28"

  """
  defdelegate protocol_version, to: TamaMCP.Protocol, as: :version

  @doc """
  Returns the reverse-DNS identifier for the MCP Tasks extension.

  ## Examples

      iex> TamaMCP.tasks_extension()
      "io.modelcontextprotocol/tasks"

  """
  defdelegate tasks_extension, to: TamaMCP.Protocol
end
