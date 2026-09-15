defmodule TamaMCP.Transport.StreamableHTTP.Execute do
  @moduledoc false

  alias TamaMCP.{Clock, Context, Error, Identifier, Protocol, Response, Schema, Task}
  alias TamaMCP.Schema.Protocol, as: ProtocolSchema
  alias TamaMCP.Schema.Tasks
  alias TamaMCP.Transport.StreamableHTTP.{Events, Result, Runner, Runtime, Wire}

  @max_detail_bytes 512

  def call(conn, request, decision, runtime, base) do
    base = Map.merge(base, %{method: request.method, tool: bounded(request.params["name"] || "")})

    with {:ok, name} <- name(request.params),
         {:ok, module} <- tool(runtime.server, name),
         meta = module.tool_metadata(),
         :ok <- required_capability(module, request),
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

  defp required_capability(module, request) do
    if module.task_policy() == :required and not tasks_declared?(request.client_capabilities) do
      {:error, missing_tasks_capability(), :missing_capability}
    else
      :ok
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

    case execution(module, arguments, context, request, runtime) do
      :sync -> run_sync(conn, request, module, arguments, context, runtime, base)
      :task -> run_task(conn, request, module, arguments, context, runtime, base)
      {:error, %Error{} = error} -> protocol_error(conn, request, error, runtime, base)
      {:error, reason} -> unexpected(conn, request, runtime, base, reason)
    end
  end

  defp run_sync(conn, request, module, arguments, context, runtime, base) do
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

  defp execution(module, arguments, context, request, runtime) do
    declared? = tasks_declared?(request.client_capabilities)

    case module.task_policy() do
      :disabled ->
        :sync

      :required when not declared? ->
        {:error, missing_tasks_capability()}

      :required ->
        :task

      :optional when not declared? ->
        :sync

      :optional ->
        select_optional(runtime, module, arguments, context)
    end
  end

  defp select_optional(runtime, module, arguments, context) do
    if Runtime.task_capable?(runtime) do
      case runtime.task_selector.(module, arguments, context) do
        :task -> :task
        :sync -> :sync
        _invalid -> {:error, :invalid_task_selector_return}
      end
    else
      :sync
    end
  rescue
    _exception -> {:error, :task_selector_exception}
  catch
    _kind, _reason -> {:error, :task_selector_exception}
  end

  defp run_task(conn, request, _module, _arguments, %Context{owner_key: nil}, runtime, base) do
    unexpected(conn, request, runtime, base, :missing_owner_key)
  end

  defp run_task(conn, request, module, arguments, context, runtime, base) do
    with {:ok, identifier} <- Identifier.generate(runtime.identifier, runtime.identifier_options),
         {:ok, now} <- Clock.now(runtime.clock, runtime.clock_options),
         task_context = %{context | task_id: identifier},
         options = task_options(runtime, request, task_context, identifier, now),
         {:ok, %Task{} = task} <- start_task(runtime, module, arguments, task_context, options),
         :ok <- validate_created_task(task, task_context, request, options, runtime),
         :ok <- verify_persisted_task(task, runtime),
         result =
           task
           |> Task.create_result()
           |> Wire.merge_meta(Result.metadata(runtime.server)),
         :ok <- validate_task_result(:create_task_result, result, runtime),
         {:ok, reply} <-
           Wire.result(
             conn,
             200,
             request.request_id,
             result,
             Map.put(base, :status, :accepted),
             runtime
           ) do
      Events.emit(runtime, [:task, :creation], %{status: :ok}, elem(reply, 1))
      reply
    else
      {:error, %Error{} = error} -> protocol_error(conn, request, error, runtime, base)
      {:error, reason} -> unexpected(conn, request, runtime, base, reason)
    end
  end

  defp start_task(runtime, module, arguments, context, options) do
    case runtime.task_runner.start(module, arguments, context, options) do
      {:ok, %Task{} = task} -> {:ok, task}
      {:error, %Error{} = error} -> {:error, error}
      _invalid -> {:error, :invalid_task_runner_return}
    end
  rescue
    _exception -> {:error, :task_runner_exception}
  catch
    _kind, _reason -> {:error, :task_runner_exception}
  end

  defp task_options(runtime, request, context, identifier, now) do
    generated = [
      task_id: identifier,
      owner_key: context.owner_key,
      method: request.method,
      request_id: request.request_id,
      original_params: request.params,
      created_at: now,
      ttl_ms: runtime.limits.default_task_ttl_ms,
      poll_interval_ms: runtime.limits.default_poll_interval_ms,
      task_store: runtime.task_store,
      task_store_options: Runtime.effective_task_store_options(runtime),
      task_validation_options: Runtime.task_validation_options(runtime)
    ]

    Keyword.put(runtime.task_runner_options, :tama_mcp, generated)
  end

  defp validate_created_task(task, context, request, options, runtime) do
    generated = Keyword.fetch!(options, :tama_mcp)

    valid? =
      created_identity?(task, context, request) and created_timing?(task, generated) and
        task.original_params == request.params

    if valid? do
      Task.validate(task, Runtime.task_validation_options(runtime))
    else
      {:error, :invalid_task}
    end
  end

  defp created_identity?(task, context, request) do
    task.id == context.task_id and task.owner_key == context.owner_key and
      task.method == request.method and task.request_id == request.request_id and
      task.status == :working
  end

  defp created_timing?(task, generated) do
    task.created_at == generated[:created_at] and task.last_updated_at == generated[:created_at] and
      task.ttl_ms == generated[:ttl_ms] and
      task.poll_interval_ms == generated[:poll_interval_ms]
  end

  defp verify_persisted_task(task, runtime) do
    case runtime.task_store.get(
           task.owner_key,
           task.id,
           Runtime.effective_task_store_options(runtime)
         ) do
      {:ok, %Task{} = persisted} ->
        validate_persisted_task(task, persisted, runtime)

      _missing_or_mismatched ->
        {:error, :task_not_durable}
    end
  rescue
    _exception -> {:error, :task_store_exception}
  catch
    _kind, _reason -> {:error, :task_store_exception}
  end

  defp validate_persisted_task(initial, persisted, runtime) do
    with :ok <- Task.validate(persisted, Runtime.task_validation_options(runtime)),
         true <- same_persisted_identity?(initial, persisted),
         true <- persisted_progress?(initial, persisted) do
      :ok
    else
      _invalid_or_mismatched -> {:error, :task_not_durable}
    end
  end

  defp same_persisted_identity?(initial, persisted) do
    persisted.id == initial.id and persisted.owner_key == initial.owner_key and
      persisted.method == initial.method and persisted.request_id == initial.request_id and
      persisted.created_at == initial.created_at and persisted.ttl_ms == initial.ttl_ms and
      persisted.original_params == initial.original_params
  end

  defp persisted_progress?(initial, persisted) when persisted.revision == initial.revision,
    do: persisted == initial

  defp persisted_progress?(initial, persisted) when persisted.revision > initial.revision,
    do: DateTime.compare(persisted.last_updated_at, initial.last_updated_at) == :gt

  defp persisted_progress?(_initial, _persisted), do: false

  defp validate_task_result(kind, result, runtime) do
    case Tasks.validate(kind, result, runtime.cache, runtime.cache_options) do
      :ok -> :ok
      {:error, _details} -> {:error, :invalid_protocol_result}
    end
  end

  defp tasks_declared?(capabilities) do
    get_in(capabilities, ["extensions", Protocol.tasks_extension()]) |> is_map()
  end

  defp missing_tasks_capability do
    Error.missing_required_client_capability(%{
      "extensions" => %{Protocol.tasks_extension() => %{}}
    })
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
