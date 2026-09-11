defmodule TamaMCP.Transport.StreamableHTTP.RuntimeTest do
  @moduledoc false

  use ExUnit.Case

  alias TamaMCP.Transport.StreamableHTTP.Runtime

  @valid [
    server: TamaMCP.TestSupport.Server,
    authorization: TamaMCP.TestSupport.Authorization
  ]

  @unloaded TamaMCP.TestSupport.Fakes.NeverDefinedServer
  @plain TamaMCP.TestSupport.Fakes.PlainModule

  describe "build/1" do
    test "builds a valid Phase 1 runtime" do
      runtime = Runtime.build(@valid)

      assert runtime.server == TamaMCP.TestSupport.Server
      assert runtime.authorization == TamaMCP.TestSupport.Authorization
      assert runtime.authorization_options == []
      assert runtime.telemetry_prefix == [:tama_mcp]
      assert runtime.safe_metadata == nil
      assert runtime.context_headers == []
      assert runtime.limits.max_body_bytes == 1_048_576
      assert runtime.limits.max_tool_result_bytes == 1_048_576
      assert runtime.limits.max_tools_per_server == 256
      assert runtime.limits.request_timeout_ms == 30_000
    end

    test "normalizes limits, headers, and telemetry prefix" do
      runtime =
        Runtime.build(
          @valid ++
            [
              limits: [max_body_bytes: 1024],
              context_headers: ["X-Request-Id"],
              telemetry_prefix: [:tama_mcp, :test]
            ]
        )

      assert runtime.limits.max_body_bytes == 1024
      assert runtime.limits.body_read_timeout_ms == 5_000
      assert runtime.context_headers == ["x-request-id"]
      assert runtime.telemetry_prefix == [:tama_mcp, :test]
    end

    test "accepts a {module, function} safe_metadata callback" do
      runtime =
        Runtime.build(
          @valid ++ [safe_metadata: {TamaMCP.TestSupport.Fakes.PlainModule, :metadata}]
        )

      assert is_function(runtime.safe_metadata, 2)
      assert runtime.safe_metadata.("x", %{}) == %{origin: :fake}
    end

    test "accepts a direct safe_metadata callback" do
      callback = fn _method, _meta -> %{safe: true} end
      runtime = Runtime.build(@valid ++ [safe_metadata: callback])
      assert runtime.safe_metadata.("x", %{}) == %{safe: true}
    end
  end

  describe "module validation" do
    test "rejects a nil server" do
      assert_raise ArgumentError, ~r/expected a compiled module/, fn ->
        Runtime.build(server: nil, authorization: TamaMCP.TestSupport.Authorization)
      end
    end

    test "rejects a non-atom server" do
      assert_raise ArgumentError, ~r/expected a compiled module/, fn ->
        Runtime.build(server: "not-a-module", authorization: TamaMCP.TestSupport.Authorization)
      end
    end

    test "rejects an unloaded module atom as the server" do
      assert_raise ArgumentError, ~r/not a compiled TamaMCP server/, fn ->
        Runtime.build(server: @unloaded, authorization: TamaMCP.TestSupport.Authorization)
      end
    end

    test "rejects a compiled module that is missing the server contract" do
      assert_raise ArgumentError, ~r/not a compiled TamaMCP server/, fn ->
        Runtime.build(server: @plain, authorization: TamaMCP.TestSupport.Authorization)
      end
    end

    test "rejects a nil authorization" do
      assert_raise ArgumentError, ~r/expected a compiled module/, fn ->
        Runtime.build(server: TamaMCP.TestSupport.Server, authorization: nil)
      end
    end

    test "rejects a compiled module that is missing authenticate/2" do
      assert_raise ArgumentError, ~r/does not implement/, fn ->
        Runtime.build(server: TamaMCP.TestSupport.Server, authorization: @plain)
      end
    end

    test "rejects an unloaded authorization module" do
      assert_raise ArgumentError, ~r/does not implement/, fn ->
        Runtime.build(server: TamaMCP.TestSupport.Server, authorization: @unloaded)
      end
    end
  end

  describe "option validation" do
    test "rejects a non-keyword authorization_options" do
      assert_raise ArgumentError, ~r/authorization_options must be a keyword list/, fn ->
        Runtime.build(@valid ++ [authorization_options: "not-a-keyword"])
      end
    end

    test "rejects non-keyword top-level options" do
      assert_raise ArgumentError, ~r/options must be a keyword list/, fn ->
        Runtime.build(%{server: TamaMCP.TestSupport.Server})
      end
    end

    test "rejects invalid safe_metadata callbacks" do
      assert_raise ArgumentError, ~r/safe_metadata/, fn ->
        Runtime.build(@valid ++ [safe_metadata: :invalid])
      end

      assert_raise ArgumentError, ~r/not an exported function/, fn ->
        Runtime.build(
          @valid ++ [safe_metadata: {TamaMCP.TestSupport.Fakes.PlainModule, :missing}]
        )
      end
    end

    test "rejects a telemetry_prefix containing a non-atom" do
      assert_raise ArgumentError, ~r/telemetry_prefix/, fn ->
        Runtime.build(@valid ++ [telemetry_prefix: [:ok, "not-an-atom"]])
      end
    end

    test "rejects an empty telemetry_prefix" do
      assert_raise ArgumentError, ~r/telemetry_prefix/, fn ->
        Runtime.build(@valid ++ [telemetry_prefix: []])
      end
    end

    test "rejects context_headers that are not binaries" do
      assert_raise ArgumentError, ~r/context_headers/, fn ->
        Runtime.build(@valid ++ [context_headers: [1, 2]])
      end
    end

    test "rejects an empty-string context header" do
      assert_raise ArgumentError, ~r/context_headers/, fn ->
        Runtime.build(@valid ++ [context_headers: [""]])
      end
    end

    test "rejects malformed and duplicate context header names" do
      assert_raise ArgumentError, ~r/context_headers/, fn ->
        Runtime.build(@valid ++ [context_headers: ["not a header"]])
      end

      assert_raise ArgumentError, ~r/duplicate/, fn ->
        Runtime.build(@valid ++ [context_headers: ["X-Trace", "x-trace"]])
      end
    end

    test "rejects duplicate top-level and limit options" do
      assert_raise ArgumentError, ~r/duplicate option/, fn ->
        Runtime.build(@valid ++ [server: TamaMCP.TestSupport.Server])
      end

      assert_raise ArgumentError, ~r/duplicate .*override/, fn ->
        Runtime.build(@valid ++ [limits: [max_body_bytes: 1, max_body_bytes: 2]])
      end
    end

    test "rejects malformed limit collections and values" do
      assert_raise ArgumentError, ~r/keyword list or map/, fn ->
        Runtime.build(@valid ++ [limits: [:not_a_pair]])
      end

      assert_raise ArgumentError, ~r/keyword list or map/, fn ->
        Runtime.build(@valid ++ [limits: "invalid"])
      end

      assert_raise ArgumentError, ~r/positive integer/, fn ->
        Runtime.build(@valid ++ [limits: [max_body_bytes: 0]])
      end

      assert_raise ArgumentError, ~r/at least 2/, fn ->
        Runtime.build(@valid ++ [limits: [max_safe_metadata_bytes: 1]])
      end
    end

    test "rejects schemas that exceed the configured byte limit" do
      assert_raise ArgumentError, ~r/max_schema_bytes/, fn ->
        Runtime.build(@valid ++ [limits: [max_schema_bytes: 1]])
      end
    end

    test "rejects catalogs that exceed the configured tool limit" do
      assert_raise ArgumentError, ~r/max_tools_per_server/, fn ->
        Runtime.build(@valid ++ [limits: [max_tools_per_server: 1]])
      end
    end
  end

  describe "Phase 1 boundary" do
    test "rejects unknown top-level options" do
      assert_raise ArgumentError, ~r/unknown option/, fn ->
        Runtime.build(@valid ++ [bogus: true])
      end
    end

    test "rejects every future-phase adapter option" do
      future = [
        :clock,
        :identifier,
        :task_store,
        :task_store_options,
        :task_runner,
        :task_runner_options,
        :notification_bus,
        :notification_bus_options
      ]

      for option <- future do
        assert_raise ArgumentError, ~r/unknown option/, fn ->
          Runtime.build(@valid ++ [{option, TamaMCP.TestSupport.Authorization}])
        end
      end
    end

    test "rejects a future-phase limit override" do
      assert_raise ArgumentError, ~r/unknown limit/, fn ->
        Runtime.build(@valid ++ [limits: [default_task_ttl_ms: 1_000]])
      end
    end

    test "rejects a server containing a task-required tool" do
      assert_raise ArgumentError, ~r/task policy :required/, fn ->
        Runtime.build(
          server: TamaMCP.TestSupport.TaskRequiredServer,
          authorization: TamaMCP.TestSupport.Authorization
        )
      end
    end
  end
end
