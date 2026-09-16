defmodule TamaMCP.Transport.StreamableHTTP.Dispatch do
  @moduledoc false

  alias TamaMCP.{Error, Protocol}
  alias TamaMCP.Schema.Protocol, as: ProtocolSchema
  alias TamaMCP.Transport.StreamableHTTP.{Execute, Result, Runtime, Subscriptions, Tasks, Wire}

  def call(conn, request, decision, runtime, base) do
    discover = Protocol.method(:server_discover)
    list = Protocol.method(:tools_list)
    execute = Protocol.method(:tools_call)
    get_task = Protocol.method(:tasks_get)
    update_task = Protocol.method(:tasks_update)
    cancel_task = Protocol.method(:tasks_cancel)
    listen = Protocol.method(:subscriptions_listen)

    case request.method do
      ^discover ->
        discover(conn, request, runtime, base)

      ^list ->
        list(conn, request, decision, runtime, base)

      ^execute ->
        Execute.call(conn, request, decision, runtime, base)

      ^get_task ->
        Tasks.call(conn, request, decision, runtime, base)

      ^update_task ->
        Tasks.call(conn, request, decision, runtime, base)

      ^cancel_task ->
        Tasks.call(conn, request, decision, runtime, base)

      ^listen ->
        Subscriptions.call(conn, request, decision, runtime, base)

      method ->
        Wire.error(
          conn,
          request.request_id,
          Error.method_not_found(method),
          Map.merge(base, %{status: :method_not_found, method: bounded(method)}),
          runtime
        )
    end
  end

  defp discover(conn, request, runtime, base) do
    protocol_result(
      conn,
      request,
      Result.discover(runtime.server, Runtime.task_capable?(runtime)),
      :discover_result,
      runtime,
      base
    )
  end

  defp list(conn, request, decision, runtime, base) do
    case request.params["cursor"] do
      nil ->
        result = Result.tools(runtime.server, decision.scopes)
        protocol_result(conn, request, result, :list_tools_result, runtime, base)

      _cursor ->
        error =
          Error.invalid_params("Unexpected cursor: tools/list is not paginated by this server")

        Wire.error(
          conn,
          request.request_id,
          error,
          Map.merge(base, %{status: :rejected, method: request.method, reason: :invalid_params}),
          runtime
        )
    end
  end

  defp protocol_result(conn, request, result, kind, runtime, base) do
    case ProtocolSchema.validate(kind, result, runtime.cache, runtime.cache_options) do
      :ok ->
        case Wire.result(conn, 200, request.request_id, result, ok_meta(base, request), runtime) do
          {:ok, reply} -> reply
          {:error, reason} -> result_error(conn, request, runtime, base, reason)
        end

      {:error, _details} ->
        result_error(conn, request, runtime, base, :invalid_result)
    end
  end

  defp result_error(conn, request, runtime, base, reason) do
    Wire.error(
      conn,
      request.request_id,
      Error.internal(),
      Map.merge(base, %{status: :exception, method: request.method, reason: reason}),
      runtime
    )
  end

  defp ok_meta(base, request), do: Map.merge(base, %{status: :ok, method: request.method})

  defp bounded(value) when byte_size(value) <= 512, do: value
  defp bounded(value), do: binary_part(value, 0, 512)
end
