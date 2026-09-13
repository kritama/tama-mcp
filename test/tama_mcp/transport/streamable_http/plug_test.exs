defmodule TamaMCP.Transport.StreamableHTTP.PlugTest do
  @moduledoc false

  use ExUnit.Case
  import ExUnit.CaptureLog
  import Plug.Test
  import Elixir.Plug.Conn, only: [get_resp_header: 2]

  alias TamaMCP.{Protocol, Response}
  alias TamaMCP.TestSupport.Server
  alias TamaMCP.Transport.StreamableHTTP.{Plug, Result, Wire}

  @version Protocol.version()
  @parse Protocol.error_code(:parse)
  @invalid_request Protocol.error_code(:invalid_request)
  @method_not_found Protocol.error_code(:method_not_found)
  @invalid_params Protocol.error_code(:invalid_params)
  @internal Protocol.error_code(:internal)
  @header_mismatch Protocol.error_code(:header_mismatch)
  @unsupported Protocol.error_code(:unsupported_protocol_version)

  defmodule Cache do
    @moduledoc false

    @behaviour TamaMCP.Cache

    @impl true
    def fetch(_key, _loader, _options), do: {:error, %{secret: "must not leak"}}
  end

  setup do
    runtime =
      Plug.init(
        server: TamaMCP.TestSupport.Server,
        authorization: TamaMCP.TestSupport.Authorization,
        cache: TamaMCP.TestSupport.Cache
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

    test "accepts an empty string request ID", %{runtime: runtime} do
      conn = post(runtime, Protocol.method(:server_discover), %{}, id: "")

      assert conn.status == 200
      assert %{"id" => "", "jsonrpc" => "2.0", "result" => _result} = decode(conn)
    end

    test "returns a bounded internal error when the validator cache fails" do
      runtime =
        Plug.init(
          server: TamaMCP.TestSupport.Server,
          authorization: TamaMCP.TestSupport.Authorization,
          cache: Cache
        )

      {conn, log} =
        with_log(fn -> post(runtime, Protocol.method(:server_discover), %{}) end)

      assert conn.status == 500
      assert %{"error" => %{"code" => @internal, "message" => "Internal error"}} = decode(conn)
      refute conn.resp_body =~ "must not leak"
      refute log =~ "must not leak"
    end
  end

  describe "tools/list" do
    test "returns the catalog in deterministic order", %{runtime: runtime} do
      conn = post(runtime, Protocol.method(:tools_list), %{})

      assert conn.status == 200
      %{"result" => result} = decode(conn)

      names = result["tools"] |> Enum.map(& &1["name"])

      assert names == [
               "context",
               "echo",
               "failing",
               "headers",
               "invalid",
               "invalid_output",
               "null",
               "protocol_failing",
               "result",
               "slow"
             ]

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

    test "returns only tools visible to the granted scopes", %{runtime: runtime} do
      conn = post(runtime, Protocol.method(:tools_list), %{}, token: "echo-only")

      assert conn.status == 200
      assert [%{"name" => "echo"}] = decode(conn)["result"]["tools"]
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

    test "validates schema-declared parameter headers before executing", %{runtime: runtime} do
      region = "Hello, 世界"

      conn =
        post(
          runtime,
          Protocol.method(:tools_call),
          %{
            "name" => "headers",
            "arguments" => %{
              "enabled" => true,
              "region" => region,
              "routing" => %{"shard" => 42}
            }
          },
          headers: [
            {"mcp-name", "headers"},
            {"mcp-param-enabled", "true"},
            {"mcp-param-region", "=?base64?#{Base.encode64(region)}?="},
            {"mcp-param-shard", "42"}
          ]
        )

      assert conn.status == 200
      assert %{"result" => %{"resultType" => "complete"}} = decode(conn)
    end

    test "compares mirrored integer headers exactly and numerically", %{runtime: runtime} do
      for {body, shard} <- [
            {42, "42.0"},
            {42, "4.2e1"},
            {42, "=?base64?#{Base.encode64("42.0")}?="},
            {-42, "-42.0"},
            {0, "-0.0e999"}
          ] do
        conn =
          post(
            runtime,
            Protocol.method(:tools_call),
            %{
              "name" => "headers",
              "arguments" => %{
                "enabled" => true,
                "region" => "west",
                "routing" => %{"shard" => body}
              }
            },
            headers: [
              {"mcp-name", "headers"},
              {"mcp-param-enabled", "true"},
              {"mcp-param-region", "west"},
              {"mcp-param-shard", shard}
            ]
          )

        assert conn.status == 200
        assert %{"result" => %{"resultType" => "complete"}} = decode(conn)
      end

      for {body, shard} <- [
            {42, "42.5"},
            {42, "-42.0"},
            {42, "42trailing"},
            {9_007_199_254_740_991, "9007199254740991.4"}
          ] do
        conn =
          post(
            runtime,
            Protocol.method(:tools_call),
            %{
              "name" => "headers",
              "arguments" => %{
                "enabled" => true,
                "region" => "west",
                "routing" => %{"shard" => body}
              }
            },
            headers: [
              {"mcp-name", "headers"},
              {"mcp-param-enabled", "true"},
              {"mcp-param-region", "west"},
              {"mcp-param-shard", shard}
            ]
          )

        assert conn.status == 400
        assert %{"error" => %{"code" => @header_mismatch}} = decode(conn)
      end
    end

    test "rejects missing, mismatched, duplicate, and unexpected parameter headers", %{
      runtime: runtime
    } do
      arguments = %{"enabled" => true, "region" => "west", "routing" => %{"shard" => 42}}

      header_sets = [
        [{"mcp-name", "headers"}, {"mcp-param-enabled", "true"}, {"mcp-param-shard", "42"}],
        [
          {"mcp-name", "headers"},
          {"mcp-param-enabled", "false"},
          {"mcp-param-region", "west"},
          {"mcp-param-shard", "42"}
        ],
        [
          {"mcp-name", "headers"},
          {"mcp-param-enabled", "true"},
          {"mcp-param-region", "west"},
          {"mcp-param-region", "west"},
          {"mcp-param-shard", "42"}
        ],
        [
          {"mcp-name", "headers"},
          {"mcp-param-enabled", "true"},
          {"mcp-param-note", "unexpected"},
          {"mcp-param-region", "west"},
          {"mcp-param-shard", "42"}
        ]
      ]

      for headers <- header_sets do
        conn =
          post(
            runtime,
            Protocol.method(:tools_call),
            %{"name" => "headers", "arguments" => arguments},
            headers: headers
          )

        assert conn.status == 400
        assert %{"error" => %{"code" => @header_mismatch}} = decode(conn)
      end
    end

    test "rejects unsafe plain values, null headers, and integers outside the safe range", %{
      runtime: runtime
    } do
      cases = [
        {
          %{"enabled" => true, "region" => "世界", "routing" => %{"shard" => 42}},
          [{"mcp-param-enabled", "true"}, {"mcp-param-region", "世界"}, {"mcp-param-shard", "42"}]
        },
        {
          %{
            "enabled" => true,
            "note" => nil,
            "region" => "west",
            "routing" => %{"shard" => 42}
          },
          [
            {"mcp-param-enabled", "true"},
            {"mcp-param-note", "present"},
            {"mcp-param-region", "west"},
            {"mcp-param-shard", "42"}
          ]
        },
        {
          %{
            "enabled" => true,
            "region" => "west",
            "routing" => %{"shard" => 9_007_199_254_740_992}
          },
          [
            {"mcp-param-enabled", "true"},
            {"mcp-param-region", "west"},
            {"mcp-param-shard", "9007199254740992"}
          ]
        }
      ]

      for {arguments, parameter_headers} <- cases do
        conn =
          post(
            runtime,
            Protocol.method(:tools_call),
            %{"name" => "headers", "arguments" => arguments},
            headers: [{"mcp-name", "headers"} | parameter_headers]
          )

        assert conn.status == 400
        assert %{"error" => %{"code" => @header_mismatch}} = decode(conn)
      end
    end

    test "preserves explicit null structured content", %{runtime: runtime} do
      conn =
        post(runtime, Protocol.method(:tools_call), %{"name" => "null"},
          headers: [{"mcp-name", "null"}]
        )

      assert conn.status == 200
      assert Map.fetch!(decode(conn)["result"], "structuredContent") == nil
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

    test "rejects unsupported continuation fields and non-object arguments", %{runtime: runtime} do
      requests = [
        %{"name" => "echo", "inputResponses" => []},
        %{"name" => "echo", "requestState" => "state"},
        %{"name" => "echo", "arguments" => []}
      ]

      for params <- requests do
        conn =
          post(runtime, Protocol.method(:tools_call), params, headers: [{"mcp-name", "echo"}])

        assert conn.status == 400
        assert %{"error" => %{"code" => @invalid_params}} = decode(conn)
      end
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
          cache: TamaMCP.TestSupport.Cache,
          context_headers: ["X-Trace"]
        )

      conn =
        post(runtime, Protocol.method(:tools_call), %{"name" => "context"},
          headers: [{"mcp-name", "context"}, {"x-trace", "trace-1"}]
        )

      assert conn.status == 200
      result = decode(conn)["result"]

      assert result["structuredContent"] == %{
               "owner" => "test-owner",
               "trace" => "trace-1",
               "workspace" => "test-workspace"
             }

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

    test "rejects structured content that violates the declared output schema", %{
      runtime: runtime
    } do
      {conn, log} =
        with_log(fn ->
          post(runtime, Protocol.method(:tools_call), %{"name" => "invalid_output"},
            headers: [{"mcp-name", "invalid_output"}]
          )
        end)

      assert conn.status == 500
      assert %{"error" => %{"code" => @internal}} = decode(conn)
      assert log =~ "TamaMCP unexpected runtime failure: Elixir.RuntimeError"
    end

    test "enforces the encoded tool result limit at the exact boundary" do
      value = String.duplicate("x", static_result_size())

      result =
        Response.success(content: [Response.text(value)])
        |> Response.encode()
        |> Wire.merge_meta(%{
          Protocol.meta_key(:server_info) => %{
            "name" => Server.name(),
            "version" => Server.version()
          }
        })

      size = result |> Jason.encode!() |> byte_size()

      assert post(
               result_runtime(size),
               Protocol.method(:tools_call),
               result_params("content", value),
               headers: [{"mcp-name", "result"}]
             ).status == 200

      conn =
        post(
          result_runtime(size - 1),
          Protocol.method(:tools_call),
          result_params("content", value),
          headers: [{"mcp-name", "result"}]
        )

      assert conn.status == 500
      assert %{"error" => %{"code" => @internal}} = decode(conn)
    end

    test "rejects oversized content, structured content, and result metadata" do
      maximum = static_result_size()
      value = String.duplicate("must-not-escape", maximum)

      for placement <- ["content", "structured_content", "meta"] do
        {conn, log} =
          with_log(fn ->
            post(
              result_runtime(maximum),
              Protocol.method(:tools_call),
              result_params(placement, value),
              headers: [{"mcp-name", "result"}]
            )
          end)

        assert conn.status == 500
        assert %{"error" => %{"code" => @internal, "message" => "Internal error"}} = decode(conn)
        refute conn.resp_body =~ value
        refute log =~ value
        refute log =~ "unexpected runtime failure"
      end
    end

    test "terminates synchronous execution at the configured request deadline" do
      runtime =
        Plug.init(
          server: TamaMCP.TestSupport.Server,
          authorization: TamaMCP.TestSupport.Authorization,
          cache: TamaMCP.TestSupport.Cache,
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
    test "preserves readable request IDs when malformed errors use the fallback", %{
      runtime: runtime
    } do
      malformed = %TamaMCP.Error{code: "invalid", message: "failure"}

      for id <- ["request-1", ""] do
        {conn, _meta} = Wire.error(conn(:post, "/", ""), id, malformed, %{}, runtime)

        assert conn.status == 500
        assert %{"id" => ^id, "error" => %{"code" => @internal}} = decode(conn)
      end
    end

    test "rejects non-POST requests", %{runtime: runtime} do
      conn =
        :get
        |> conn("/", "")
        |> set_headers([{"mcp-protocol-version", @version}, {"x-test-token", "ok"}])
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
      response = decode(conn)
      assert %{"error" => %{"code" => @parse}} = response
      refute Map.has_key?(response, "id")
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

    test "combines repeated Accept field lines", %{runtime: runtime} do
      method = Protocol.method(:server_discover)

      conn =
        raw_post(runtime, Jason.encode!(envelope(method, %{"_meta" => base_meta()})), [
          {"mcp-protocol-version", @version},
          {"mcp-method", method},
          {"content-type", "application/json"},
          {"accept", "application/json"},
          {"accept", "text/event-stream"}
        ])

      assert conn.status == 200
    end

    test "honors q=0 across repeated Accept field lines", %{runtime: runtime} do
      method = Protocol.method(:server_discover)

      conn =
        raw_post(runtime, Jason.encode!(envelope(method, %{"_meta" => base_meta()})), [
          {"mcp-protocol-version", @version},
          {"mcp-method", method},
          {"content-type", "application/json"},
          {"accept", "application/json;q=0"},
          {"accept", "text/event-stream"}
        ])

      assert conn.status == 400
    end

    test "enforces the total body byte limit across adapter chunks" do
      runtime =
        Plug.init(
          server: TamaMCP.TestSupport.Server,
          authorization: TamaMCP.TestSupport.Authorization,
          cache: TamaMCP.TestSupport.Cache,
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

    test "rejects malformed protocol versions as header mismatches", %{runtime: runtime} do
      params = %{"_meta" => base_meta()}

      for version <- ["método", "bad\x01version"] do
        conn =
          raw_post(
            runtime,
            Jason.encode!(envelope(Protocol.method(:server_discover), params)),
            [
              {"mcp-protocol-version", version},
              {"mcp-method", Protocol.method(:server_discover)},
              {"content-type", "application/json"},
              {"accept", "application/json, text/event-stream"}
            ]
          )

        assert conn.status == 400

        assert %{"error" => %{"code" => @header_mismatch, "message" => message}} =
                 decode(conn)

        assert message =~ "MCP-Protocol-Version header is malformed"
      end
    end

    test "rejects Mcp-Session-Id instead of accepting protocol sessions", %{runtime: runtime} do
      conn =
        post(runtime, Protocol.method(:server_discover), %{},
          headers: [{"mcp-session-id", "legacy-session"}]
        )

      assert conn.status == 400
      assert %{"error" => %{"code" => @header_mismatch, "message" => message}} = decode(conn)
      assert message =~ "Mcp-Session-Id is not supported"
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

    test "rejects matching Mcp-Method values with unsafe characters", %{runtime: runtime} do
      for method <- ["método", "bad\x01method"] do
        params = %{"_meta" => base_meta()}

        conn =
          raw_post(runtime, Jason.encode!(envelope(method, params)), [
            {"mcp-protocol-version", @version},
            {"mcp-method", method},
            {"content-type", "application/json"},
            {"accept", "application/json, text/event-stream"}
          ])

        assert conn.status == 400

        assert %{"error" => %{"code" => @header_mismatch, "message" => message}} =
                 decode(conn)

        assert message =~ "Mcp-Method header is malformed"
      end
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

    test "rejects requests that violate the complete method-specific schema", %{runtime: runtime} do
      capabilities = %{"extensions" => %{"example.extension/invalid" => "not-an-object"}}

      conn =
        post(
          runtime,
          Protocol.method(:tools_call),
          %{"name" => "echo", "arguments" => %{"message" => "hi"}},
          headers: [{"mcp-name", "echo"}],
          meta: %{Protocol.meta_key(:client_capabilities) => capabilities}
        )

      assert conn.status == 400
      assert %{"error" => %{"code" => @invalid_params}} = decode(conn)
    end

    test "validates extension capability identifiers", %{runtime: runtime} do
      valid = %{"extensions" => %{"com.example/feature" => %{}}}

      assert post(runtime, Protocol.method(:server_discover), %{},
               meta: %{Protocol.meta_key(:client_capabilities) => valid}
             ).status == 200

      for identifier <- ["tasks", "bad key"] do
        capabilities = %{"extensions" => %{identifier => %{}}}

        conn =
          post(runtime, Protocol.method(:server_discover), %{},
            meta: %{Protocol.meta_key(:client_capabilities) => capabilities}
          )

        assert conn.status == 400
        assert %{"error" => %{"code" => @invalid_params}} = decode(conn)
      end
    end

    test "rejects legacy and future-phase methods", %{runtime: runtime} do
      requests = [
        {"", %{}, []},
        {"initialize", %{}, []},
        {"notifications/initialized", %{}, []},
        {"tasks/result", %{}, []},
        {"tasks/list", %{}, []},
        {"tasks/get", %{"taskId" => "t-1"}, [{"mcp-name", "t-1"}]},
        {"tasks/update", %{"taskId" => "t-1"}, [{"mcp-name", "t-1"}]},
        {"tasks/cancel", %{"taskId" => "t-1"}, [{"mcp-name", "t-1"}]},
        {Protocol.method(:resources_read), %{"uri" => "tama://resource/1"},
         [{"mcp-name", "tama://resource/1"}]},
        {Protocol.method(:prompts_get), %{"name" => "summarize"}, [{"mcp-name", "summarize"}]},
        {"subscriptions/listen", %{}, []}
      ]

      for {method, params, headers} <- requests do
        conn = post(runtime, method, params, headers: headers)
        assert conn.status == 404
        assert %{"error" => %{"code" => @method_not_found}} = decode(conn)
      end
    end

    test "preserves an empty string request ID in boundary errors", %{runtime: runtime} do
      conn =
        post(runtime, Protocol.method(:server_discover), %{},
          id: "",
          headers: [{"mcp-name", "unexpected"}]
        )

      assert conn.status == 400
      assert %{"id" => "", "error" => %{"code" => @header_mismatch}} = decode(conn)
    end

    test "fails closed when authorization rejects the request", %{runtime: runtime} do
      conn =
        post(runtime, Protocol.method(:server_discover), %{}, token: "bad")

      assert conn.status == 401
      assert %{"error" => %{"code" => @invalid_request}} = decode(conn)
    end

    test "bounds selected context headers using the configured metadata limit" do
      runtime =
        Plug.init(
          server: TamaMCP.TestSupport.Server,
          authorization: TamaMCP.TestSupport.Authorization,
          cache: TamaMCP.TestSupport.Cache,
          context_headers: ["X-Trace"],
          limits: [max_safe_metadata_bytes: 64]
        )

      conn =
        post(runtime, Protocol.method(:tools_call), %{"name" => "context"},
          headers: [{"mcp-name", "context"}, {"x-trace", String.duplicate("x", 128)}]
        )

      assert conn.status == 200
      assert decode(conn)["result"]["structuredContent"]["trace"] == "omitted"
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
    headers =
      if Enum.any?(headers, fn {name, _value} -> String.downcase(name) == "x-test-token" end),
        do: headers,
        else: [{"x-test-token", "ok"} | headers]

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

  defp result_runtime(maximum) do
    Plug.init(
      server: TamaMCP.TestSupport.Server,
      authorization: TamaMCP.TestSupport.Authorization,
      cache: TamaMCP.TestSupport.Cache,
      limits: [max_result_bytes: maximum]
    )
  end

  defp static_result_size do
    [Result.discover(Server), Result.tools(Server)]
    |> Enum.map(&(Jason.encode!(&1) |> byte_size()))
    |> Enum.max()
  end

  defp result_params(placement, value) do
    %{"name" => "result", "arguments" => %{"placement" => placement, "value" => value}}
  end

  defp decode(%{resp_body: body}) do
    Jason.decode!(body)
  end
end
