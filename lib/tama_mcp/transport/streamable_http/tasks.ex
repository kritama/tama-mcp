defmodule TamaMCP.Transport.StreamableHTTP.Tasks do
  @moduledoc false

  alias TamaMCP.{Error, Protocol, Task}
  alias TamaMCP.Schema.Tasks, as: TaskSchema
  alias TamaMCP.Transport.StreamableHTTP.{Events, Result, Runtime, Wire}

  def call(conn, request, decision, %Runtime{} = runtime, base) do
    base = Map.merge(base, %{method: request.method, task: bounded(request.params["taskId"])})

    cond do
      not Runtime.task_capable?(runtime) ->
        method_not_found(conn, request, runtime, base)

      not tasks_declared?(request.client_capabilities) ->
        protocol_error(conn, request, missing_capability(), runtime, base)

      is_nil(decision.owner_key) ->
        unexpected(conn, request, runtime, base, :missing_owner_key)

      request.method == Protocol.method(:tasks_get) ->
        get(conn, request, decision.owner_key, runtime, base)

      request.method == Protocol.method(:tasks_update) ->
        update(conn, request, decision.owner_key, runtime, base)

      request.method == Protocol.method(:tasks_cancel) ->
        cancel(conn, request, decision.owner_key, runtime, base)

      true ->
        method_not_found(conn, request, runtime, base)
    end
  end

  defp get(conn, request, owner_key, runtime, base) do
    case store(runtime, :get, [owner_key, request.params["taskId"], runtime.task_store_options]) do
      {:ok, %Task{} = task} ->
        with :ok <- validate_task(task, owner_key, request.params["taskId"], runtime),
             result =
               task
               |> Task.get_result(runtime.limits.max_error_data_bytes)
               |> Wire.merge_meta(Result.metadata(runtime.server)),
             :ok <- validate_result(:get_task_result, result, runtime),
             {:ok, reply} <-
               Wire.result(
                 conn,
                 200,
                 request.request_id,
                 result,
                 Map.put(base, :status, :ok),
                 runtime
               ) do
          Events.emit(runtime, [:task, :lookup], %{status: :ok}, elem(reply, 1))
          reply
        else
          {:error, reason} -> unexpected(conn, request, runtime, base, reason)
        end

      {:error, :not_found} ->
        not_found(conn, request, runtime, base)

      {:error, %Error{} = error} ->
        protocol_error(conn, request, error, runtime, base)

      _invalid ->
        unexpected(conn, request, runtime, base, :invalid_task_store_return)
    end
  end

  defp update(conn, request, owner_key, runtime, base) do
    responses = request.params["inputResponses"]

    case store(runtime, :update, [
           owner_key,
           request.params["taskId"],
           responses,
           runtime.task_store_options
         ]) do
      :ok -> acknowledge(conn, request, :update_task_result, runtime, base, :update)
      {:error, :not_found} -> not_found(conn, request, runtime, base)
      {:error, :invalid_state} -> invalid_state(conn, request, runtime, base)
      {:error, :conflict} -> invalid_state(conn, request, runtime, base)
      {:error, %Error{} = error} -> protocol_error(conn, request, error, runtime, base)
      _invalid -> unexpected(conn, request, runtime, base, :invalid_task_store_return)
    end
  end

  defp cancel(conn, request, owner_key, runtime, base) do
    case store(runtime, :cancel, [owner_key, request.params["taskId"], runtime.task_store_options]) do
      :ok -> acknowledge(conn, request, :cancel_task_result, runtime, base, :cancellation)
      {:error, :not_found} -> not_found(conn, request, runtime, base)
      {:error, :invalid_state} -> invalid_state(conn, request, runtime, base)
      {:error, :conflict} -> invalid_state(conn, request, runtime, base)
      {:error, %Error{} = error} -> protocol_error(conn, request, error, runtime, base)
      _invalid -> unexpected(conn, request, runtime, base, :invalid_task_store_return)
    end
  end

  defp acknowledge(conn, request, kind, runtime, base, operation) do
    result =
      %{"resultType" => Protocol.result_type(:complete)}
      |> Wire.merge_meta(Result.metadata(runtime.server))

    with :ok <- validate_result(kind, result, runtime),
         {:ok, reply} <-
           Wire.result(
             conn,
             200,
             request.request_id,
             result,
             Map.put(base, :status, :accepted),
             runtime
           ) do
      Events.emit(runtime, [:task, operation], %{status: :accepted}, elem(reply, 1))
      reply
    else
      {:error, reason} -> unexpected(conn, request, runtime, base, reason)
    end
  end

  defp validate_task(task, owner_key, identifier, runtime) do
    if task.owner_key == owner_key and task.id == identifier do
      Task.validate(task,
        max_status_message_bytes: runtime.limits.max_status_message_bytes,
        max_task_ttl_ms: runtime.limits.max_task_ttl_ms
      )
    else
      {:error, :invalid_task}
    end
  end

  defp validate_result(kind, result, runtime) do
    case TaskSchema.validate(kind, result, runtime.cache, runtime.cache_options) do
      :ok -> :ok
      {:error, _details} -> {:error, :invalid_protocol_result}
    end
  end

  defp store(runtime, function, arguments) do
    apply(runtime.task_store, function, arguments)
  rescue
    _exception -> {:error, :adapter_exception}
  catch
    _kind, _reason -> {:error, :adapter_exception}
  end

  defp not_found(conn, request, runtime, base) do
    protocol_error(
      conn,
      request,
      Error.invalid_params("Task was not found"),
      runtime,
      Map.put(base, :reason, :task_not_found)
    )
  end

  defp invalid_state(conn, request, runtime, base) do
    protocol_error(
      conn,
      request,
      Error.invalid_params("Task is not in a state that accepts this operation"),
      runtime,
      Map.put(base, :reason, :invalid_task_state)
    )
  end

  defp protocol_error(conn, request, error, runtime, base) do
    Wire.error(
      conn,
      request.request_id,
      error,
      Map.merge(base, %{status: :rejected, reason: Error.reason(error)}),
      runtime
    )
  end

  defp method_not_found(conn, request, runtime, base) do
    protocol_error(conn, request, Error.method_not_found(request.method), runtime, base)
  end

  defp unexpected(conn, request, runtime, base, reason) do
    meta = Map.merge(base, %{status: :error, reason: reason})
    Events.emit(runtime, [:task, :exception], %{status: :exception}, meta)
    Wire.error(conn, request.request_id, Error.internal(), meta, runtime)
  end

  defp missing_capability do
    Error.missing_required_client_capability(%{
      "extensions" => %{Protocol.tasks_extension() => %{}}
    })
  end

  defp tasks_declared?(capabilities) do
    get_in(capabilities, ["extensions", Protocol.tasks_extension()]) |> is_map()
  end

  defp bounded(value) when is_binary(value) and byte_size(value) <= 512, do: value
  defp bounded(value) when is_binary(value), do: binary_part(value, 0, 512)
  defp bounded(_value), do: ""
end
