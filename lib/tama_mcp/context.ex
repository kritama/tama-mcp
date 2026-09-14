defmodule TamaMCP.Context do
  @moduledoc """
  Normalized, request-scoped data passed to every tool call.

  The context contains only values the transport explicitly normalized.
  Arbitrary Plug assigns and raw request headers are never copied here; the
  host application selects the safe header values it wants exposed.

  A context must survive transfer into asynchronous task execution.
  Authorization claims, scopes, request identity, and the caller binding must
  not disappear when a tool becomes a task.
  """

  defstruct [
    :request_id,
    :protocol_version,
    :method,
    :name,
    :client_info,
    :client_capabilities,
    :principal,
    :owner_key,
    :claims,
    :scopes,
    :headers,
    :remote_address,
    :task_id,
    :assigns
  ]

  @type t :: %__MODULE__{
          request_id: String.t() | integer(),
          protocol_version: String.t(),
          method: String.t(),
          name: String.t() | nil,
          client_info: map() | nil,
          client_capabilities: map(),
          principal: term(),
          owner_key: term(),
          claims: map(),
          scopes: [String.t()],
          headers: map(),
          remote_address: String.t() | nil,
          task_id: String.t() | nil,
          assigns: map()
        }
end
