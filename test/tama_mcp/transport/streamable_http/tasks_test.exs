defmodule TamaMCP.Transport.StreamableHTTP.TasksTest.OptionalTool do
  @moduledoc false

  use TamaMCP.Tool, task: :optional, scopes: ["test.task_required"]

  input_schema do
    field(:value, :string, required: true)
  end

  @impl true
  def call(%{"value" => value}, _context) do
    {:ok, TamaMCP.Response.success(content: [TamaMCP.Response.text(value)])}
  end
end

defmodule TamaMCP.Transport.StreamableHTTP.TasksTest.OptionalServer do
  @moduledoc false

  use TamaMCP.Server, name: "optional-tasks", version: "1.0.0"

  tool(TamaMCP.Transport.StreamableHTTP.TasksTest.OptionalTool, name: "optional")
end

defmodule TamaMCP.Transport.StreamableHTTP.TasksTest do
  @moduledoc false

  use ExUnit.Case
  import ExUnit.CaptureLog
  import Plug.Test

  alias TamaMCP.{Error, Protocol, Task}
  alias TamaMCP.TestSupport.Tasks.Store
  alias TamaMCP.Transport.StreamableHTTP.Plug, as: MCPPlug
  alias TamaMCP.Transport.StreamableHTTP.Runtime

  @version Protocol.version()
  @missing_capability Protocol.error_code(:missing_required_client_capability)
  @invalid_params Protocol.error_code(:invalid_params)
  @internal Protocol.error_code(:internal)
  @later ~U[2026-09-14 12:00:01Z]

  setup do
    {:ok, store} = Store.start_link()
    {:ok, runtime: runtime(store, self()), store: store}
  end

  test "advertises Tasks only for a completely configured runtime", %{runtime: runtime} do
    conn = post(runtime, Protocol.method(:server_discover), %{}, capabilities: false)

    assert conn.status == 200

    assert get_in(decode(conn), [
             "result",
             "capabilities",
             "extensions",
             Protocol.tasks_extension()
           ]) ==
             %{}

    phase1 =
      MCPPlug.init(
        server: TamaMCP.TestSupport.Server,
        authorization: TamaMCP.TestSupport.Authorization,
        cache: TamaMCP.TestSupport.Cache
      )

    conn = post(phase1, Protocol.method(:server_discover), %{}, capabilities: false)
    refute get_in(decode(conn), ["result", "capabilities", "extensions"])
  end

  test "a required tool creates a durable working task only with per-request capability", %{
    runtime: runtime,
    store: store
  } do
    params = %{"name" => "task_required", "arguments" => %{"value" => "hello"}}

    conn =
      post(runtime, Protocol.method(:tools_call), params,
        name: "task_required",
        capabilities: false
      )

    assert conn.status == 400
    assert get_in(decode(conn), ["error", "code"]) == @missing_capability
    assert {:error, :not_found} = Store.get("test-owner", "task-phase2-1", agent: store)

    conn =
      post(runtime, Protocol.method(:tools_call), params,
        name: "task_required",
        capabilities: true
      )

    assert conn.status == 200
    result = decode(conn)["result"]
    assert result["resultType"] == "task"
    assert result["taskId"] == "task-phase2-1"
    assert result["status"] == "working"

    arguments = params["arguments"]

    assert_receive {:task_started, TamaMCP.TestSupport.Tools.TaskRequired, ^arguments, context,
                    %Task{} = task}

    assert context.task_id == task.id
    assert context.owner_key == "test-owner"
    assert context.request_id == 1
    assert context.method == Protocol.method(:tools_call)
    assert context.name == "task_required"
    assert context.principal == "test-principal"
    assert context.claims == %{"sub" => "test-principal"}
    assert "test.task_required" in context.scopes
    assert context.assigns == %{workspace: "test-workspace"}
    assert context.headers == %{}
    assert {:ok, ^task} = Store.get("test-owner", task.id, agent: store)

    conn = post(runtime, Protocol.method(:tasks_get), %{"taskId" => task.id}, name: task.id)
    assert conn.status == 200
    assert get_in(decode(conn), ["result", "status"]) == "working"
  end

  test "task methods require capability and preserve owner indistinguishability", %{
    runtime: runtime
  } do
    task = create_task(runtime)

    without_capability =
      post(runtime, Protocol.method(:tasks_get), %{"taskId" => task.id},
        name: task.id,
        capabilities: false
      )

    assert without_capability.status == 400
    assert get_in(decode(without_capability), ["error", "code"]) == @missing_capability

    unauthorized =
      post(runtime, Protocol.method(:tasks_get), %{"taskId" => task.id},
        name: task.id,
        token: "other"
      )

    missing =
      post(runtime, Protocol.method(:tasks_get), %{"taskId" => "missing"}, name: "missing")

    assert unauthorized.status == 400
    assert missing.status == 400
    assert get_in(decode(unauthorized), ["error", "code"]) == @invalid_params
    assert get_in(decode(missing), ["error", "code"]) == @invalid_params

    assert get_in(decode(unauthorized), ["error", "message"]) ==
             get_in(decode(missing), ["error", "message"])
  end

  test "task methods fail closed when authorization does not provide an owner", %{
    runtime: runtime
  } do
    conn =
      post(runtime, Protocol.method(:tasks_get), %{"taskId" => "task-phase2-1"},
        name: "task-phase2-1",
        token: "ownerless"
      )

    assert conn.status == 500
    assert get_in(decode(conn), ["error", "code"]) == @internal
    refute conn.resp_body =~ "ownerless-principal"
  end

  test "task execution rejects an ownerless decision before invoking the runner", %{
    runtime: runtime,
    store: store
  } do
    conn =
      post(
        runtime,
        Protocol.method(:tools_call),
        %{"name" => "task_required", "arguments" => %{"value" => "hello"}},
        name: "task_required",
        token: "ownerless"
      )

    assert conn.status == 500
    assert get_in(decode(conn), ["error", "code"]) == @internal
    refute_receive {:task_started, _, _, _, _}
    assert {:error, :not_found} = Store.get(nil, "task-phase2-1", agent: store)
  end

  test "tasks/update accepts only outstanding input response keys", %{runtime: runtime} do
    task = create_task(runtime)
    requests = %{"approval" => elicitation_request()}

    assert {:ok, waiting} =
             Store.transition(
               task.owner_key,
               task.id,
               task.revision,
               :input_required,
               %{input_requests: requests, last_updated_at: @later},
               Runtime.effective_task_store_options(runtime)
             )

    responses = %{
      "approval" => %{"action" => "accept", "content" => %{"approved" => true}},
      "unknown" => %{"action" => "decline"}
    }

    conn =
      post(
        runtime,
        Protocol.method(:tasks_update),
        %{"taskId" => waiting.id, "inputResponses" => responses},
        name: waiting.id
      )

    assert conn.status == 200
    assert decode(conn)["result"]["resultType"] == "complete"

    assert_receive {:task_updated, "task-phase2-1",
                    %{"approval" => %{"action" => "accept", "content" => %{"approved" => true}}}}

    working_runtime = %{runtime | identifier_options: [task_id: "task-phase2-2"]}
    working = create_task(working_runtime)

    conn =
      post(
        working_runtime,
        Protocol.method(:tasks_update),
        %{"taskId" => working.id, "inputResponses" => %{}},
        name: working.id
      )

    assert conn.status == 400
    assert get_in(decode(conn), ["error", "code"]) == @invalid_params

    missing =
      post(
        runtime,
        Protocol.method(:tasks_update),
        %{"taskId" => "missing", "inputResponses" => %{}},
        name: "missing"
      )

    assert missing.status == 400
    assert get_in(decode(missing), ["error", "message"]) == "Task was not found"
  end

  test "tasks/cancel acknowledges cooperative intent without promising a state", %{
    runtime: runtime
  } do
    task = create_task(runtime)

    conn = post(runtime, Protocol.method(:tasks_cancel), %{"taskId" => task.id}, name: task.id)

    assert conn.status == 200
    assert decode(conn)["result"]["resultType"] == "complete"
    assert_receive {:task_cancelled, "task-phase2-1"}

    assert {:ok, persisted} =
             Store.get(task.owner_key, task.id, runtime.task_store_options)

    assert persisted.status == :working

    missing =
      post(runtime, Protocol.method(:tasks_cancel), %{"taskId" => "missing"}, name: "missing")

    assert missing.status == 400
    assert get_in(decode(missing), ["error", "message"]) == "Task was not found"
  end

  test "tasks/get encodes every state and cancellation preserves terminal winners", %{
    runtime: runtime,
    store: store
  } do
    transitions = [
      {:input_required, %{input_requests: %{"approval" => elicitation_request()}}},
      {:completed,
       %{
         result: %{
           "resultType" => "complete",
           "content" => [%{"type" => "text", "text" => "done"}],
           "isError" => false
         }
       }},
      {:failed, %{error: Error.internal("Durable execution failed")}},
      {:cancelled, %{}}
    ]

    for {{status, attributes}, offset} <- Enum.with_index(transitions, 1) do
      identifier = "task-state-#{status}"
      state_runtime = %{runtime | identifier_options: [task_id: identifier]}
      task = create_task(state_runtime)
      attributes = Map.put(attributes, :last_updated_at, DateTime.add(@later, offset, :second))

      assert {:ok, persisted} =
               Store.transition(
                 task.owner_key,
                 task.id,
                 task.revision,
                 status,
                 attributes,
                 Runtime.effective_task_store_options(state_runtime)
               )

      get =
        post(runtime, Protocol.method(:tasks_get), %{"taskId" => identifier}, name: identifier)

      result = decode(get)["result"]

      assert get.status == 200
      assert result["status"] == Protocol.task_status(status)
      assert_state_payload(result, status)

      cancel =
        post(runtime, Protocol.method(:tasks_cancel), %{"taskId" => identifier}, name: identifier)

      if Task.terminal?(persisted) do
        assert cancel.status == 400
        assert get_in(decode(cancel), ["error", "code"]) == @invalid_params
        assert {:ok, ^persisted} = Store.get(task.owner_key, task.id, agent: store)
      else
        assert cancel.status == 200
      end
    end
  end

  test "task request schemas and routing headers fail closed", %{runtime: runtime} do
    conn =
      post(runtime, Protocol.method(:tasks_update), %{"taskId" => "task-phase2-1"},
        name: "task-phase2-1"
      )

    assert conn.status == 400
    assert get_in(decode(conn), ["error", "code"]) == @invalid_params

    conn =
      post(runtime, Protocol.method(:tasks_get), %{"taskId" => "task-phase2-1"},
        name: "different"
      )

    assert conn.status == 400
    assert get_in(decode(conn), ["error", "code"]) == Protocol.error_code(:header_mismatch)
  end

  test "invalid runner returns remain internal and expose no handle", %{
    runtime: runtime,
    store: store
  } do
    runtime = %{runtime | task_runner_options: [result: :invalid]}

    log =
      capture_log(fn ->
        conn =
          post(
            runtime,
            Protocol.method(:tools_call),
            %{"name" => "task_required", "arguments" => %{"value" => "hello"}},
            name: "task_required"
          )

        assert conn.status == 500
        assert get_in(decode(conn), ["error", "code"]) == @internal
        refute decode(conn)["result"]
      end)

    refute log =~ "invalid"
    assert {:error, :not_found} = Store.get("test-owner", "task-phase2-1", agent: store)
  end

  test "durability verification accepts a task that advances before lookup", %{
    runtime: runtime,
    store: store
  } do
    completed_result = %{
      "resultType" => "complete",
      "content" => [%{"type" => "text", "text" => "finished immediately"}],
      "isError" => false
    }

    runtime = %{
      runtime
      | task_runner_options: [
          test: self(),
          transition_after_create:
            {:completed, %{last_updated_at: @later, result: completed_result}}
        ]
    }

    conn =
      post(
        runtime,
        Protocol.method(:tools_call),
        %{"name" => "task_required", "arguments" => %{"value" => "hello"}},
        name: "task_required"
      )

    assert conn.status == 200
    assert get_in(decode(conn), ["result", "status"]) == "working"
    assert_receive {:task_started, _, _, _, %Task{} = initial}

    assert {:ok, persisted} = Store.get(initial.owner_key, initial.id, agent: store)
    assert persisted.status == :completed
    assert persisted.revision == initial.revision + 1
  end

  test "task creation honors explicitly raised runtime bounds", %{store: store} do
    runtime =
      runtime(store, self(),
        limits: [
          default_task_ttl_ms: 691_200_000,
          max_task_ttl_ms: 777_600_000,
          max_status_message_bytes: 4_096
        ]
      )

    task = create_task(runtime)

    assert task.ttl_ms == 691_200_000
    assert {:ok, ^task} = Store.get(task.owner_key, task.id, agent: store)
  end

  test "store transitions reject task results that exceed the transport result bound", %{
    store: store
  } do
    runtime = runtime(store, self(), limits: [max_result_bytes: 1_024])
    task = create_task(runtime)

    oversized = %{
      "resultType" => "complete",
      "content" => [%{"type" => "text", "text" => String.duplicate("x", 2_048)}],
      "isError" => false
    }

    assert {:error, :invalid_task} =
             Store.transition(
               task.owner_key,
               task.id,
               task.revision,
               :completed,
               %{result: oversized, last_updated_at: @later},
               Runtime.effective_task_store_options(runtime)
             )

    assert {:ok, ^task} = Store.get(task.owner_key, task.id, agent: store)
  end

  test "store transitions reject schema-invalid task payloads before commit", %{
    runtime: runtime
  } do
    task = create_task(runtime)
    options = Runtime.effective_task_store_options(runtime)

    invalid_transitions = [
      {:input_required, %{input_requests: %{"approval" => %{}}}},
      {:completed, %{result: %{}}}
    ]

    for {status, attributes} <- invalid_transitions do
      attributes = Map.put(attributes, :last_updated_at, @later)

      assert {:error, :invalid_task} =
               Store.transition(
                 task.owner_key,
                 task.id,
                 task.revision,
                 status,
                 attributes,
                 options
               )

      assert {:ok, ^task} = Store.get(task.owner_key, task.id, options)
    end
  end

  test "optional task selection is explicit and defaults to synchronous", %{store: store} do
    synchronous = runtime(store, self(), server: __MODULE__.OptionalServer, selector: nil)

    conn =
      post(
        synchronous,
        Protocol.method(:tools_call),
        %{"name" => "optional", "arguments" => %{"value" => "sync"}},
        name: "optional"
      )

    assert conn.status == 200
    assert decode(conn)["result"]["resultType"] == "complete"

    task_runtime = runtime(store, self(), server: __MODULE__.OptionalServer, selector: :task)

    conn =
      post(
        task_runtime,
        Protocol.method(:tools_call),
        %{"name" => "optional", "arguments" => %{"value" => "task"}},
        name: "optional"
      )

    assert conn.status == 200
    assert decode(conn)["result"]["resultType"] == "task"
  end

  defp create_task(runtime) do
    conn =
      post(
        runtime,
        Protocol.method(:tools_call),
        %{"name" => "task_required", "arguments" => %{"value" => "hello"}},
        name: "task_required"
      )

    assert conn.status == 200
    assert_receive {:task_started, _, _, _, %Task{} = task}
    task
  end

  defp runtime(store, test, options \\ []) do
    server = Keyword.get(options, :server, TamaMCP.TestSupport.TaskRequiredServer)

    runtime_options = [
      server: server,
      authorization: TamaMCP.TestSupport.Authorization,
      cache: TamaMCP.TestSupport.Cache,
      task_store: Store,
      task_store_options: [agent: store, test: test],
      task_runner: TamaMCP.TestSupport.Tasks.Runner,
      task_runner_options: [test: test],
      clock: TamaMCP.TestSupport.Tasks.Clock,
      identifier: TamaMCP.TestSupport.Tasks.Identifier
    ]

    runtime_options =
      case Keyword.fetch(options, :limits) do
        {:ok, limits} -> Keyword.put(runtime_options, :limits, limits)
        :error -> runtime_options
      end

    runtime_options =
      case Keyword.get(options, :selector, :task) do
        nil -> runtime_options
        :task -> Keyword.put(runtime_options, :task_selector, fn _, _, _ -> :task end)
      end

    MCPPlug.init(runtime_options)
  end

  defp post(runtime, method, params, options) do
    capabilities? = Keyword.get(options, :capabilities, true)

    extensions =
      if capabilities?, do: %{Protocol.tasks_extension() => %{}}, else: %{}

    params =
      Map.put(params, "_meta", %{
        Protocol.meta_key(:protocol_version) => @version,
        Protocol.meta_key(:client_capabilities) => %{"extensions" => extensions},
        Protocol.meta_key(:client_info) => %{"name" => "phase2-test", "version" => "1.0.0"}
      })

    headers = [
      {"mcp-protocol-version", @version},
      {"mcp-method", method},
      {"content-type", "application/json"},
      {"accept", "application/json, text/event-stream"},
      {"x-test-token", Keyword.get(options, :token, "ok")}
    ]

    headers =
      case Keyword.get(options, :name) do
        nil -> headers
        name -> [{"mcp-name", name} | headers]
      end

    body = Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => params})

    :post
    |> conn("/", body)
    |> Map.put(:req_headers, headers)
    |> MCPPlug.call(runtime)
  end

  defp elicitation_request do
    %{
      "method" => "elicitation/create",
      "params" => %{
        "message" => "Approve?",
        "mode" => "form",
        "requestedSchema" => %{
          "type" => "object",
          "properties" => %{"approved" => %{"type" => "boolean"}},
          "required" => ["approved"]
        }
      }
    }
  end

  defp assert_state_payload(result, :input_required) do
    assert is_map(result["inputRequests"])
    refute Map.has_key?(result, "result")
    refute Map.has_key?(result, "error")
  end

  defp assert_state_payload(result, :completed) do
    assert result["result"]["resultType"] == "complete"
    refute Map.has_key?(result, "inputRequests")
    refute Map.has_key?(result, "error")
  end

  defp assert_state_payload(result, :failed) do
    assert result["error"]["code"] == @internal
    refute Map.has_key?(result, "inputRequests")
    refute Map.has_key?(result, "result")
  end

  defp assert_state_payload(result, :cancelled) do
    refute Map.has_key?(result, "inputRequests")
    refute Map.has_key?(result, "result")
    refute Map.has_key?(result, "error")
  end

  defp decode(conn), do: Jason.decode!(conn.resp_body)
end
