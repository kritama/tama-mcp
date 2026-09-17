defmodule TamaMCP.Transport.StreamableHTTP.Wire do
  @moduledoc false

  import Plug.Conn

  alias TamaMCP.Authorization.Challenge
  alias TamaMCP.Protocol
  alias TamaMCP.Schema.Protocol, as: ProtocolSchema

  def result(conn, status, id, result, meta, runtime) do
    with :ok <- validate_result(result, runtime.limits.max_result_bytes) do
      body = Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "result" => result})

      reply =
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(status, body)
        |> then(&{&1, meta})

      {:ok, reply}
    end
  end

  def validate_result(result, maximum) do
    case Jason.encode(result) do
      {:ok, encoded} when byte_size(encoded) <= maximum -> :ok
      {:ok, _encoded} -> {:error, :result_too_large}
      {:error, _reason} -> {:error, :invalid_result}
    end
  end

  def error(conn, id, error, meta, runtime, opts \\ []) do
    status = Keyword.get(opts, :status, TamaMCP.Error.status(error))

    envelope = %{
      "jsonrpc" => "2.0",
      "error" => TamaMCP.Error.encode(error, runtime.limits.max_error_data_bytes)
    }

    envelope = if is_nil(id), do: envelope, else: Map.put(envelope, "id", id)
    body = envelope |> valid_error_envelope(runtime) |> Jason.encode!()

    conn
    |> maybe_authenticate(Keyword.get(opts, :authenticate), runtime)
    |> put_resp_content_type("application/json")
    |> send_resp(status, body)
    |> then(&{&1, meta})
  end

  def merge_meta(result, canonical) do
    existing = Map.get(result, "_meta", %{})
    Map.put(result, "_meta", Map.merge(existing, canonical))
  end

  defp valid_error_envelope(envelope, runtime) do
    case validate_error_envelope(envelope, runtime) do
      :ok ->
        envelope

      {:error, _details} ->
        fallback = %{
          "jsonrpc" => "2.0",
          "error" => %{"code" => Protocol.error_code(:internal), "message" => "Internal error"}
        }

        preserve_id(fallback, envelope)
    end
  end

  defp validate_error_envelope(envelope, runtime) do
    ProtocolSchema.validate(
      :error_response,
      envelope,
      runtime.cache,
      runtime.cache_options
    )
  rescue
    _exception -> {:error, []}
  catch
    _kind, _reason -> {:error, []}
  end

  defp preserve_id(fallback, %{"id" => id}) when is_binary(id) or is_integer(id) do
    Map.put(fallback, "id", id)
  end

  defp preserve_id(fallback, _envelope), do: fallback

  defp maybe_authenticate(conn, nil, _runtime), do: conn

  defp maybe_authenticate(conn, {:scope, scopes}, runtime) do
    case Challenge.insufficient_scope(scopes, runtime.limits.max_www_authenticate_bytes) do
      {:ok, challenge} ->
        put_resp_header(conn, "www-authenticate", challenge)

      {:error, :too_large} ->
        put_resp_header(conn, "www-authenticate", Challenge.insufficient_scope())
    end
  end

  defp maybe_authenticate(conn, :credential, _runtime) do
    put_resp_header(conn, "www-authenticate", ~s(Bearer error="invalid_token"))
  end
end
