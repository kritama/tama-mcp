defmodule TamaMCP.Schema.Protocol do
  @moduledoc false

  alias TamaMCP.Cache.Validator
  alias TamaMCP.Schema

  @schema_path "protocol/2026-07-28/core/schema/2026-07-28/schema.json"
  @definitions %{
    call_tool_request: "CallToolRequest",
    call_tool_result: "CallToolResult",
    call_tool_response: "CallToolResultResponse",
    discover_request: "DiscoverRequest",
    discover_result: "DiscoverResult",
    discover_response: "DiscoverResultResponse",
    error_response: "JSONRPCErrorResponse",
    list_tools_request: "ListToolsRequest",
    list_tools_result: "ListToolsResult",
    list_tools_response: "ListToolsResultResponse",
    result_response: "JSONRPCResultResponse",
    subscriptions_acknowledged_notification: "SubscriptionsAcknowledgedNotification",
    subscriptions_listen_request: "SubscriptionsListenRequest",
    subscriptions_listen_result: "SubscriptionsListenResult",
    subscriptions_listen_response: "SubscriptionsListenResultResponse"
  }

  @schema_file Path.expand("../../../priv/#{@schema_path}", __DIR__)
  @external_resource @schema_file
  @schema @schema_file |> File.read!() |> Jason.decode!()

  @validators Map.new(Enum.sort(@definitions), fn {kind, definition} ->
                root = %{
                  "$schema" => @schema["$schema"],
                  "$defs" => @schema["$defs"],
                  "$ref" => "#/$defs/#{definition}"
                }

                case Schema.compile(root) do
                  {:ok, compiled} -> {kind, Validator.artifact(__MODULE__, kind, compiled)}
                  {:error, reason} -> raise Schema.Error, message: reason
                end
              end)

  @type kind ::
          :call_tool_request
          | :call_tool_result
          | :call_tool_response
          | :discover_request
          | :discover_result
          | :discover_response
          | :error_response
          | :list_tools_request
          | :list_tools_result
          | :list_tools_response
          | :result_response
          | :subscriptions_acknowledged_notification
          | :subscriptions_listen_request
          | :subscriptions_listen_result
          | :subscriptions_listen_response

  @spec validate(kind(), term(), module(), keyword()) :: :ok | {:error, [String.t()]}
  def validate(kind, value, cache, cache_options \\ []) when is_map_key(@definitions, kind) do
    artifact = Map.fetch!(@validators, kind)
    Schema.validate(Validator.fetch(artifact, cache, cache_options), value)
  end
end
