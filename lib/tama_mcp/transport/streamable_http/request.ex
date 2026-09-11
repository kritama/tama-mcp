defmodule TamaMCP.Transport.StreamableHTTP.Request do
  @moduledoc false

  alias TamaMCP.Protocol
  alias TamaMCP.Transport.StreamableHTTP.Headers

  defstruct [
    :request_id,
    :method,
    :name,
    :protocol_version,
    :client_info,
    :client_capabilities,
    :params
  ]

  @type t :: %__MODULE__{
          request_id: String.t() | integer(),
          method: String.t(),
          name: String.t() | nil,
          protocol_version: String.t(),
          client_info: map() | nil,
          client_capabilities: map(),
          params: map()
        }

  @type failure ::
          {:error, TamaMCP.Error.t(), non_neg_integer(), String.t() | integer() | nil,
           Plug.Conn.t()}

  @spec validate_headers(Plug.Conn.t()) :: {:ok, Plug.Conn.t()} | failure()
  def validate_headers(conn) do
    case Headers.validate_version(conn) do
      :ok -> {:ok, conn}
      {:error, error} -> {:error, error, TamaMCP.Error.status(error), nil, conn}
    end
  end

  @spec validate(Plug.Conn.t(), binary()) :: {:ok, t(), Plug.Conn.t()} | failure()
  def validate(conn, body) do
    with {:ok, json} <- decode(body),
         {:ok, request} <- parse(json),
         {:ok, request} <- Headers.match(conn, request) do
      {:ok, request, conn}
    else
      {:error, error, id} -> {:error, error, TamaMCP.Error.status(error), id, conn}
      {:error, error} -> {:error, error, TamaMCP.Error.status(error), request_id(body), conn}
    end
  end

  defp decode(body) do
    case Jason.decode(body) do
      {:ok, json} -> {:ok, json}
      {:error, _reason} -> {:error, TamaMCP.Error.parse(), nil}
    end
  end

  defp parse(%{} = json) do
    id = valid_id(json["id"])

    with :ok <- jsonrpc(json),
         {:ok, method} <- method(json),
         {:ok, request_id} <- id,
         {:ok, params} <- params(json),
         {:ok, meta} <- meta(params),
         {:ok, version} <- protocol_version(meta),
         {:ok, capabilities} <- capabilities(meta),
         {:ok, info} <- client_info(meta) do
      {:ok,
       %__MODULE__{
         request_id: request_id,
         method: method,
         name: nil,
         protocol_version: version,
         client_info: info,
         client_capabilities: capabilities,
         params: params
       }}
    else
      {:error, error} -> {:error, error, id_value(id)}
    end
  end

  defp parse(_json),
    do: {:error, TamaMCP.Error.invalid_request("Request body must be a JSON object"), nil}

  defp jsonrpc(%{"jsonrpc" => "2.0"}), do: :ok
  defp jsonrpc(_json), do: {:error, TamaMCP.Error.invalid_request("jsonrpc must be \"2.0\"")}

  defp method(%{"method" => method}) when is_binary(method) and method != "", do: {:ok, method}

  defp method(_json),
    do: {:error, TamaMCP.Error.invalid_request("method must be a non-empty string")}

  defp valid_id(id) when is_integer(id), do: {:ok, id}
  defp valid_id(id) when is_binary(id) and id != "", do: {:ok, id}

  defp valid_id(_id) do
    {:error,
     TamaMCP.Error.invalid_request("JSON-RPC notifications are not supported by this endpoint")}
  end

  defp params(%{"params" => params}) when is_map(params), do: {:ok, params}
  defp params(_json), do: {:error, TamaMCP.Error.invalid_params("params is required")}

  defp meta(%{"_meta" => meta}) when is_map(meta), do: {:ok, meta}
  defp meta(_params), do: {:error, TamaMCP.Error.invalid_params("params._meta is required")}

  defp protocol_version(meta) do
    key = Protocol.meta_key(:protocol_version)
    supported = Protocol.version()

    case meta[key] do
      ^supported ->
        {:ok, supported}

      version when is_binary(version) ->
        {:error,
         TamaMCP.Error.header_mismatch(
           "MCP-Protocol-Version header does not match body value #{inspect(version)}"
         )}

      _ ->
        {:error, TamaMCP.Error.invalid_params("params._meta.#{key} is required")}
    end
  end

  defp capabilities(meta) do
    key = Protocol.meta_key(:client_capabilities)

    case meta[key] do
      capabilities when is_map(capabilities) -> {:ok, capabilities}
      _ -> {:error, TamaMCP.Error.invalid_params("params._meta.#{key} is required")}
    end
  end

  defp client_info(meta) do
    key = Protocol.meta_key(:client_info)

    case Map.fetch(meta, key) do
      :error ->
        {:ok, nil}

      {:ok, %{"name" => name, "version" => version} = info}
      when is_binary(name) and name != "" and is_binary(version) and version != "" ->
        {:ok, info}

      {:ok, _info} ->
        {:error,
         TamaMCP.Error.invalid_params(
           "params._meta.#{key} must have non-empty name and version strings"
         )}
    end
  end

  defp id_value({:ok, id}), do: id
  defp id_value(_id), do: nil

  defp request_id(body) do
    case Jason.decode(body) do
      {:ok, %{"id" => id}} when is_integer(id) or (is_binary(id) and id != "") -> id
      _ -> nil
    end
  end
end
