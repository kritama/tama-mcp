defmodule TamaMCP.Transport.StreamableHTTP.BoundaryTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias TamaMCP.Protocol
  alias TamaMCP.Transport.StreamableHTTP.{Body, Headers, Request}

  defmodule Adapter do
    @moduledoc false

    def read_req_body([{:more, data} | rest], _opts), do: {:more, data, rest}
    def read_req_body([{:ok, data} | rest], _opts), do: {:ok, data, rest}
    def read_req_body([{:error, reason} | _rest], _opts), do: {:error, reason}
  end

  @limits %{max_body_bytes: 8, body_read_timeout_ms: 1_000}

  test "body media validation rejects missing, duplicate, and unacceptable values" do
    assert {:error, _error} = Body.validate(conn([]))

    assert {:error, _error} =
             Body.validate(
               conn([
                 {"content-type", "application/json"},
                 {"content-type", "application/json"},
                 {"accept", "application/json, text/event-stream"}
               ])
             )

    assert {:error, _error} =
             Body.validate(conn([{"content-type", "text/plain"}, {"accept", "*/*"}]))

    assert {:error, _error} =
             Body.validate(conn([{"content-type", "application/json"}, {"accept", "*/*"}]))

    assert :ok =
             Body.validate(
               conn([
                 {"content-type", "Application/JSON; charset=utf-8"},
                 {"accept", "application/json;Q=1, text/event-stream;q=0.5"}
               ])
             )
  end

  test "body reading validates content length and adapter failures" do
    assert {:error, %TamaMCP.Error{}, _conn} =
             Body.read(conn([{"content-length", "invalid"}]), @limits)

    assert {:error, :too_large, _conn} = Body.read(conn([{"content-length", "9"}]), @limits)

    assert {:error, %TamaMCP.Error{}, _conn} =
             Body.read(conn([{"content-length", "1"}, {"content-length", "1"}]), @limits)

    assert {:error, :timeout, _conn} = Body.read(adapter_conn([{:error, :timeout}]), @limits)
    assert {:error, :read, _conn} = Body.read(adapter_conn([{:error, :closed}]), @limits)
  end

  test "body reading enforces the accumulated multi-chunk limit" do
    assert {:ok, "12345678", _conn} =
             Body.read(adapter_conn([{:more, "1234"}, {:ok, "5678"}]), @limits)

    assert {:error, :too_large, _conn} =
             Body.read(adapter_conn([{:more, "12345"}, {:more, "6789"}]), @limits)
  end

  test "standard header validation rejects duplicate versions and session identifiers" do
    assert {:error, _error} =
             Headers.validate_version(
               conn([
                 {"mcp-protocol-version", Protocol.version()},
                 {"mcp-protocol-version", Protocol.version()}
               ])
             )

    assert {:error, _error} =
             Headers.validate_version(
               conn([
                 {"mcp-protocol-version", Protocol.version()},
                 {"mcp-session-id", "one"}
               ])
             )
  end

  test "name headers support the Base64 sentinel and reject malformed or unexpected names" do
    request = request(Protocol.method(:tools_call), %{"name" => "echo"})
    encoded = "=?base64?#{Base.encode64("echo")}?="

    assert {:ok, %{name: "echo"}} =
             Headers.match(conn([{"mcp-method", request.method}, {"mcp-name", encoded}]), request)

    assert {:error, _error} =
             Headers.match(
               conn([{"mcp-method", request.method}, {"mcp-name", "=?base64?invalid?="}]),
               request
             )

    discover = request(Protocol.method(:server_discover), %{})

    assert {:error, _error} =
             Headers.match(
               conn([{"mcp-method", discover.method}, {"mcp-name", "unexpected"}]),
               discover
             )

    assert {:error, _error} =
             Headers.match(
               conn([
                 {"mcp-method", request.method},
                 {"mcp-name", "echo"},
                 {"mcp-name", "echo"}
               ]),
               request
             )
  end

  test "name headers validate known name-scoped methods before dispatch" do
    requests = [
      {Protocol.method(:resources_read), %{"uri" => "tama://resource/1"}, "tama://resource/1"},
      {Protocol.method(:prompts_get), %{"name" => "summarize"}, "summarize"}
    ]

    for {method, params, name} <- requests do
      request = request(method, params)

      assert {:ok, %{name: ^name}} =
               Headers.match(conn([{"mcp-method", method}, {"mcp-name", name}]), request)

      assert {:error, _error} =
               Headers.match(conn([{"mcp-method", method}, {"mcp-name", "other"}]), request)

      assert {:error, _error} = Headers.match(conn([{"mcp-method", method}]), request)
    end
  end

  test "request parsing rejects malformed envelope fields" do
    valid_conn = conn([{"mcp-method", Protocol.method(:server_discover)}])

    invalid = [
      "[]",
      encode(%{
        "jsonrpc" => "1.0",
        "id" => 1,
        "method" => "server/discover",
        "params" => params()
      }),
      encode(%{"jsonrpc" => "2.0", "id" => 1, "method" => "", "params" => params()}),
      encode(%{
        "jsonrpc" => "2.0",
        "id" => nil,
        "method" => "server/discover",
        "params" => params()
      }),
      encode(%{"jsonrpc" => "2.0", "method" => "server/discover", "params" => params()}),
      encode(%{"jsonrpc" => "2.0", "id" => 1, "method" => "server/discover"}),
      encode(%{"jsonrpc" => "2.0", "id" => 1, "method" => "server/discover", "params" => %{}})
    ]

    for body <- invalid do
      assert {:error, %TamaMCP.Error{}, _status, _id, _conn} =
               Request.validate(valid_conn, body, TamaMCP.TestSupport.Server)
    end
  end

  test "request parsing rejects missing protocol metadata and malformed client information" do
    method = Protocol.method(:server_discover)
    valid_conn = conn([{"mcp-method", method}])

    missing_version =
      envelope(method, %{
        "_meta" => %{Protocol.meta_key(:client_capabilities) => %{}}
      })

    invalid_info =
      envelope(
        method,
        params(%{Protocol.meta_key(:client_info) => %{"name" => "", "version" => "1"}})
      )

    assert {:error, %TamaMCP.Error{}, 400, 1, _conn} =
             Request.validate(valid_conn, encode(missing_version), TamaMCP.TestSupport.Server)

    assert {:error, %TamaMCP.Error{}, 400, 1, _conn} =
             Request.validate(valid_conn, encode(invalid_info), TamaMCP.TestSupport.Server)
  end

  defp conn(headers), do: %{Plug.Test.conn(:post, "/", "") | req_headers: headers}

  defp adapter_conn(replies) do
    %{conn([]) | adapter: {Adapter, replies}}
  end

  defp request(method, request_params) do
    %Request{
      request_id: 1,
      method: method,
      protocol_version: Protocol.version(),
      client_capabilities: %{},
      params: request_params
    }
  end

  defp envelope(method, request_params) do
    %{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => request_params}
  end

  defp params(overrides \\ %{}) do
    %{
      "_meta" =>
        Map.merge(
          %{
            Protocol.meta_key(:protocol_version) => Protocol.version(),
            Protocol.meta_key(:client_capabilities) => %{}
          },
          overrides
        )
    }
  end

  defp encode(value), do: Jason.encode!(value)
end
