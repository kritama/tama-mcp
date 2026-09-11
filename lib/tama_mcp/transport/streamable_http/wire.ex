defmodule TamaMCP.Transport.StreamableHTTP.Wire do
  @moduledoc false

  import Plug.Conn

  alias TamaMCP.Protocol
  alias TamaMCP.Schema.Protocol, as: ProtocolSchema

  def result(conn, status, id, result, meta) do
    body = Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "result" => result})

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, body)
    |> then(&{&1, meta})
  end

  def error(conn, id, error, meta, runtime, opts \\ []) do
    status = Keyword.get(opts, :status, TamaMCP.Error.status(error))

    envelope = %{
      "jsonrpc" => "2.0",
      "error" => TamaMCP.Error.encode(error, runtime.limits.max_error_data_bytes)
    }

    envelope = if is_nil(id), do: envelope, else: Map.put(envelope, "id", id)
    body = envelope |> valid_error_envelope() |> Jason.encode!()

    conn
    |> maybe_authenticate(Keyword.get(opts, :authenticate))
    |> put_resp_content_type("application/json")
    |> send_resp(status, body)
    |> then(&{&1, meta})
  end

  def server_meta(runtime) do
    %{
      Protocol.meta_key(:server_info) => %{
        "name" => runtime.server.name(),
        "version" => runtime.server.version()
      }
    }
  end

  def merge_meta(result, canonical) do
    existing = Map.get(result, "_meta", %{})
    Map.put(result, "_meta", Map.merge(existing, canonical))
  end

  defp valid_error_envelope(envelope) do
    case ProtocolSchema.validate(:error_response, envelope) do
      :ok ->
        envelope

      {:error, _details} ->
        %{
          "jsonrpc" => "2.0",
          "error" => %{"code" => Protocol.error_code(:internal), "message" => "Internal error"}
        }
    end
  end

  defp maybe_authenticate(conn, nil), do: conn

  defp maybe_authenticate(conn, {:scope, scopes}) do
    escaped = scopes |> Enum.join(" ") |> String.replace(["\\", "\""], "")

    put_resp_header(
      conn,
      "www-authenticate",
      ~s(Bearer error="insufficient_scope", scope="#{escaped}")
    )
  end

  defp maybe_authenticate(conn, :credential) do
    put_resp_header(conn, "www-authenticate", ~s(Bearer error="invalid_token"))
  end
end
