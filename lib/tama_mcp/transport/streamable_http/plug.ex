defmodule TamaMCP.Transport.StreamableHTTP.Plug do
  @moduledoc """
  Stateless Streamable HTTP endpoint for MCP `2026-07-28`.

  The endpoint authenticates every independent request and supports
  `server/discover`, `tools/list`, and synchronous `tools/call`.
  """

  import Plug.Conn

  alias TamaMCP.Transport.StreamableHTTP.{Body, Dispatch, Events, Request, Runtime, Wire}

  @spec init(keyword()) :: Runtime.t()
  def init(opts), do: Runtime.build(opts)

  @spec call(Plug.Conn.t(), Runtime.t()) :: Plug.Conn.t()
  def call(%Plug.Conn{} = conn, %Runtime{} = runtime) do
    base = %{server: runtime.server.name()}
    started = System.monotonic_time()
    prefix = runtime.telemetry_prefix
    :telemetry.execute(prefix ++ [:request, :start], %{}, base)

    {conn, meta} =
      try do
        handle(conn, runtime, base)
      rescue
        exception -> unexpected(conn, runtime, base, exception)
      end

    :telemetry.execute(
      prefix ++ [:request, :stop],
      %{system_time: System.monotonic_time() - started},
      Events.bound(meta, runtime)
    )

    conn
  end

  defp handle(conn, runtime, base) do
    if String.downcase(conn.method) == "post" do
      post(conn, runtime, base)
    else
      conn
      |> put_resp_header("allow", "POST")
      |> send_resp(405, "")
      |> then(&{&1, Map.put(base, :status, :method_not_allowed)})
    end
  end

  defp post(conn, runtime, base) do
    with :ok <- Body.validate(conn),
         {:ok, conn} <- Request.validate_headers(conn),
         {:ok, body, conn} <- Body.read(conn, runtime.limits),
         {:ok, request, conn} <- Request.validate(conn, body) do
      authenticate(conn, request, runtime, base)
    else
      {:error, %TamaMCP.Error{} = error} ->
        reject(conn, nil, error, TamaMCP.Error.reason(error), runtime, base)

      {:error, :too_large, conn} ->
        reject(
          conn,
          nil,
          TamaMCP.Error.invalid_request("Request body exceeds the maximum allowed size"),
          :body_too_large,
          runtime,
          base,
          413
        )

      {:error, :timeout, conn} ->
        reject(
          conn,
          nil,
          TamaMCP.Error.invalid_request("Request body read timed out"),
          :body_timeout,
          runtime,
          base,
          408
        )

      {:error, :read, conn} ->
        reject(
          conn,
          nil,
          TamaMCP.Error.invalid_request("Request body could not be read"),
          :body_read_error,
          runtime,
          base,
          400
        )

      {:error, %TamaMCP.Error{} = error, conn} ->
        reject(conn, nil, error, TamaMCP.Error.reason(error), runtime, base)

      {:error, %TamaMCP.Error{} = error, status, id, conn} ->
        reject(conn, id, error, TamaMCP.Error.reason(error), runtime, base, status)
    end
  end

  defp authenticate(conn, request, runtime, base) do
    case runtime.authorization.authenticate(conn, runtime.authorization_options) do
      {:ok, %TamaMCP.Authorization.Decision{} = decision} ->
        :telemetry.execute(runtime.telemetry_prefix ++ [:authorization, :success], %{}, base)
        Dispatch.call(conn, request, decision, runtime, base)

      {:error, %TamaMCP.Error{} = error} ->
        meta = Map.merge(base, %{status: :unauthorized, reason: :authorization_rejected})
        :telemetry.execute(runtime.telemetry_prefix ++ [:authorization, :failure], %{}, meta)

        Wire.error(conn, request.request_id, error, meta, runtime,
          status: 401,
          authenticate: :credential
        )

      _invalid ->
        unexpected(conn, runtime, base, %RuntimeError{message: "invalid authorization return"})
    end
  end

  defp reject(conn, id, error, reason, runtime, base, status \\ nil) do
    opts = if status, do: [status: status], else: []

    Wire.error(
      conn,
      id,
      error,
      Map.merge(base, %{status: :rejected, reason: reason}),
      runtime,
      opts
    )
  end

  defp unexpected(conn, runtime, base, exception) do
    Events.log(exception)
    meta = Map.merge(base, %{status: :exception, reason: Events.exception(exception)})
    Wire.error(conn, nil, TamaMCP.Error.internal(), meta, runtime)
  end
end
