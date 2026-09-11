defmodule TamaMCP.Transport.StreamableHTTP.Plug do
  @moduledoc """
  Stateless Streamable HTTP endpoint for MCP `2026-07-28`.

  The endpoint authenticates every independent request and supports
  `server/discover`, `tools/list`, and synchronous `tools/call`.
  """

  import Plug.Conn

  alias TamaMCP.Authorization.Decision
  alias TamaMCP.Transport.StreamableHTTP.{Body, Dispatch, Events, Request, Runtime, Wire}

  @spec init(keyword()) :: Runtime.t()
  def init(opts), do: Runtime.build(opts)

  @spec call(Plug.Conn.t(), Runtime.t()) :: Plug.Conn.t()
  def call(%Plug.Conn{} = conn, %Runtime{} = runtime) do
    base = %{server: runtime.server.name()}
    started = System.monotonic_time()
    Events.emit(runtime, [:request, :start], %{}, base)

    {conn, meta} =
      try do
        handle(conn, runtime, base)
      rescue
        exception ->
          meta = Map.merge(base, %{status: :exception, reason: Events.exception(exception)})
          Events.emit(runtime, [:request, :exception], %{}, meta)
          unexpected(conn, runtime, base, exception)
      end

    Events.emit(
      runtime,
      [:request, :stop],
      %{duration: System.monotonic_time() - started},
      meta
    )

    conn
  end

  defp handle(conn, runtime, base) do
    case runtime.authorization.authenticate(conn, runtime.authorization_options) do
      {:ok, %Decision{} = decision} ->
        authorized(conn, decision, runtime, base)

      {:error, %TamaMCP.Error{} = error} ->
        authorization_error(conn, error, runtime, base)

      _invalid ->
        meta = Map.merge(base, %{status: :exception, reason: :invalid_authorization_return})
        Events.emit(runtime, [:authorization, :failure], %{}, meta)
        unexpected(conn, runtime, base, %RuntimeError{message: "invalid authorization return"})
    end
  end

  defp authorized(conn, decision, runtime, base) do
    if Decision.valid?(decision) do
      Events.emit(runtime, [:authorization, :success], %{}, base)
      route(conn, decision, runtime, base)
    else
      meta = Map.merge(base, %{status: :exception, reason: :invalid_authorization_decision})
      Events.emit(runtime, [:authorization, :failure], %{}, meta)
      unexpected(conn, runtime, base, %RuntimeError{message: "invalid authorization decision"})
    end
  end

  defp route(conn, decision, runtime, base) do
    if String.downcase(conn.method) == "post" do
      post(conn, decision, runtime, base)
    else
      conn
      |> put_resp_header("allow", "POST")
      |> send_resp(405, "")
      |> then(&{&1, Map.put(base, :status, :method_not_allowed)})
    end
  end

  defp post(conn, decision, runtime, base) do
    with :ok <- Body.validate(conn),
         {:ok, conn} <- Request.validate_headers(conn),
         {:ok, body, conn} <- Body.read(conn, runtime.limits),
         {:ok, request, conn} <- Request.validate(conn, body, runtime.server) do
      Dispatch.call(conn, request, decision, runtime, base)
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

  defp authorization_error(conn, error, runtime, base) do
    meta = Map.merge(base, %{status: :unauthorized, reason: :authorization_rejected})
    Events.emit(runtime, [:authorization, :failure], %{}, meta)

    Wire.error(conn, nil, error, meta, runtime,
      status: 401,
      authenticate: :credential
    )
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
