defmodule TamaMCP.Transport.StreamableHTTP.PlugTest do
  @moduledoc false

  use ExUnit.Case
  import Plug.Test
  import Elixir.Plug.Conn, only: [get_resp_header: 2]

  alias TamaMCP.Protocol
  alias TamaMCP.Transport.StreamableHTTP.Plug

  @version Protocol.version()
  @parse Protocol.error_code(:parse)
  @invalid_request Protocol.error_code(:invalid_request)
  @method_not_found Protocol.error_code(:method_not_found)
  @invalid_params Protocol.error_code(:invalid_params)
  @internal Protocol.error_code(:internal)
  @header_mismatch Protocol.error_code(:header_mismatch)
  @unsupported Protocol.error_code(:unsupported_protocol_version)

  setup do
    runtime =
      Plug.init(
        server: TamaMCP.TestSupport.Server,
        authorization: TamaMCP.TestSupport.Authorization
      )

    {:ok, runtime: runtime}
  end

  describe "server/discover" do
    test "returns the discovery result for a valid request", %{runtime: runtime} do
      conn = post(runtime, Protocol.method(:server_discover), %{})

      assert conn.status == 200
      %{"result" => result, "id" => 1, "jsonrpc" => "2.0"} = decode(conn)

      assert result["resultType"] == Protocol.result_type(:complete)
      assert result["supportedVersions"] == Protocol.supported_versions()
      assert result["cacheScope"] == "private"
      assert result["ttlMs"] == 0
      assert result["instructions"] == "A test MCP server."
      assert %{"tools" => _} = result["capabilities"]

      assert result["_meta"][Protocol.meta_key(:server_info)] == %{
               "name" => "tama-mcp-test",
               "version" => "0.0.1-test"
             }
    end
  end

  describe "tools/list" do
    test "returns the catalog in deterministic order", %{runtime: runtime} do
      conn = post(runtime, Protocol.method(:tools_list), %{})

      assert conn.status == 200
      %{"result" => result} = decode(conn)

      names = result["tools"] |> Enum.map(& &1["name"])
      assert names == ["context", "echo", "failing", "invalid", "protocol_failing", "slow"]
      assert result["resultType"] == Protocol.result_type(:complete)
      assert result["cacheScope"] == "private"

      echo = Enum.find(result["tools"], &(&1["name"] == "echo"))
      assert %{"inputSchema" => %{"type" => "object"}} = echo
    end

    test "rejects an unexpected cursor", %{runtime: runtime} do
      conn = post(runtime, Protocol.method(:tools_list), %{"cursor" => "next"})

      assert conn.status == 400
      assert %{"error" => %{"code" => @invalid_params}} = decode(conn)
    end
  end

  describe "tools/call" do
    test "runs a synchronous tool and returns a complete result", %{runtime: runtime} do
      conn =
        post(
          runtime,
          Protocol.method(:tools_call),
          %{"name" => "echo", "arguments" => %{"message" => "hi"}},
          headers: [{"mcp-name", "echo"}]
        )

      assert conn.status == 200
      %{"result" => result} = decode(conn)

      assert result["resultType"] == Protocol.result_type(:complete)
      assert result["isError"] == false
      assert result["structuredContent"] == %{"message" => "hi"}
      assert [%{"type" => "text", "text" => "echo: hi"}] = result["content"]
    end

    test "returns a tool error as a successful JSON-RPC response with isError true", %{
      runtime: runtime
    } do
      conn =
        post(
          runtime,
          Protocol.method(:tools_call),
          %{"name" => "failing", "arguments" => %{"reason" => "nope"}},
          headers: [{"mcp-name", "failing"}]
        )

      assert conn.status == 200

      decoded = decode(conn)
      %{"result" => result} = decoded
      refute Map.has_key?(decoded, "error")
      assert result["isError"] == true
    end

    test "maps a protocol failure to a JSON-RPC error", %{runtime: runtime} do
      conn =
        post(
          runtime,
          Protocol.method(:tools_call),
          %{"name" => "protocol_failing", "arguments" => %{"boom" => true}},
          headers: [{"mcp-name", "protocol_failing"}]
        )

      assert conn.status == 500
      assert %{"error" => %{"code" => @internal}} = decode(conn)
    end

    test "rejects arguments that violate the input schema", %{runtime: runtime} do
      conn =
        post(
          runtime,
          Protocol.method(:tools_call),
          %{"name" => "echo", "arguments" => %{"message" => 123}},
          headers: [{"mcp-name", "echo"}]
        )

      assert conn.status == 400
      assert %{"error" => %{"code" => @invalid_params}} = decode(conn)
    end

    test "rejects an unknown tool", %{runtime: runtime} do
      conn =
        post(runtime, Protocol.method(:tools_call), %{"name" => "nope", "arguments" => %{}},
          headers: [{"mcp-name", "nope"}]
        )

      assert conn.status == 400
      assert %{"error" => %{"code" => @invalid_params}} = decode(conn)
    end

    test "requires params.name", %{runtime: runtime} do
      conn = post(runtime, Protocol.method(:tools_call), %{"arguments" => %{}})

      assert conn.status == 400
      assert %{"error" => %{"code" => @invalid_params}} = decode(conn)
    end

    test "rejects a non-string params.name as invalid parameters", %{runtime: runtime} do
      conn = post(runtime, Protocol.method(:tools_call), %{"name" => 123, "arguments" => %{}})

      assert conn.status == 400
      assert %{"error" => %{"code" => @invalid_params}} = decode(conn)
    end

    test "fails closed when the caller lacks the required scope", %{runtime: runtime} do
      conn =
        post(
          runtime,
          Protocol.method(:tools_call),
          %{"name" => "echo", "arguments" => %{"message" => "hi"}},
          headers: [{"mcp-name", "echo"}],
          token: "no-scope"
        )

      assert conn.status == 403
      assert %{"error" => %{"data" => %{"reason" => "scope_denied"}}} = decode(conn)
      assert [challenge] = get_resp_header(conn, "www-authenticate")
      assert challenge =~ ~s(error="insufficient_scope")
      assert challenge =~ ~s(scope="test.echo")
    end

    test "passes owner binding and selected header values without tuple leakage" do
      runtime =
        Plug.init(
          server: TamaMCP.TestSupport.Server,
          authorization: TamaMCP.TestSupport.Authorization,
          context_headers: ["X-Trace"]
        )

      conn =
        post(runtime, Protocol.method(:tools_call), %{"name" => "context"},
          headers: [{"mcp-name", "context"}, {"x-trace", "trace-1"}]
        )

      assert conn.status == 200
      result = decode(conn)["result"]
      assert result["structuredContent"] == %{"owner" => "test-owner", "trace" => "trace-1"}

      assert result["_meta"][Protocol.meta_key(:server_info)] == %{
               "name" => "tama-mcp-test",
               "version" => "0.0.1-test"
             }
    end

    test "rejects a tool result that violates the pinned CallToolResult schema", %{
      runtime: runtime
    } do
      conn =
        post(runtime, Protocol.method(:tools_call), %{"name" => "invalid"},
          headers: [{"mcp-name", "invalid"}]
        )

      assert conn.status == 500
      assert %{"error" => %{"code" => @internal}} = decode(conn)
    end

    test "terminates synchronous execution at the configured request deadline" do
      runtime =
        Plug.init(
          server: TamaMCP.TestSupport.Server,
          authorization: TamaMCP.TestSupport.Authorization,
          limits: [request_timeout_ms: 10]
        )

      conn =
        post(runtime, Protocol.method(:tools_call), %{"name" => "slow"},
          headers: [{"mcp-name", "slow"}]
        )

      assert conn.status == 500
      assert %{"error" => %{"code" => @internal}} = decode(conn)
    end
  end

  describe "transport and envelope validation" do
    test "rejects non-POST requests", %{runtime: runtime} do
      conn =
        :get
        |> conn("/", "")
        |> set_headers([{"mcp-protocol-version", @version}])
        |> Plug.call(runtime)

      assert conn.status == 405
    end

    test "rejects a body that is not valid JSON", %{runtime: runtime} do
      conn =
        raw_post(runtime, "this is not json", [
          {"mcp-protocol-version", @version},
          {"mcp-method", Protocol.method(:server_discover)},
          {"content-type", "application/json"},
          {"accept", "application/json, text/event-stream"}
        ])

      assert conn.status == 400
      assert %{"error" => %{"code" => @parse}} = decode(conn)
    end

    test "rejects media types with a query suffix", %{runtime: runtime} do
      method = Protocol.method(:server_discover)

      conn =
        raw_post(runtime, Jason.encode!(envelope(method, %{"_meta" => base_meta()})), [
          {"mcp-protocol-version", @version},
          {"mcp-method", method},
          {"content-type", "application/json?x=1"},
          {"accept", "application/json, text/event-stream"}
        ])

      assert conn.status == 400
    end

    test "does not accept required response media types with q=0", %{runtime: runtime} do
      method = Protocol.method(:server_discover)

      conn =
        raw_post(runtime, Jason.encode!(envelope(method, %{"_meta" => base_meta()})), [
          {"mcp-protocol-version", @version},
          {"mcp-method", method},
          {"content-type", "application/json"},
          {"accept", "application/json;q=0, text/event-stream"}
        ])

      assert conn.status == 400
    end

    test "enforces the total body byte limit across adapter chunks" do
      runtime =
        Plug.init(
          server: TamaMCP.TestSupport.Server,
          authorization: TamaMCP.TestSupport.Authorization,
          limits: [max_body_bytes: 8]
        )

      method = Protocol.method(:server_discover)

      conn =
        raw_post(runtime, "123456789", [
          {"mcp-protocol-version", @version},
          {"mcp-method", method},
          {"content-type", "application/json"},
          {"accept", "application/json, text/event-stream"}
        ])

      assert conn.status == 413
    end

    test "requires the MCP-Protocol-Version header", %{runtime: runtime} do
      params = %{"_meta" => base_meta()}

      conn =
        raw_post(runtime, Jason.encode!(envelope(Protocol.method(:server_discover), params)), [
          {"mcp-method", Protocol.method(:server_discover)},
          {"content-type", "application/json"},
          {"accept", "application/json, text/event-stream"}
        ])

      assert conn.status == 400
      assert %{"error" => %{"code" => @header_mismatch}} = decode(conn)
    end

    test "rejects an unsupported protocol version", %{runtime: runtime} do
      params = %{
        "_meta" => base_meta(%{"io.modelcontextprotocol/protocolVersion" => "1999-01-01"})
      }

      conn =
        raw_post(runtime, Jason.encode!(envelope(Protocol.method(:server_discover), params)), [
          {"mcp-protocol-version", "1999-01-01"},
          {"mcp-method", Protocol.method(:server_discover)},
          {"content-type", "application/json"},
          {"accept", "application/json, text/event-stream"}
        ])

      assert conn.status == 400
      assert %{"error" => %{"code" => @unsupported}} = decode(conn)
    end

    test "rejects a Mcp-Method header that disagrees with the body", %{runtime: runtime} do
      method = Protocol.method(:server_discover)
      params = %{"_meta" => base_meta()}

      conn =
        raw_post(runtime, Jason.encode!(envelope(method, params)), [
          {"mcp-protocol-version", @version},
          {"mcp-method", "something/else"},
          {"content-type", "application/json"},
          {"accept", "application/json, text/event-stream"}
        ])

      assert conn.status == 400
      assert %{"error" => %{"code" => @header_mismatch}} = decode(conn)
    end

    test "requires the Mcp-Name header for tools/call", %{runtime: runtime} do
      method = Protocol.method(:tools_call)
      params = %{"name" => "echo", "arguments" => %{"message" => "hi"}, "_meta" => base_meta()}

      conn =
        raw_post(runtime, Jason.encode!(envelope(method, params)), [
          {"mcp-protocol-version", @version},
          {"mcp-method", method},
          {"content-type", "application/json"},
          {"accept", "application/json, text/event-stream"}
        ])

      assert conn.status == 400
      assert %{"error" => %{"code" => @header_mismatch}} = decode(conn)
    end

    test "rejects requests missing the required client capabilities", %{runtime: runtime} do
      method = Protocol.method(:server_discover)

      params = %{
        "_meta" => Map.delete(base_meta(), Protocol.meta_key(:client_capabilities))
      }

      conn =
        raw_post(runtime, Jason.encode!(envelope(method, params)), [
          {"mcp-protocol-version", @version},
          {"mcp-method", method},
          {"content-type", "application/json"},
          {"accept", "application/json, text/event-stream"}
        ])

      assert conn.status == 400
      assert %{"error" => %{"code" => @invalid_params}} = decode(conn)
    end

    test "answers 404 for methods this phase does not implement", %{runtime: runtime} do
      conn = post(runtime, "tasks/get", %{"taskId" => "t-1"}, headers: [{"mcp-name", "t-1"}])

      assert conn.status == 404
      assert %{"error" => %{"code" => @method_not_found}} = decode(conn)
    end

    test "fails closed when authorization rejects the request", %{runtime: runtime} do
      conn =
        post(runtime, Protocol.method(:server_discover), %{}, token: "bad")

      assert conn.status == 401
      assert %{"error" => %{"code" => @invalid_request}} = decode(conn)
    end
  end

  describe "vendored protocol manifest" do
    test "every vendored artifact matches its recorded sha256" do
      manifest_path = Path.expand("priv/protocol/2026-07-28/manifest.json", File.cwd!())
      {:ok, raw} = File.read(manifest_path)
      %{"artifacts" => artifacts, "protocol_version" => version} = Jason.decode!(raw)

      assert version == @version
      assert artifacts != []

      Enum.each(artifacts, fn artifact ->
        path = Path.expand("priv/protocol/2026-07-28/" <> artifact["file"], File.cwd!())
        {:ok, bytes} = File.read(path)
        digest = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
        assert digest == artifact["sha256"], "sha256 mismatch for #{artifact["file"]}"
      end)
    end
  end

  defp post(runtime, method, params, opts \\ []) do
    token = Keyword.get(opts, :token, "ok")
    params = Map.put(params, "_meta", base_meta(Keyword.get(opts, :meta, %{})))
    body = Jason.encode!(envelope(method, params, Keyword.get(opts, :id, 1)))
    headers = standard_headers(method, token, Keyword.get(opts, :headers, []))
    raw_post(runtime, body, headers)
  end

  defp raw_post(runtime, body, headers) do
    :post
    |> conn("/", body)
    |> set_headers(headers)
    |> Plug.call(runtime)
  end

  defp set_headers(conn, headers) do
    %{conn | req_headers: headers}
  end

  defp standard_headers(method, token, extra) do
    [
      {"mcp-protocol-version", @version},
      {"mcp-method", method},
      {"content-type", "application/json"},
      {"accept", "application/json, text/event-stream"},
      {"x-test-token", token}
    ] ++ extra
  end

  defp envelope(method, params, id \\ 1) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => method,
      "params" => params
    }
  end

  defp base_meta(overrides \\ %{}) do
    Map.merge(
      %{
        Protocol.meta_key(:protocol_version) => @version,
        Protocol.meta_key(:client_capabilities) => %{"extensions" => %{}},
        Protocol.meta_key(:client_info) => %{"name" => "test-client", "version" => "1.0.0"}
      },
      overrides
    )
  end

  defp decode(%{resp_body: body}) do
    Jason.decode!(body)
  end
end
