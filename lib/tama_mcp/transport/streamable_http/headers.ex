defmodule TamaMCP.Transport.StreamableHTTP.Headers do
  @moduledoc false

  import Plug.Conn, only: [get_req_header: 2]

  alias TamaMCP.Protocol

  @base64_sentinel ~r/\A=\?base64\?.*\?=\z/
  @session_header "mcp-session-id"

  def validate_version(conn) do
    with :ok <- reject_session(conn) do
      validate_protocol_version(conn)
    end
  end

  defp validate_protocol_version(conn) do
    version = Protocol.version()

    case get_req_header(conn, Protocol.header_key(:protocol_version)) do
      [] -> {:error, mismatch(Protocol.header(:protocol_version) <> " header is required")}
      [^version] -> :ok
      [value] -> {:error, TamaMCP.Error.unsupported_protocol_version(value)}
      _ -> {:error, mismatch(Protocol.header(:protocol_version) <> " must be a single value")}
    end
  end

  defp reject_session(conn) do
    case get_req_header(conn, @session_header) do
      [] -> :ok
      _values -> {:error, mismatch("Mcp-Session-Id is not supported")}
    end
  end

  def match(conn, request) do
    with :ok <- match_method(conn, request),
         {:ok, name} <- match_name(conn, request) do
      {:ok, %{request | name: name}}
    end
  end

  defp match_method(conn, request) do
    case get_req_header(conn, Protocol.header_key(:method)) do
      [] ->
        {:error, mismatch("Mcp-Method header is required")}

      [method] when method == request.method ->
        :ok

      [method] ->
        {:error,
         mismatch(
           "Mcp-Method header #{inspect(method)} does not match #{inspect(request.method)}"
         )}

      _ ->
        {:error, mismatch("Mcp-Method header must be a single value")}
    end
  end

  defp match_name(conn, request) do
    values = get_req_header(conn, Protocol.header_key(:name))
    expected = expected_name(request)

    case {expected, values} do
      {:unscoped, []} ->
        {:ok, nil}

      {:unscoped, _} ->
        {:error, mismatch("Mcp-Name header is not expected for #{inspect(request.method)}")}

      {{:scoped, _source, _expected}, []} ->
        {:error, mismatch("Mcp-Name header is required for #{inspect(request.method)}")}

      {{:scoped, _source, _expected}, [_first, _second | _]} ->
        {:error, mismatch("Mcp-Name header must be a single value")}

      {{:scoped, _source, expected}, [raw]} when is_binary(expected) ->
        compare_name(raw, expected)

      {{:scoped, source, _expected}, [_raw]} ->
        {:error, mismatch("Mcp-Name source params.#{source} must be a string")}
    end
  end

  defp compare_name(raw, expected) do
    case decode(raw) do
      {:ok, ^expected} ->
        {:ok, expected}

      {:ok, decoded} ->
        {:error,
         mismatch("Mcp-Name header #{inspect(decoded)} does not match #{inspect(expected)}")}

      {:error, reason} ->
        {:error, mismatch("Mcp-Name header is malformed: #{reason}")}
    end
  end

  defp expected_name(%{method: method, params: params}) do
    case Protocol.name_source(method) do
      nil -> :unscoped
      source -> {:scoped, source, params[source]}
    end
  end

  @doc false
  def decode(value) do
    if value =~ @base64_sentinel, do: decode_sentinel(value), else: valid_plain(value)
  end

  defp decode_sentinel(value) do
    inner = String.slice(value, 9, byte_size(value) - 11)

    case Base.decode64(inner) do
      {:ok, bytes} -> valid_utf8(bytes)
      :error -> {:error, "invalid Base64 sentinel payload"}
    end
  end

  defp valid_plain(value) do
    cond do
      not String.valid?(value) -> {:error, "invalid UTF-8"}
      value != String.trim(value) -> {:error, "leading or trailing whitespace requires Base64"}
      not plain_ascii?(value) -> {:error, "unsafe characters require Base64"}
      true -> {:ok, value}
    end
  end

  defp valid_utf8(value) do
    if String.valid?(value), do: {:ok, value}, else: {:error, "invalid UTF-8"}
  end

  defp plain_ascii?(value) do
    value
    |> :binary.bin_to_list()
    |> Enum.all?(fn byte -> byte == 9 or byte in 32..126 end)
  end

  defp mismatch(message) do
    TamaMCP.Error.header_mismatch("Header mismatch: " <> message)
  end
end
