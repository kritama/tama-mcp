defmodule TamaMCP.Schema.Protocol do
  @moduledoc false

  alias TamaMCP.Schema

  @schema_path "protocol/2026-07-28/core/schema/2026-07-28/schema.json"

  @spec validate(:call_tool_result, term()) :: :ok | {:error, [String.t()]}
  def validate(:call_tool_result, value) do
    Schema.validate(validator(), value)
  end

  defp validator do
    key = {__MODULE__, :call_tool_result}

    case :persistent_term.get(key, :undefined) do
      :undefined ->
        validator = compile!()
        :persistent_term.put(key, validator)
        validator

      validator ->
        validator
    end
  end

  defp compile! do
    path = Application.app_dir(:tama_mcp, "priv/#{@schema_path}")
    schema = path |> File.read!() |> Jason.decode!()

    root = %{
      "$schema" => schema["$schema"],
      "$defs" => schema["$defs"],
      "$ref" => "#/$defs/CallToolResult"
    }

    case Schema.compile(root) do
      {:ok, validator} -> validator
      {:error, reason} -> raise Schema.Error, message: reason
    end
  end
end
