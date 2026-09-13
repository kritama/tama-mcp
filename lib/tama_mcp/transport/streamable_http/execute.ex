defmodule TamaMCP.Transport.StreamableHTTP.Execute do
  @moduledoc false

  alias TamaMCP.{Context, Error, Protocol, Response, Schema}
  alias TamaMCP.Schema.Protocol, as: ProtocolSchema
  alias TamaMCP.Transport.StreamableHTTP.{Events, Result, Runner, Wire}

  @max_detail_bytes 512

  def call(conn, request, decision, runtime, base) do
    base = Map.merge(base, %{method: request.method, tool: bounded(request.params["name"] || "")})

    with {:ok, name} <- name(request.params),
         {:ok, module} <- tool(runtime.server, name),
         meta = module.tool_metadata(),
         {:ok, arguments} <- arguments(request.params),
         :ok <- scopes(meta.scopes, decision.scopes) do
      validate_and_run(conn, request, module, arguments, decision, runtime, base)
    else
      {:error, error, reason} ->
        reject(conn, request, error, reason, runtime, base)

      {:scope, missing} ->
        scope_error(conn, request, missing, runtime, base)
    end
  end

  defp name(%{"name" => name}) when is_binary(name) and name != "", do: {:ok, name}

  defp name(_params),
    do: {:error, Error.invalid_params("params.name is required"), :invalid_params}

  defp tool(server, name) do
    case server.tool(name) do
      nil -> {:error, Error.invalid_params("Unknown tool: #{bounded(name)}"), :unknown_tool}
      module -> {:ok, module}
    end
  end

  defp arguments(params) do
    cond do
      Map.has_key?(params, "inputResponses") ->
        unsupported("inputResponses")

      Map.has_key?(params, "requestState") ->
        unsupported("requestState")

      Map.has_key?(params, "arguments") and not is_map(params["arguments"]) ->
        {:error, Error.invalid_params("params.arguments must be an object"), :invalid_params}

      true ->
        {:ok, Map.get(params, "arguments", %{})}
    end
  end

  defp unsupported(key) do
    {:error, Error.invalid_params("#{key} is not supported for this tool"), :invalid_params}
  end

  defp scopes(required, granted) do
    case Enum.sort(required -- granted) do
      [] -> :ok
      missing -> {:scope, missing}
    end
  end

  defp validate_and_run(conn, request, module, arguments, decision, runtime, base) do
    case Schema.validate(module.input_validator(runtime.cache, runtime.cache_options), arguments) do
      :ok ->
        Events.emit(runtime, [:tool, :validation], %{status: :ok}, base)
        run(conn, request, module, arguments, decision, runtime, base)

      {:error, details} ->
        Events.emit(runtime, [:tool, :validation], %{status: :invalid}, base)

        message =
          details
          |> Enum.take(3)
          |> Enum.join("; ")
          |> bounded()

        reject(
          conn,
          request,
          Error.invalid_params("Invalid arguments for tool #{bounded(request.name)}: #{message}"),
          :invalid_arguments,
          runtime,
          base
        )
    end
  end

  defp run(conn, request, module, arguments, decision, runtime, base) do
    context = context(conn, request, decision, runtime)

    case Runner.run(module, arguments, context, runtime.limits.request_timeout_ms) do
      {:ok, {:ok, %Response{} = response}} ->
        complete(conn, request, module, response, runtime, base)

      {:ok, {:error, %Error{} = error}} ->
        protocol_error(conn, request, error, runtime, base)

      {:ok, _invalid} ->
        unexpected(conn, request, runtime, base, :invalid_tool_return)

      {:error, :timeout} ->
        unexpected(conn, request, runtime, base, :request_timeout)

      {:error, reason} ->
        unexpected(conn, request, runtime, base, reason)
    end
  end

  defp complete(conn, request, module, response, runtime, base) do
    with :ok <- Response.validate(response),
         :ok <- structured(module, response, runtime),
         result = Response.encode(response) |> Wire.merge_meta(Result.metadata(runtime.server)),
         :ok <- protocol_result(result, runtime),
         {:ok, reply} <-
           Wire.result(
             conn,
             200,
             request.request_id,
             result,
             Map.put(base, :status, :ok),
             runtime
           ) do
      Events.emit(runtime, [:tool, :execution], %{status: :ok}, elem(reply, 1))
      reply
    else
      {:error, reason} -> unexpected(conn, request, runtime, base, reason)
    end
  end

  defp structured(module, response, runtime) do
    case module.output_validator(runtime.cache, runtime.cache_options) do
      nil ->
        :ok

      compiled ->
        if Response.structured_content?(response) do
          Schema.validate(compiled, response.structured_content)
        else
          {:error, :missing_structured_content}
        end
    end
  end

  defp protocol_result(result, runtime) do
    case ProtocolSchema.validate(
           :call_tool_result,
           result,
           runtime.cache,
           runtime.cache_options
         ) do
      :ok -> :ok
      {:error, _details} -> {:error, :invalid_protocol_result}
    end
  end

  defp protocol_error(conn, request, error, runtime, base) do
    reason = Error.reason(error)
    meta = Map.merge(base, %{status: :error, reason: reason})

    Events.emit(runtime, [:tool, :execution], %{status: :error, reason: reason}, meta)

    Wire.error(conn, request.request_id, error, meta, runtime)
  end

  defp reject(conn, request, error, reason, runtime, base) do
    Wire.error(
      conn,
      request.request_id,
      error,
      Map.merge(base, %{status: :rejected, reason: reason}),
      runtime
    )
  end

  defp scope_error(conn, request, missing, runtime, base) do
    error = %Error{
      code: Protocol.error_code(:invalid_request),
      message: "Insufficient scope for tool #{bounded(request.name)}",
      data: %{"reason" => "scope_denied", "requiredScopes" => missing}
    }

    Wire.error(
      conn,
      request.request_id,
      error,
      Map.merge(base, %{status: :forbidden, reason: :scope_denied}),
      runtime,
      status: 403,
      authenticate: {:scope, missing}
    )
  end

  defp unexpected(conn, request, runtime, base, reason) do
    if reason not in [
         :request_timeout,
         :invalid_tool_return,
         :invalid_protocol_result,
         :missing_structured_content,
         :result_too_large
       ] do
      Events.log(%RuntimeError{message: inspect(reason)})
    end

    meta = Map.merge(base, %{status: :error, reason: safe_reason(reason)})

    Events.emit(
      runtime,
      [:tool, :execution],
      %{status: :exception, reason: safe_reason(reason)},
      meta
    )

    Wire.error(conn, request.request_id, Error.internal(), meta, runtime)
  end

  defp context(conn, request, decision, runtime) do
    %Context{
      request_id: request.request_id,
      protocol_version: request.protocol_version,
      method: request.method,
      name: request.name,
      client_info: request.client_info,
      client_capabilities: request.client_capabilities,
      principal: decision.principal,
      owner_key: decision.owner_key,
      claims: decision.claims,
      scopes: decision.scopes,
      headers:
        selected_headers(
          conn.req_headers,
          runtime.context_headers,
          runtime.limits.max_safe_metadata_bytes
        ),
      remote_address: remote_address(conn.remote_ip),
      task_id: nil,
      assigns: decision.assigns
    }
  end

  defp selected_headers(headers, names, limit) do
    Enum.reduce(names, %{}, fn name, selected ->
      values = for {key, value} <- headers, String.downcase(key) == name, do: value

      case values do
        [value] -> put_if_bounded(selected, name, value, limit)
        _none_or_duplicate -> selected
      end
    end)
  end

  defp put_if_bounded(headers, name, value, limit) do
    candidate = Map.put(headers, name, value)

    case Jason.encode(candidate) do
      {:ok, encoded} when byte_size(encoded) <= limit -> candidate
      _too_large_or_invalid -> headers
    end
  end

  defp remote_address({a, b, c, d}), do: "#{a}.#{b}.#{c}.#{d}"

  defp remote_address(ip) when is_tuple(ip) and tuple_size(ip) == 8,
    do: ip |> Tuple.to_list() |> Enum.map_join(":", &Integer.to_string(&1, 16))

  defp remote_address(_ip), do: nil

  defp safe_reason(reason) when is_atom(reason), do: reason
  defp safe_reason(_reason), do: :tool_exception

  defp bounded(nil), do: ""
  defp bounded(value) when is_binary(value) and byte_size(value) <= @max_detail_bytes, do: value

  defp bounded(value) when not is_binary(value), do: ""

  defp bounded(value) do
    value
    |> String.graphemes()
    |> Enum.reduce_while("", fn grapheme, result ->
      if byte_size(result) + byte_size(grapheme) > @max_detail_bytes,
        do: {:halt, result},
        else: {:cont, result <> grapheme}
    end)
  end
end
