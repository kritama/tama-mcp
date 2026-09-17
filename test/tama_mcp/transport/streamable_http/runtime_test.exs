defmodule TamaMCP.Transport.StreamableHTTP.RuntimeTest do
  @moduledoc false

  use ExUnit.Case

  alias TamaMCP.Authorization.Challenge
  alias TamaMCP.Transport.StreamableHTTP.{Result, Runtime}

  defmodule Verbose do
    @moduledoc false

    def name, do: "verbose"
    def version, do: "1.0.0"
    def instructions, do: String.duplicate("instruction", 32)
    def tools, do: []
    def tool(_name), do: nil
  end

  @valid [
    server: TamaMCP.TestSupport.Server,
    authorization: TamaMCP.TestSupport.Authorization,
    cache: TamaMCP.TestSupport.Cache
  ]

  @unloaded TamaMCP.TestSupport.Fakes.NeverDefinedServer
  @plain TamaMCP.TestSupport.Fakes.PlainModule

  describe "build/1" do
    test "builds a valid Phase 1 runtime" do
      runtime = Runtime.build(@valid)

      assert runtime.server == TamaMCP.TestSupport.Server
      assert runtime.authorization == TamaMCP.TestSupport.Authorization
      assert runtime.authorization_options == []
      assert runtime.cache == TamaMCP.TestSupport.Cache
      assert runtime.cache_options == []
      assert runtime.telemetry_prefix == [:tama_mcp]
      assert runtime.safe_metadata == nil
      assert runtime.context_headers == []
      assert runtime.limits.max_body_bytes == 1_048_576
      assert runtime.limits.max_result_bytes == 1_048_576
      assert runtime.limits.max_tools_per_server == 256
      assert runtime.limits.max_input_request_keys_per_task == 256
      assert runtime.limits.max_www_authenticate_bytes == 4_096
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

    test "rejects a compiled module that is missing fetch/3" do
      assert_raise ArgumentError, ~r/does not implement TamaMCP.Cache/, fn ->
        Runtime.build(
          server: TamaMCP.TestSupport.Server,
          authorization: TamaMCP.TestSupport.Authorization,
          cache: @plain
        )
      end
    end
  end

  describe "option validation" do
    test "rejects a non-keyword authorization_options" do
      assert_raise ArgumentError, ~r/authorization_options must be a keyword list/, fn ->
        Runtime.build(@valid ++ [authorization_options: "not-a-keyword"])
      end
    end

    test "rejects non-keyword cache_options" do
      assert_raise ArgumentError, ~r/cache_options must be a keyword list/, fn ->
        Runtime.build(@valid ++ [cache_options: "not-a-keyword"])
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

      assert_raise ArgumentError, ~r/positive integer/, fn ->
        Runtime.build(@valid ++ [limits: [max_input_request_keys_per_task: 0]])
      end

      assert_raise ArgumentError, ~r/at least 2/, fn ->
        Runtime.build(@valid ++ [limits: [max_safe_metadata_bytes: 1]])
      end

      assert_raise ArgumentError,
                   ~r/max_www_authenticate_bytes must be an integer of at least/,
                   fn ->
                     Runtime.build(
                       @valid ++
                         [limits: [max_www_authenticate_bytes: Challenge.minimum_size() - 1]]
                     )
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

    test "rejects scope challenges that exceed the configured response-header limit" do
      {:ok, challenge} = Challenge.insufficient_scope(["test.echo"], 1_024)

      assert_raise ArgumentError, ~r/scope challenge exceeds.*max_www_authenticate_bytes/, fn ->
        Runtime.build(
          @valid ++
            [limits: [max_www_authenticate_bytes: byte_size(challenge) - 1]]
        )
      end
    end

    test "rejects discovery results that exceed the configured result limit" do
      assert_raise ArgumentError, ~r/server\/discover result exceeds.*max_result_bytes/, fn ->
        Runtime.build(
          server: Verbose,
          authorization: TamaMCP.TestSupport.Authorization,
          cache: TamaMCP.TestSupport.Cache,
          limits: [max_result_bytes: 64]
        )
      end
    end

    test "rejects tool-list results that exceed the configured result limit" do
      discovery_size =
        Result.discover(TamaMCP.TestSupport.Server) |> Jason.encode!() |> byte_size()

      assert Result.tools(TamaMCP.TestSupport.Server) |> Jason.encode!() |> byte_size() >
               discovery_size

      assert_raise ArgumentError, ~r/tools\/list result exceeds.*max_result_bytes/, fn ->
        Runtime.build(@valid ++ [limits: [max_result_bytes: discovery_size]])
      end
    end
  end

  describe "phase boundaries and task configuration" do
    test "rejects unknown top-level options" do
      assert_raise ArgumentError, ~r/unknown option/, fn ->
        Runtime.build(@valid ++ [bogus: true])
      end
    end

    test "validates Phase 3 notification configuration as a complete task extension" do
      assert_raise ArgumentError, ~r/notification requires task_store and task_runner/, fn ->
        Runtime.build(@valid ++ [notification: TamaMCP.Notification.Local])
      end

      assert_raise ArgumentError, ~r/notification_options requires notification/, fn ->
        Runtime.build(@valid ++ [notification_options: [server: self()]])
      end

      assert_raise ArgumentError, ~r/does not implement TamaMCP.Notification/, fn ->
        Runtime.build(
          @valid ++
            [
              task_store: TamaMCP.TestSupport.Tasks.Store,
              task_runner: TamaMCP.TestSupport.Tasks.Runner,
              notification: @plain
            ]
        )
      end
    end

    test "provides bounded Phase 2 defaults and validates their relationship" do
      runtime = Runtime.build(@valid)

      assert runtime.limits.default_task_ttl_ms == 86_400_000
      assert runtime.limits.max_task_ttl_ms == 604_800_000
      assert runtime.limits.default_poll_interval_ms == 1_000
      assert runtime.limits.max_input_request_keys_per_task == 256
      assert runtime.limits.max_task_ids_per_subscription == 100
      assert runtime.limits.notification_buffer_capacity == 100
      assert runtime.limits.stream_keepalive_interval_ms == 15_000
      assert runtime.limits.stream_authorization_recheck_ms == 60_000
      assert runtime.limits.stream_max_lifetime_ms == 3_600_000
      assert runtime.limits.max_status_message_bytes == 2_048

      assert_raise ArgumentError, ~r/cannot exceed/, fn ->
        Runtime.build(
          @valid ++
            [limits: [default_task_ttl_ms: 2_000, max_task_ttl_ms: 1_000]]
        )
      end

      for key <- [:default_task_ttl_ms, :max_task_ttl_ms, :default_poll_interval_ms] do
        assert_raise ArgumentError, ~r/positive protocol-safe integer/, fn ->
          Runtime.build(@valid ++ [limits: [{key, 9_007_199_254_740_992}]])
        end
      end
    end

    test "rejects a server containing a task-required tool" do
      assert_raise ArgumentError, ~r/task policy :required/, fn ->
        Runtime.build(
          server: TamaMCP.TestSupport.TaskRequiredServer,
          authorization: TamaMCP.TestSupport.Authorization,
          cache: TamaMCP.TestSupport.Cache
        )
      end
    end

    test "rejects partial and invalid task adapter configuration" do
      assert_raise ArgumentError, ~r/task_store requires task_runner/, fn ->
        Runtime.build(@valid ++ [task_store: TamaMCP.TestSupport.Tasks.Store])
      end

      assert_raise ArgumentError, ~r/task_runner requires task_store/, fn ->
        Runtime.build(@valid ++ [task_runner: TamaMCP.TestSupport.Tasks.Runner])
      end

      assert_raise ArgumentError, ~r/does not implement TamaMCP.Task.Store/, fn ->
        Runtime.build(
          @valid ++
            [task_store: @plain, task_runner: TamaMCP.TestSupport.Tasks.Runner]
        )
      end

      assert_raise ArgumentError, ~r/task_selector requires/, fn ->
        Runtime.build(@valid ++ [task_selector: fn _, _, _ -> :sync end])
      end
    end

    test "accepts a complete task runtime and task-required tools" do
      runtime =
        Runtime.build(
          server: TamaMCP.TestSupport.TaskRequiredServer,
          authorization: TamaMCP.TestSupport.Authorization,
          cache: TamaMCP.TestSupport.Cache,
          task_store: TamaMCP.TestSupport.Tasks.Store,
          task_runner: TamaMCP.TestSupport.Tasks.Runner,
          clock: TamaMCP.TestSupport.Tasks.Clock,
          identifier: TamaMCP.TestSupport.Tasks.Identifier,
          task_selector: fn _, _, _ -> :task end
        )

      assert Runtime.task_capable?(runtime)
      assert is_function(runtime.task_selector, 3)

      assert %{"extensions" => extensions} =
               Result.discover(runtime.server, true)["capabilities"]

      assert extensions[TamaMCP.tasks_extension()] == %{}
    end

    test "accepts a notification adapter on a complete task runtime" do
      runtime =
        Runtime.build(
          server: TamaMCP.TestSupport.TaskRequiredServer,
          authorization: TamaMCP.TestSupport.Authorization,
          cache: TamaMCP.TestSupport.Cache,
          task_store: TamaMCP.TestSupport.Tasks.Store,
          task_runner: TamaMCP.TestSupport.Tasks.Runner,
          notification: TamaMCP.Notification.Local,
          notification_options: [server: self()]
        )

      assert Runtime.notification_capable?(runtime)
      assert runtime.notification_options == [server: self()]
    end
  end
end
