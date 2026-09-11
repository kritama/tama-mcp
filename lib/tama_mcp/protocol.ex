defmodule TamaMCP.Protocol do
  @moduledoc """
  Stable identifiers for the protocol and extension implemented by TamaMCP.

  Every constant in this module is fixed by the pinned protocol revisions
  recorded in `priv/protocol/2026-07-28/manifest.json`. Do not derive these
  values from client input or from unpinned upstream sources.

  Protocol-specific encoding and dispatch modules remain internal so the
  public server, tool, context, response, task-store, and notification APIs do
  not inherit wire-format details.
  """

  @version "2026-07-28"
  @tasks_extension "io.modelcontextprotocol/tasks"

  @methods %{
    server_discover: "server/discover",
    tools_list: "tools/list",
    tools_call: "tools/call",
    tasks_get: "tasks/get",
    tasks_update: "tasks/update",
    tasks_cancel: "tasks/cancel",
    subscriptions_listen: "subscriptions/listen"
  }

  @headers %{
    protocol_version: "MCP-Protocol-Version",
    method: "Mcp-Method",
    name: "Mcp-Name"
  }

  @meta_keys %{
    protocol_version: "io.modelcontextprotocol/protocolVersion",
    client_info: "io.modelcontextprotocol/clientInfo",
    client_capabilities: "io.modelcontextprotocol/clientCapabilities",
    server_info: "io.modelcontextprotocol/serverInfo",
    subscription_id: "io.modelcontextprotocol/subscriptionId"
  }

  @result_types %{
    complete: "complete",
    input_required: "input_required",
    task: "task"
  }

  @task_statuses %{
    working: "working",
    input_required: "input_required",
    completed: "completed",
    failed: "failed",
    cancelled: "cancelled"
  }

  @error_codes %{
    parse: -32_700,
    invalid_request: -32_600,
    method_not_found: -32_601,
    invalid_params: -32_602,
    internal: -32_603,
    header_mismatch: -32_020,
    missing_required_client_capability: -32_021,
    unsupported_protocol_version: -32_022
  }

  @doc "Returns the MCP protocol version implemented by TamaMCP."
  @spec version() :: String.t()
  def version, do: @version

  @doc "Returns the list of MCP protocol versions supported by TamaMCP."
  @spec supported_versions() :: [String.t()]
  def supported_versions, do: [@version]

  @doc "Returns the MCP Tasks extension identifier."
  @spec tasks_extension() :: String.t()
  def tasks_extension, do: @tasks_extension

  @doc "Returns the JSON-RPC method name for a known protocol method atom."
  @spec method(atom()) :: String.t()
  def method(name) when is_atom(name), do: Map.fetch!(@methods, name)

  @doc "Returns the set of known protocol method atoms and their names."
  @spec methods() :: %{atom() => String.t()}
  def methods, do: @methods

  @doc """
  Returns the set of method atoms whose `Mcp-Name` header carries the tool
  name (`tools/call`) or the task ID (`tasks/get`, `tasks/update`,
  `tasks/cancel`).
  """
  @spec name_scoped_methods() :: [atom()]
  def name_scoped_methods, do: [:tools_call, :tasks_get, :tasks_update, :tasks_cancel]

  @doc "Returns the standard HTTP header name for a known header atom."
  @spec header(atom()) :: String.t()
  def header(name) when is_atom(name), do: Map.fetch!(@headers, name)

  @doc "Returns the case-insensitive lookup key for a standard header atom."
  @spec header_key(atom()) :: String.t()
  def header_key(name) when is_atom(name), do: String.downcase(Map.fetch!(@headers, name))

  @doc "Returns the `_meta` key for a known metadata field atom."
  @spec meta_key(atom()) :: String.t()
  def meta_key(name) when is_atom(name), do: Map.fetch!(@meta_keys, name)

  @doc "Returns the wire value of a known result type atom."
  @spec result_type(atom()) :: String.t()
  def result_type(name) when is_atom(name), do: Map.fetch!(@result_types, name)

  @doc "Returns the wire value of a known task status atom."
  @spec task_status(atom()) :: String.t()
  def task_status(name) when is_atom(name), do: Map.fetch!(@task_statuses, name)

  @doc "Returns the set of known task status wire values."
  @spec task_statuses() :: [String.t()]
  def task_statuses, do: Map.values(@task_statuses)

  @doc "Returns the JSON-RPC error code for a known error kind atom."
  @spec error_code(atom()) :: integer()
  def error_code(kind) when is_atom(kind), do: Map.fetch!(@error_codes, kind)
end
