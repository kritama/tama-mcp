defmodule TamaMCP.Protocol do
  @moduledoc """
  Stable identifiers for the protocol and extension implemented by TamaMCP.

  Protocol-specific encoding and dispatch modules will remain internal so the
  public server, tool, context, response, task-store, and notification APIs do
  not inherit wire-format details.
  """

  @version "2026-07-28"
  @tasks_extension "io.modelcontextprotocol/tasks"

  @doc "Returns the MCP protocol version implemented by TamaMCP."
  @spec version() :: String.t()
  def version, do: @version

  @doc "Returns the MCP Tasks extension identifier."
  @spec tasks_extension() :: String.t()
  def tasks_extension, do: @tasks_extension
end
