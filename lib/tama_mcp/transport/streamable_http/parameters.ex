defmodule TamaMCP.Transport.StreamableHTTP.Parameters do
  @moduledoc false

  import Plug.Conn, only: [get_req_header: 2]

  alias TamaMCP.Protocol
  alias TamaMCP.Transport.StreamableHTTP.Headers

  @maximum_safe_integer 9_007_199_254_740_991
  @decimal_number ~r/\A(?<sign>[+-]?)(?<whole>[0-9]+)(?:\.(?<fraction>[0-9]+))?(?:[eE](?<exponent>[+-]?[0-9]+))?\z/

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
    with {:ok, expected} <- comparable(value, descriptor.type),
         {:ok, decoded} <- Headers.decode(raw),
         {:ok, matches?} <- matches(decoded, expected, descriptor.type) do
      if matches? do
        :ok
      else
        error(descriptor, "does not match the corresponding body value")
      end
    else
      {:error, reason} -> error(descriptor, "is malformed: #{reason}")
    end
  end

  defp comparable(value, "string") when is_binary(value), do: {:ok, value}
  defp comparable(true, "boolean"), do: {:ok, "true"}
  defp comparable(false, "boolean"), do: {:ok, "false"}

  defp comparable(value, "integer")
       when is_integer(value) and value >= -@maximum_safe_integer and
              value <= @maximum_safe_integer,
       do: {:ok, value}

  defp comparable(value, "integer") when is_integer(value),
    do: {:error, "integer is outside the IEEE-754 safe range"}

  defp comparable(_value, type), do: {:error, "body value is not a #{type}"}

  defp matches(decoded, expected, "integer") do
    case Regex.named_captures(@decimal_number, decoded) do
      nil -> {:error, "integer header is not a decimal number"}
      captures -> {:ok, decimal_matches_integer?(captures, expected)}
    end
  end

  defp matches(decoded, expected, _type), do: {:ok, decoded == expected}

  defp decimal_matches_integer?(captures, expected) do
    coefficient = String.trim_leading(captures["whole"] <> captures["fraction"], "0")
    negative? = captures["sign"] == "-"
    expected_negative? = expected < 0

    cond do
      coefficient == "" ->
        expected == 0

      expected == 0 ->
        false

      negative? != expected_negative? ->
        false

      true ->
        {significant, trailing_zeros} = strip_trailing_zeros(coefficient)

        {expected_significant, expected_trailing_zeros} =
          expected
          |> abs()
          |> Integer.to_string()
          |> strip_trailing_zeros()

        required_exponent =
          expected_trailing_zeros - trailing_zeros + byte_size(captures["fraction"])

        significant == expected_significant and
          exponent_matches?(captures["exponent"], required_exponent)
    end
  end

  defp strip_trailing_zeros(digits) do
    significant = String.trim_trailing(digits, "0")
    {significant, byte_size(digits) - byte_size(significant)}
  end

  defp exponent_matches?("", expected), do: expected == 0

  defp exponent_matches?(actual, expected) do
    actual
    |> normalize_signed_integer()
    |> Kernel.==(Integer.to_string(expected))
  end

  defp normalize_signed_integer(value) do
    {sign, digits} =
      case value do
        <<sign, rest::binary>> when sign in [?+, ?-] -> {sign, rest}
        digits -> {?+, digits}
      end

    case String.trim_leading(digits, "0") do
      "" -> "0"
      digits when sign == ?- -> "-" <> digits
      digits -> digits
    end
  end

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
