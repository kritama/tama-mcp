defmodule TamaMCP.Transport.StreamableHTTP.SubscriptionsTest.Authorization do
  @moduledoc false

  use TamaMCP.Authorization

  alias TamaMCP.Authorization.Decision

  @impl true
  def authenticate(_conn, options) do
    state = Agent.get(Keyword.fetch!(options, :agent), & &1)

    case state.mode do
      :ok ->
        {:ok,
         %Decision{
           principal: "stream-principal",
           claims: %{"sub" => "stream-principal"},
           scopes: ["test.task_required"],
           owner_key: state.owner_key,
           expires_at: state.expires_at
         }}

      :deny ->
        {:error, TamaMCP.Error.invalid_request("credential rejected")}

      :raise ->
        raise "authorization secret must not leak"

      :invalid ->
        :invalid
    end
  end

  @impl true
  def reauthorize(conn, decision, options) do
    send(Keyword.fetch!(options, :test), {:reauthorized, self(), decision.owner_key})
    authenticate(conn, options)
  end

  @impl true
  def register_invalidation(_decision, subscriber, options) do
    state = Agent.get(Keyword.fetch!(options, :agent), & &1)

    if Map.get(state, :registration) == :error do
      {:error, TamaMCP.Error.internal()}
    else
      reference = make_ref()
      send(Keyword.fetch!(options, :test), {:invalidation_registered, subscriber, reference})
      {:ok, reference}
    end
  end

  @impl true
  def unregister_invalidation(reference, options) do
    send(Keyword.fetch!(options, :test), {:invalidation_unregistered, reference})
    :ok
  end
end

defmodule TamaMCP.Transport.StreamableHTTP.SubscriptionsTest.OverflowNotification do
  @moduledoc false

  @behaviour TamaMCP.Notification

  @impl true
  def subscribe(_task_ids, subscriber, _capacity, options) do
    reference = make_ref()
    send(Keyword.fetch!(options, :test), {:notification_subscribed, reference})
    Process.send_after(subscriber, TamaMCP.Notification.overflow(reference), 10)
    {:ok, reference}
  end

  @impl true
  def take(_subscription, _options), do: {:error, :overflow}

  @impl true
  def unsubscribe(subscription, options) do
    send(Keyword.fetch!(options, :test), {:notification_unsubscribed, subscription})
    :ok
  end

  @impl true
  def publish(_task, _options), do: :ok
end

defmodule TamaMCP.Transport.StreamableHTTP.SubscriptionsTest.FaultyNotification do
  @moduledoc false

  @behaviour TamaMCP.Notification

  @impl true
  def subscribe(_task_ids, _subscriber, _capacity, options) do
    case Keyword.fetch!(options, :mode) do
      :raise -> raise "notification secret must not leak"
      :throw -> throw("notification secret must not leak")
      :exit -> exit("notification secret must not leak")
      :invalid -> {:adapter, "notification secret must not leak"}
    end
  end

  @impl true
  def take(_subscription, _options), do: :empty

  @impl true
  def unsubscribe(_subscription, _options), do: :ok

  @impl true
  def publish(_task, _options), do: :ok
end

defmodule TamaMCP.Transport.StreamableHTTP.SubscriptionsTest do
  @moduledoc false

  use ExUnit.Case
  import Plug.Test

  alias TamaMCP.Authorization
  alias TamaMCP.Notification.Local
  alias TamaMCP.{Protocol, Task}
  alias TamaMCP.TestSupport.Tasks.Store
  alias TamaMCP.Transport.StreamableHTTP.Plug, as: MCPPlug
  alias TamaMCP.Transport.StreamableHTTP.Runtime

  @version Protocol.version()
  @missing_capability Protocol.error_code(:missing_required_client_capability)

  setup do
    {:ok, store} = Store.start_link()
    {:ok, notification} = Local.start_link()

    {:ok, authorization} =
      Agent.start_link(fn -> %{mode: :ok, owner_key: "test-owner", expires_at: nil} end)

    runtime = runtime(store, notification, authorization, self())
    task = create_task(runtime, store, "test-owner", "task-phase3-1")

    {:ok,
     runtime: runtime,
     store: store,
     notification: notification,
     authorization: authorization,
     task: task}
  end

  test "acknowledges first, delivers a current detailed task, and closes gracefully", %{
    runtime: runtime,
    notification: notification,
    task: task
  } do
    stream = start_stream(runtime, [task.id])
    assert_receive {:invalidation_registered, stream_pid, reference}, 1_000
    assert stream.pid == stream_pid

    assert :ok = Local.publish(task, server: notification)
    conn = Elixir.Task.await(stream, 1_000)
    events = data_events(conn)

    assert [acknowledgement, notification, closing] = events
    assert acknowledgement["method"] == Protocol.notification(:subscriptions_acknowledged)
    assert get_in(acknowledgement, ["params", "notifications", "taskIds"]) == [task.id]

    assert notification["method"] == Protocol.notification(:tasks)
    assert notification["params"]["taskId"] == task.id
    assert notification["params"]["status"] == "working"
    refute Map.has_key?(notification["params"], "resultType")

    assert closing["id"] == "listen-1"
    assert closing["result"]["resultType"] == "complete"

    for event <- events do
      location = if event["method"], do: ["params", "_meta"], else: ["result", "_meta"]
      assert get_in(event, location)[Protocol.meta_key(:subscription_id)] == "listen-1"
    end

    assert_receive {:invalidation_unregistered, ^reference}, 1_000
  end

  test "acknowledges only the owner-authorized subset", %{
    runtime: runtime,
    store: store,
    task: task
  } do
    _other = create_task(runtime, store, "other-owner", "task-other")

    stream = start_stream(runtime, ["missing", task.id, "task-other", task.id])
    conn = Elixir.Task.await(stream, 1_000)
    assert conn.status == 200, conn.resp_body
    assert_receive {:invalidation_registered, _, _}, 1_000
    [acknowledgement | _events] = data_events(conn)

    assert get_in(acknowledgement, ["params", "notifications", "taskIds"]) == [task.id]
  end

  test "requires the Tasks capability only when task IDs are requested", %{runtime: runtime} do
    conn = runtime |> request(["task-phase3-1"], capabilities: false) |> MCPPlug.call(runtime)

    assert conn.status == 400
    assert Jason.decode!(conn.resp_body)["error"]["code"] == @missing_capability

    stream = start_stream(runtime, [], capabilities: false)
    assert_receive {:invalidation_registered, _, _}, 1_000
    conn = Elixir.Task.await(stream, 1_000)
    [acknowledgement | _events] = data_events(conn)
    assert get_in(acknowledgement, ["params", "notifications", "taskIds"]) == []
  end

  test "a task runtime without a notification adapter truthfully acknowledges no task IDs", %{
    store: store,
    authorization: authorization,
    task: task
  } do
    runtime = runtime(store, nil, authorization, self())
    stream = start_stream(runtime, [task.id])
    assert_receive {:invalidation_registered, _, _}, 1_000
    conn = Elixir.Task.await(stream, 1_000)
    [acknowledgement | _events] = data_events(conn)

    assert get_in(acknowledgement, ["params", "notifications", "taskIds"]) == []
  end

  test "policy invalidation rechecks authorization and closes before task delivery", %{
    runtime: runtime,
    authorization: authorization,
    task: task
  } do
    stream = start_stream(runtime, [task.id])
    assert_receive {:invalidation_registered, stream_pid, reference}, 1_000

    Agent.update(authorization, &%{&1 | mode: :deny})
    send(stream_pid, Authorization.invalidation(reference))

    conn = Elixir.Task.await(stream, 1_000)
    events = data_events(conn)

    assert_receive {:reauthorized, ^stream_pid, "test-owner"}, 1_000

    assert Enum.map(events, & &1["method"]) == [
             Protocol.notification(:subscriptions_acknowledged),
             nil
           ]
  end

  test "delivery-time reauthorization closes before a task snapshot is sent", %{
    runtime: runtime,
    authorization: authorization,
    task: task,
    notification: notification
  } do
    stream = start_stream(runtime, [task.id])
    assert_receive {:invalidation_registered, stream_pid, _reference}, 1_000

    Agent.update(authorization, &%{&1 | mode: :deny})
    assert :ok = Local.publish(task, server: notification)
    conn = Elixir.Task.await(stream, 1_000)

    assert_receive {:reauthorized, ^stream_pid, "test-owner"}, 1_000
    assert [acknowledgement, closing] = data_events(conn)
    assert acknowledgement["method"] == Protocol.notification(:subscriptions_acknowledged)
    assert closing["result"]["resultType"] == "complete"
  end

  test "a delivery hint is resolved back through the durable store", %{
    runtime: runtime,
    task: task,
    notification: notification
  } do
    stream = start_stream(runtime, [task.id])
    assert_receive {:invalidation_registered, _, _}, 1_000

    result = %{
      "resultType" => "complete",
      "content" => [%{"type" => "text", "text" => "done"}],
      "isError" => false
    }

    assert {:ok, completed} =
             Store.transition(
               task.owner_key,
               task.id,
               task.revision,
               :completed,
               %{result: result, last_updated_at: DateTime.add(task.last_updated_at, 1, :second)},
               Runtime.effective_task_store_options(runtime)
             )

    assert :ok = Local.publish(task, server: notification)
    conn = Elixir.Task.await(stream, 1_000)
    [_acknowledgement, notification, _closing] = data_events(conn)

    assert notification["params"]["status"] == "completed"
    assert notification["params"]["result"] == completed.result
  end

  test "periodic reauthorization closes on a changed owner binding", %{
    store: store,
    notification: notification,
    authorization: authorization,
    task: task
  } do
    runtime =
      runtime(store, notification, authorization, self(),
        limits: [
          stream_keepalive_interval_ms: 1_000,
          stream_authorization_recheck_ms: 10,
          stream_max_lifetime_ms: 200
        ]
      )

    stream = start_stream(runtime, [task.id])
    assert_receive {:invalidation_registered, stream_pid, _}, 1_000
    Agent.update(authorization, &%{&1 | owner_key: "changed-owner"})
    conn = Elixir.Task.await(stream, 1_000)

    assert_receive {:reauthorized, ^stream_pid, "test-owner"}, 1_000
    assert [acknowledgement, closing] = data_events(conn)
    assert acknowledgement["method"] == Protocol.notification(:subscriptions_acknowledged)
    assert closing["result"]["resultType"] == "complete"
  end

  test "overflow closes the stream and cleans up the adapter subscription", %{
    store: store,
    authorization: authorization,
    task: task
  } do
    events =
      for suffix <- [[:open], [:acknowledgement], [:overflow], [:close]] do
        [:tama_mcp, :subscription] ++ suffix
      end

    handler = "subscription-events-#{System.unique_integer([:positive])}"
    :ok = :telemetry.attach_many(handler, events, &__MODULE__.handle/4, self())
    on_exit(fn -> :telemetry.detach(handler) end)

    runtime =
      runtime(store, __MODULE__.OverflowNotification, authorization, self(),
        notification_options: [test: self()]
      )

    stream = start_stream(runtime, [task.id])
    assert_receive {:notification_subscribed, subscription}, 1_000
    assert_receive {:invalidation_registered, _, _}, 1_000
    conn = Elixir.Task.await(stream, 1_000)

    assert [acknowledgement, closing] = data_events(conn)
    assert acknowledgement["method"] == Protocol.notification(:subscriptions_acknowledged)
    assert closing["result"]["resultType"] == "complete"
    assert_receive {:notification_unsubscribed, ^subscription}, 1_000

    for event <- events do
      assert_receive {:event, ^event, metadata}, 1_000
      assert metadata.method == Protocol.method(:subscriptions_listen)
      refute Map.has_key?(metadata, :owner_key)
      refute Map.has_key?(metadata, :task)
    end
  end

  test "emits keepalive comments and closes at the credential deadline", %{
    store: store,
    notification: notification,
    authorization: authorization,
    task: task
  } do
    expires_at = DateTime.add(DateTime.utc_now(), 40, :millisecond)
    Agent.update(authorization, &%{&1 | expires_at: expires_at})

    runtime =
      runtime(store, notification, authorization, self(),
        limits: [
          stream_keepalive_interval_ms: 5,
          stream_authorization_recheck_ms: 100,
          stream_max_lifetime_ms: 500
        ]
      )

    stream = start_stream(runtime, [task.id])
    assert_receive {:invalidation_registered, _, _}, 1_000
    conn = Elixir.Task.await(stream, 1_000)

    assert conn.resp_body =~ ": keepalive\n\n"
    assert [acknowledgement | _events] = data_events(conn)
    assert acknowledgement["method"] == Protocol.notification(:subscriptions_acknowledged)
  end

  test "rejects expired credentials and subscription bounds before opening a stream", %{
    runtime: runtime,
    authorization: authorization
  } do
    Agent.update(
      authorization,
      &%{&1 | expires_at: DateTime.add(DateTime.utc_now(), -1, :second)}
    )

    expired = runtime |> request([], []) |> MCPPlug.call(runtime)
    assert expired.status == 401
    assert Jason.decode!(expired.resp_body)["error"]["message"] == "Credential has expired"

    Agent.update(authorization, &%{&1 | expires_at: nil})

    too_many =
      runtime
      |> request(Enum.map(1..101, &"task-#{&1}"), [])
      |> MCPPlug.call(runtime)

    assert too_many.status == 400

    assert Jason.decode!(too_many.resp_body)["error"]["message"] =~
             "max_task_ids_per_subscription"
  end

  test "contains notification adapter failures before response streaming", %{
    store: store,
    authorization: authorization,
    task: task
  } do
    for mode <- [:raise, :throw, :exit, :invalid] do
      runtime =
        runtime(store, __MODULE__.FaultyNotification, authorization, self(),
          notification_options: [mode: mode]
        )

      conn = runtime |> request([task.id], []) |> MCPPlug.call(runtime)
      assert conn.status == 500
      assert Jason.decode!(conn.resp_body)["error"]["message"] == "Internal error"
      refute conn.resp_body =~ "notification secret"
    end
  end

  test "cleans up a notification subscription when invalidation registration fails", %{
    store: store,
    authorization: authorization,
    task: task
  } do
    Agent.update(authorization, &Map.put(&1, :registration, :error))

    runtime =
      runtime(store, __MODULE__.OverflowNotification, authorization, self(),
        notification_options: [test: self()]
      )

    conn = runtime |> request([task.id], []) |> MCPPlug.call(runtime)
    assert conn.status == 500
    assert_receive {:notification_subscribed, subscription}, 1_000
    assert_receive {:notification_unsubscribed, ^subscription}, 1_000
    refute_receive {:invalidation_registered, _, _}
  end

  defp runtime(store, notification, authorization, test, options \\ []) do
    notification_options = Keyword.get(options, :notification_options, server: notification)

    runtime_options = [
      server: TamaMCP.TestSupport.TaskRequiredServer,
      authorization: __MODULE__.Authorization,
      authorization_options: [agent: authorization, test: test],
      cache: TamaMCP.TestSupport.Cache,
      task_store: Store,
      task_store_options: [agent: store],
      task_runner: TamaMCP.TestSupport.Tasks.Runner,
      clock: TamaMCP.TestSupport.Tasks.Clock,
      identifier: TamaMCP.TestSupport.Tasks.Identifier,
      limits:
        Keyword.get(options, :limits,
          stream_keepalive_interval_ms: 1_000,
          stream_authorization_recheck_ms: 1_000,
          stream_max_lifetime_ms: 100
        )
    ]

    runtime_options =
      if is_nil(notification) do
        runtime_options
      else
        runtime_options ++
          [
            notification: notification_module(notification),
            notification_options: notification_options
          ]
      end

    MCPPlug.init(runtime_options)
  end

  defp notification_module(notification) when is_pid(notification), do: Local
  defp notification_module(notification), do: notification

  defp create_task(runtime, _store, owner_key, id) do
    {:ok, task} =
      Task.new(
        %{
          id: id,
          owner_key: owner_key,
          method: Protocol.method(:tools_call),
          request_id: "call-1",
          client_capabilities: %{
            "extensions" => %{Protocol.tasks_extension() => %{}}
          },
          created_at: ~U[2026-09-15 12:00:00Z],
          last_updated_at: ~U[2026-09-15 12:00:00Z],
          ttl_ms: 86_400_000,
          poll_interval_ms: 1_000,
          status_message: "Working"
        },
        Runtime.task_validation_options(runtime, TamaMCP.TestSupport.Tools.TaskRequired)
      )

    assert {:ok, ^task} = Store.create(task, Runtime.effective_task_store_options(runtime))
    task
  end

  defp start_stream(runtime, task_ids, options \\ []) do
    conn = request(runtime, task_ids, options)
    Elixir.Task.async(fn -> MCPPlug.call(conn, runtime) end)
  end

  defp request(_runtime, task_ids, options) do
    extensions =
      if Keyword.get(options, :capabilities, true),
        do: %{Protocol.tasks_extension() => %{}},
        else: %{}

    params = %{
      "_meta" => %{
        Protocol.meta_key(:protocol_version) => @version,
        Protocol.meta_key(:client_capabilities) => %{"extensions" => extensions},
        Protocol.meta_key(:client_info) => %{"name" => "phase3-test", "version" => "1.0.0"}
      },
      "notifications" => %{"taskIds" => task_ids}
    }

    body =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => "listen-1",
        "method" => Protocol.method(:subscriptions_listen),
        "params" => params
      })

    headers = [
      {"mcp-protocol-version", @version},
      {"mcp-method", Protocol.method(:subscriptions_listen)},
      {"content-type", "application/json"},
      {"accept", "application/json, text/event-stream"}
    ]

    :post
    |> conn("/", body)
    |> Map.put(:req_headers, headers)
  end

  defp data_events(conn) do
    conn.resp_body
    |> String.split("\n\n", trim: true)
    |> Enum.filter(&String.starts_with?(&1, "data: "))
    |> Enum.map(fn "data: " <> json -> Jason.decode!(json) end)
  end

  @doc false
  def handle(name, _measurements, metadata, test), do: send(test, {:event, name, metadata})
end
