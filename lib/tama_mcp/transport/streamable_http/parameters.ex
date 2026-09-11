defmodule TamaMCP.Transport.StreamableHTTP.Parameters do
  @moduledoc false

  import Plug.Conn, only: [get_req_header: 2]

  alias TamaMCP.Protocol
  alias TamaMCP.Transport.StreamableHTTP.Headers

  @maximum_safe_integer 9_007_199_254_740_991

  def match(conn, %{method: method, name: name, params: params}, server) do
    if method == Protocol.method(:tools_call) do
      match_tool(conn, server.tool(name), Map.get(params, "arguments", %{}))
    else
      :ok
    end
  end

  defp match_tool(_conn, nil, _arguments), do: :ok

  defp match_tool(conn, module, arguments) do
    Enum.reduce_while(module.parameter_headers(), :ok, fn descriptor, _acc ->
      case match_header(conn, descriptor, arguments) do
        :ok -> {:cont, :ok}
        {:error, _error} = error -> {:halt, error}
      end
    end)
  end

  defp match_header(conn, descriptor, arguments) do
    values = get_req_header(conn, descriptor.header)
    value = fetch(arguments, descriptor.path)

    case {value, values} do
      {:absent, []} ->
        :ok

      {{:ok, nil}, []} ->
        :ok

      {:absent, _values} ->
        error(descriptor, "is not expected when the argument is absent")

      {{:ok, nil}, _values} ->
        error(descriptor, "is not expected when the argument is null")

      {{:ok, _value}, []} ->
        error(descriptor, "is required when the argument is present")

      {{:ok, _value}, [_first, _second | _rest]} ->
        error(descriptor, "must be a single value")

      {{:ok, value}, [raw]} ->
        compare(descriptor, value, raw)
    end
  end

  defp compare(descriptor, value, raw) do
    with {:ok, expected} <- stringify(value, descriptor.type),
         {:ok, decoded} <- Headers.decode(raw) do
      if decoded == expected do
        :ok
      else
        error(descriptor, "does not match the corresponding body value")
      end
    else
      {:error, reason} -> error(descriptor, "is malformed: #{reason}")
    end
  end

  defp stringify(value, "string") when is_binary(value), do: {:ok, value}
  defp stringify(true, "boolean"), do: {:ok, "true"}
  defp stringify(false, "boolean"), do: {:ok, "false"}

  defp stringify(value, "integer")
       when is_integer(value) and value >= -@maximum_safe_integer and
              value <= @maximum_safe_integer,
       do: {:ok, Integer.to_string(value)}

  defp stringify(value, "integer") when is_integer(value),
    do: {:error, "integer is outside the IEEE-754 safe range"}

  defp stringify(_value, type), do: {:error, "body value is not a #{type}"}

  defp fetch(arguments, path) do
    Enum.reduce_while(path, {:ok, arguments}, fn key, {:ok, current} ->
      fetch_key(current, key)
    end)
  end

  defp fetch_key(%{} = current, key) do
    case Map.fetch(current, key) do
      {:ok, value} -> {:cont, {:ok, value}}
      :error -> {:halt, :absent}
    end
  end

  defp fetch_key(_not_an_object, _key), do: {:halt, :absent}

  defp error(descriptor, detail) do
    {:error,
     TamaMCP.Error.header_mismatch(
       "Header mismatch: Mcp-Param-#{descriptor.name} header #{detail}"
     )}
  end
end
