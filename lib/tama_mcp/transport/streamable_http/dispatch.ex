defmodule TamaMCP.Transport.StreamableHTTP.Dispatch do
  @moduledoc false

  alias TamaMCP.{Error, Protocol}
  alias TamaMCP.Schema.Protocol, as: ProtocolSchema
  alias TamaMCP.Transport.StreamableHTTP.{Execute, Wire}

  def call(conn, request, decision, runtime, base) do
    discover = Protocol.method(:server_discover)
    list = Protocol.method(:tools_list)
    execute = Protocol.method(:tools_call)

    case request.method do
      ^discover ->
        discover(conn, request, runtime, base)

      ^list ->
        list(conn, request, decision, runtime, base)

      ^execute ->
        Execute.call(conn, request, decision, runtime, base)

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
    result = %{
      "resultType" => Protocol.result_type(:complete),
      "supportedVersions" => Protocol.supported_versions(),
      "capabilities" => %{"tools" => %{}},
      "ttlMs" => 0,
      "cacheScope" => "private",
      "_meta" => Wire.server_meta(runtime)
    }

    result =
      case runtime.server.instructions() do
        nil -> result
        instructions -> Map.put(result, "instructions", instructions)
      end

    protocol_result(conn, request, result, :discover_result, runtime, base)
  end

  defp list(conn, request, decision, runtime, base) do
    case request.params["cursor"] do
      nil ->
        tools =
          runtime.server.tools()
          |> Enum.filter(&visible?(&1, decision.scopes))
          |> Enum.map(&Map.put(&1.module.definition(), "name", &1.name))

        result = %{
          "resultType" => Protocol.result_type(:complete),
          "tools" => tools,
          "ttlMs" => 0,
          "cacheScope" => "private",
          "_meta" => Wire.server_meta(runtime)
        }

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
    case ProtocolSchema.validate(kind, result) do
      :ok ->
        Wire.result(conn, 200, request.request_id, result, ok_meta(base, request))

      {:error, _details} ->
        Wire.error(
          conn,
          request.request_id,
          Error.internal(),
          Map.merge(base, %{status: :exception, method: request.method, reason: :invalid_result}),
          runtime
        )
    end
  end

  defp visible?(entry, granted) do
    Enum.all?(entry.module.scopes(), &(&1 in granted))
  end

  defp ok_meta(base, request), do: Map.merge(base, %{status: :ok, method: request.method})

  defp bounded(value) when byte_size(value) <= 512, do: value
  defp bounded(value), do: binary_part(value, 0, 512)
end
