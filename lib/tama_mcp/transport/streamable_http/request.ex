defmodule TamaMCP.Transport.StreamableHTTP.Request do
  @moduledoc false

  alias TamaMCP.{JSON, Protocol}
  alias TamaMCP.Schema.Protocol, as: ProtocolSchema
  alias TamaMCP.Schema.Tasks, as: TaskSchema
  alias TamaMCP.Transport.StreamableHTTP.{Headers, Parameters, Runtime}

  @subscriptions_listen Protocol.method(:subscriptions_listen)

  @core_request_schemas %{
    Protocol.method(:server_discover) => :discover_request,
    Protocol.method(:tools_list) => :list_tools_request,
    Protocol.method(:tools_call) => :call_tool_request,
    Protocol.method(:subscriptions_listen) => :subscriptions_listen_request
  }
  @task_request_schemas %{
    Protocol.method(:tasks_get) => :get_task_request,
    Protocol.method(:tasks_update) => :update_task_request,
    Protocol.method(:tasks_cancel) => :cancel_task_request
  }

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

  @spec validate(Plug.Conn.t(), binary(), Runtime.t()) :: {:ok, t(), Plug.Conn.t()} | failure()
  def validate(conn, body, %Runtime{} = runtime) do
    with {:ok, json} <- decode(body),
         {:ok, request} <- parse(json),
         :ok <- validate_schema(json, request.method, runtime),
         {:ok, request} <- Headers.match(conn, request),
         :ok <- Parameters.match(conn, request, runtime.server) do
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

  defp method(%{"method" => method}) when is_binary(method), do: {:ok, method}

  defp method(_json),
    do: {:error, TamaMCP.Error.invalid_request("method must be a string")}

  defp valid_id(id) when is_integer(id), do: {:ok, id}
  defp valid_id(id) when is_binary(id), do: {:ok, id}

  defp valid_id(_id) do
    {:error,
     TamaMCP.Error.invalid_request("JSON-RPC notifications are not supported by this endpoint")}
  end

  defp params(%{"params" => params}) when is_map(params), do: {:ok, params}
  defp params(_json), do: {:error, TamaMCP.Error.invalid_params("params is required")}

  defp meta(%{"_meta" => meta}) when is_map(meta) do
    if JSON.meta_object?(meta) do
      {:ok, meta}
    else
      {:error, TamaMCP.Error.invalid_params("params._meta contains an invalid metadata key")}
    end
  end

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
      capabilities when is_map(capabilities) -> validate_capabilities(capabilities, key)
      _ -> {:error, TamaMCP.Error.invalid_params("params._meta.#{key} is required")}
    end
  end

  defp validate_capabilities(capabilities, key) do
    case Map.fetch(capabilities, "extensions") do
      :error ->
        {:ok, capabilities}

      {:ok, extensions} when is_map(extensions) ->
        if Enum.all?(extensions, &valid_extension?/1) do
          {:ok, capabilities}
        else
          {:error, invalid_extensions(key)}
        end

      {:ok, _extensions} ->
        {:error, invalid_extensions(key)}
    end
  end

  defp valid_extension?({identifier, settings}) do
    JSON.extension_identifier?(identifier) and is_map(settings)
  end

  defp invalid_extensions(key) do
    TamaMCP.Error.invalid_params(
      "params._meta.#{key}.extensions must use prefixed identifiers with object values"
    )
  end

  defp client_info(meta) do
    key = Protocol.meta_key(:client_info)

    case Map.fetch(meta, key) do
      :error ->
        {:ok, nil}

      {:ok, %{"name" => name, "version" => version} = info}
      when is_binary(name) and is_binary(version) ->
        {:ok, info}

      {:ok, _info} ->
        {:error,
         TamaMCP.Error.invalid_params("params._meta.#{key} must have name and version strings")}
    end
  end

  defp validate_schema(json, method, runtime) do
    case request_schema(method, runtime) do
      nil ->
        :ok

      {schema, kind} ->
        case schema.validate(kind, json, runtime.cache, runtime.cache_options) do
          :ok ->
            validate_task_subscription(json, method, runtime)

          {:error, details} ->
            message = details |> Enum.take(3) |> Enum.join("; ")

            {:error,
             TamaMCP.Error.invalid_params(
               "Request does not match the protocol schema: #{message}"
             )}
        end
    end
  end

  defp validate_task_subscription(json, @subscriptions_listen, runtime) do
    notifications = get_in(json, ["params", "notifications"])

    if is_map(notifications) and Map.has_key?(notifications, "taskIds") do
      validate_with(TaskSchema, :task_subscription_notifications, notifications, runtime)
    else
      :ok
    end
  end

  defp validate_task_subscription(_json, _method, _runtime), do: :ok

  defp validate_with(schema, kind, value, runtime) do
    case schema.validate(kind, value, runtime.cache, runtime.cache_options) do
      :ok ->
        :ok

      {:error, details} ->
        message = details |> Enum.take(3) |> Enum.join("; ")

        {:error,
         TamaMCP.Error.invalid_params("Request does not match the protocol schema: #{message}")}
    end
  end

  defp request_schema(method, runtime) do
    case Map.fetch(@core_request_schemas, method) do
      {:ok, kind} -> {ProtocolSchema, kind}
      :error -> task_request_schema(method, runtime)
    end
  end

  defp task_request_schema(method, runtime) do
    if Runtime.task_capable?(runtime) do
      case Map.fetch(@task_request_schemas, method) do
        {:ok, kind} -> {TaskSchema, kind}
        :error -> nil
      end
    end
  end

  defp id_value({:ok, id}), do: id
  defp id_value(_id), do: nil

  defp request_id(body) do
    case Jason.decode(body) do
      {:ok, %{"id" => id}} when is_integer(id) or is_binary(id) -> id
      _ -> nil
    end
  end
end
