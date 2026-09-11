defmodule TamaMCP.Schema.Protocol do
  @moduledoc false

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
    list_tools_response: "ListToolsResultResponse"
  }

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

  @spec validate(kind(), term()) :: :ok | {:error, [String.t()]}
  def validate(kind, value) when is_map_key(@definitions, kind) do
    Schema.validate(validator(kind), value)
  end

  defp validator(kind) do
    key = {__MODULE__, kind}

    case :persistent_term.get(key, :undefined) do
      :undefined ->
        validator = compile!(kind)
        :persistent_term.put(key, validator)
        validator

      validator ->
        validator
    end
  end

  defp compile!(kind) do
    path = Application.app_dir(:tama_mcp, "priv/#{@schema_path}")
    schema = path |> File.read!() |> Jason.decode!()

    root = %{
      "$schema" => schema["$schema"],
      "$defs" => schema["$defs"],
      "$ref" => "#/$defs/#{Map.fetch!(@definitions, kind)}"
    }

    case Schema.compile(root) do
      {:ok, validator} -> validator
      {:error, reason} -> raise Schema.Error, message: reason
    end
  end
end
