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
    test = Keyword.fetch!(options, :test)

    case Map.get(state, :registration, :ok) do
      :error ->
        {:error, TamaMCP.Error.internal()}

      :block ->
        reference = make_ref()
        send(test, {:invalidation_registration_blocked, subscriber, reference})

        receive do
          {:continue_invalidation_registration, ^reference} -> {:ok, reference}
        after
          1_000 -> {:error, TamaMCP.Error.internal()}
        end

      :ok ->
        reference = make_ref()
        send(test, {:invalidation_registered, subscriber, reference})
        {:ok, reference}
    end
  end

  @impl true
  def unregister_invalidation(reference, options) do
    state = Agent.get(Keyword.fetch!(options, :agent), & &1)
    test = Keyword.fetch!(options, :test)

    if Map.get(state, :invalidate_on_unregister, false),
      do: send(self(), TamaMCP.Authorization.invalidation(reference))

    send(test, {:invalidation_unregistered, reference})
    :ok
  end
end

defmodule TamaMCP.Transport.StreamableHTTP.SubscriptionsTest.BlockingStore do
  @moduledoc false

  @behaviour TamaMCP.Task.Store

  alias TamaMCP.TestSupport.Tasks.Store

  @impl true
  def create(task, options), do: Store.create(task, options)

  @impl true
  def get(owner_key, task_id, options) do
    gate = Keyword.fetch!(options, :gate)

    block? =
      Agent.get_and_update(gate, fn
        {:pass_then_block, remaining} when remaining > 0 ->
          {false, {:pass_then_block, remaining - 1}}

        {:pass_then_block, 0} = state ->
          {true, state}

        :block ->
          {true, :block}

        state ->
          {false, state}
      end)

    if block? do
      reference = make_ref()
      send(Keyword.fetch!(options, :test), {:task_get_blocked, self(), reference})

      receive do
        {:continue_task_get, ^reference} -> :ok
      after
        1_000 -> :ok
      end
    end

    Store.get(owner_key, task_id, options)
  end

  @impl true
  def transition(owner_key, task_id, revision, status, attributes, options),
    do: Store.transition(owner_key, task_id, revision, status, attributes, options)

  @impl true
  def update(owner_key, task_id, input_responses, options),
    do: Store.update(owner_key, task_id, input_responses, options)

  @impl true
  def cancel(owner_key, task_id, options), do: Store.cancel(owner_key, task_id, options)
end

defmodule TamaMCP.Transport.StreamableHTTP.SubscriptionsTest.MismatchedOwnerStore do
  @moduledoc false

  @behaviour TamaMCP.Task.Store

  alias TamaMCP.TestSupport.Tasks.Store

  @impl true
  def create(task, options), do: Store.create(task, options)

  @impl true
  def get(_owner_key, task_id, options), do: Store.get(1.0, task_id, options)

  @impl true
  def transition(owner_key, task_id, revision, status, attributes, options),
    do: Store.transition(owner_key, task_id, revision, status, attributes, options)

  @impl true
  def update(owner_key, task_id, input_responses, options),
    do: Store.update(owner_key, task_id, input_responses, options)

  @impl true
  def cancel(owner_key, task_id, options), do: Store.cancel(owner_key, task_id, options)
end

defmodule TamaMCP.Transport.StreamableHTTP.SubscriptionsTest.BlockingCache do
  @moduledoc false

  @behaviour TamaMCP.Cache

  @impl true
  def fetch(key, loader, options) do
    gate = Keyword.fetch!(options, :gate)

    block? =
      String.contains?(key, ":task_status_notification_params:") and
        Agent.get_and_update(gate, fn
          :block_once -> {true, :pass}
          state -> {false, state}
        end)

    if block? do
      reference = make_ref()
      send(Keyword.fetch!(options, :test), {:notification_validation_blocked, self(), reference})

      receive do
        {:continue_notification_validation, ^reference} -> :ok
      after
        1_000 -> :ok
      end
    end

    {:ok, loader.()}
  end
end

defmodule TamaMCP.Transport.StreamableHTTP.SubscriptionsTest.FirstChunkClosedAdapter do
  @moduledoc false

  alias Plug.Adapters.Test.Conn

  def read_req_body(payload, options), do: Conn.read_req_body(payload, options)

  def send_resp(payload, status, headers, body),
    do: Conn.send_resp(payload, status, headers, body)

  def send_chunked(payload, status, headers),
    do: Conn.send_chunked(payload, status, headers)

  def chunk(_payload, _body), do: {:error, :closed}
end

defmodule TamaMCP.Transport.StreamableHTTP.SubscriptionsTest.ObservedChunkAdapter do
  @moduledoc false

  alias Plug.Adapters.Test.Conn

  def read_req_body(payload, options), do: Conn.read_req_body(payload, options)

  def send_resp(payload, status, headers, body),
    do: Conn.send_resp(payload, status, headers, body)

  def send_chunked(payload, status, headers),
    do: Conn.send_chunked(payload, status, headers)

  def chunk(%{owner: owner} = payload, body) do
    result = Conn.chunk(payload, body)
    send(owner, {:response_chunked, self()})
    result
  end
end

defmodule TamaMCP.Transport.StreamableHTTP.SubscriptionsTest.QueuedOverflowNotification do
  @moduledoc false

  @behaviour TamaMCP.Notification

  @impl true
  def subscribe(_task_ids, subscriber, _capacity, options) do
    reference = make_ref()
    send(Keyword.fetch!(options, :test), {:notification_subscribed, reference})
    send(subscriber, TamaMCP.Notification.ready(reference))
    send(subscriber, TamaMCP.Notification.overflow(reference))
    {:ok, reference}
  end

  @impl true
  def take(_subscription, _options), do: {:error, :overflow}

  @impl true
  def unsubscribe(_subscription, _options), do: :ok

  @impl true
  def publish(_task, _options), do: :ok
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
  alias TamaMCP.Notification
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

  test "omits task filters that the client did not request", %{runtime: runtime} do
    stream =
      start_stream(runtime, [],
        capabilities: false,
        notifications: %{"toolsListChanged" => true}
      )

    assert_receive {:invalidation_registered, _, _}, 1_000
    conn = Elixir.Task.await(stream, 1_000)
    [acknowledgement | _events] = data_events(conn)

    assert acknowledgement["params"]["notifications"] == %{}
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
    conn = request(runtime, [task.id], [])
    {_adapter, payload} = conn.adapter
    conn = %{conn | adapter: {__MODULE__.ObservedChunkAdapter, payload}}
    stream = Elixir.Task.async(fn -> MCPPlug.call(conn, runtime) end)
    assert_receive {:invalidation_registered, stream_pid, reference}, 1_000
    assert_receive {:reauthorized, ^stream_pid, "test-owner"}, 1_000
    assert_receive {:response_chunked, ^stream_pid}, 1_000

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
    assert_receive {:reauthorized, ^stream_pid, "test-owner"}, 1_000

    Agent.update(authorization, &%{&1 | mode: :deny})
    assert :ok = Local.publish(task, server: notification)
    conn = Elixir.Task.await(stream, 1_000)

    assert_receive {:reauthorized, ^stream_pid, "test-owner"}, 1_000
    assert [acknowledgement, closing] = data_events(conn)
    assert acknowledgement["method"] == Protocol.notification(:subscriptions_acknowledged)
    assert closing["result"]["resultType"] == "complete"
  end

  test "delivery rechecks credential expiry after durable task lookups", %{
    store: store,
    notification: notification,
    authorization: authorization,
    task: task
  } do
    {:ok, gate} = Agent.start_link(fn -> {:pass_then_block, 2} end)

    runtime =
      runtime(store, notification, authorization, self(),
        task_store: __MODULE__.BlockingStore,
        task_store_options: [agent: store, gate: gate, test: self()],
        limits: [
          stream_keepalive_interval_ms: 1_000,
          stream_authorization_recheck_ms: 1_000,
          stream_max_lifetime_ms: 500
        ]
      )

    stream = start_stream(runtime, [task.id])
    assert_receive {:invalidation_registered, stream_pid, _reference}, 1_000
    assert_receive {:reauthorized, ^stream_pid, "test-owner"}, 1_000

    expires_at = DateTime.add(DateTime.utc_now(), 50, :millisecond)
    Agent.update(authorization, &%{&1 | expires_at: expires_at})
    assert :ok = Local.publish(task, server: notification)
    assert_receive {:task_get_blocked, ^stream_pid, reference}, 1_000

    wait_until_expired(expires_at)
    send(stream_pid, {:continue_task_get, reference})

    conn = Elixir.Task.await(stream, 1_000)
    assert [acknowledgement, closing] = data_events(conn)
    assert acknowledgement["method"] == Protocol.notification(:subscriptions_acknowledged)
    assert closing["result"]["resultType"] == "complete"
  end

  test "delivery rechecks a queued invalidation after durable task lookups", %{
    store: store,
    notification: notification,
    authorization: authorization,
    task: task
  } do
    {:ok, gate} = Agent.start_link(fn -> {:pass_then_block, 2} end)

    runtime =
      runtime(store, notification, authorization, self(),
        task_store: __MODULE__.BlockingStore,
        task_store_options: [agent: store, gate: gate, test: self()],
        limits: [
          stream_keepalive_interval_ms: 1_000,
          stream_authorization_recheck_ms: 1_000,
          stream_max_lifetime_ms: 1_000
        ]
      )

    stream = start_stream(runtime, [task.id])
    assert_receive {:invalidation_registered, stream_pid, invalidation}, 1_000
    assert_receive {:reauthorized, ^stream_pid, "test-owner"}, 1_000

    assert :ok = Local.publish(task, server: notification)
    assert_receive {:reauthorized, ^stream_pid, "test-owner"}, 1_000
    assert_receive {:task_get_blocked, ^stream_pid, reference}, 1_000

    Agent.update(authorization, &%{&1 | mode: :deny})
    send(stream_pid, Authorization.invalidation(invalidation))
    send(stream_pid, {:continue_task_get, reference})

    conn = Elixir.Task.await(stream, 1_000)
    assert_receive {:reauthorized, ^stream_pid, "test-owner"}, 1_000
    assert [acknowledgement, closing] = data_events(conn)
    assert acknowledgement["method"] == Protocol.notification(:subscriptions_acknowledged)
    assert closing["result"]["resultType"] == "complete"
  end

  test "delivery rechecks credential expiry after notification serialization", %{
    store: store,
    notification: notification,
    authorization: authorization,
    task: task
  } do
    {:ok, gate} = Agent.start_link(fn -> :block_once end)

    runtime =
      runtime(store, notification, authorization, self(),
        cache: __MODULE__.BlockingCache,
        cache_options: [gate: gate, test: self()],
        limits: [
          stream_keepalive_interval_ms: 1_000,
          stream_authorization_recheck_ms: 1_000,
          stream_max_lifetime_ms: 500
        ]
      )

    stream = start_stream(runtime, [task.id])
    assert_receive {:invalidation_registered, stream_pid, _reference}, 1_000
    assert_receive {:reauthorized, ^stream_pid, "test-owner"}, 1_000

    expires_at = DateTime.add(DateTime.utc_now(), 50, :millisecond)
    Agent.update(authorization, &%{&1 | expires_at: expires_at})
    assert :ok = Local.publish(task, server: notification)

    assert_receive {:notification_validation_blocked, ^stream_pid, reference}, 1_000
    wait_until_expired(expires_at)
    send(stream_pid, {:continue_notification_validation, reference})

    conn = Elixir.Task.await(stream, 1_000)
    assert [acknowledgement, closing] = data_events(conn)
    assert acknowledgement["method"] == Protocol.notification(:subscriptions_acknowledged)
    assert closing["result"]["resultType"] == "complete"
  end

  test "delivery enforces the maximum stream lifetime after durable task lookups", %{
    store: store,
    notification: notification,
    authorization: authorization,
    task: task
  } do
    {:ok, gate} = Agent.start_link(fn -> {:pass_then_block, 2} end)

    runtime =
      runtime(store, notification, authorization, self(),
        task_store: __MODULE__.BlockingStore,
        task_store_options: [agent: store, gate: gate, test: self()],
        limits: [
          stream_keepalive_interval_ms: 1_000,
          stream_authorization_recheck_ms: 1_000,
          stream_max_lifetime_ms: 500
        ]
      )

    stream = start_stream(runtime, [task.id])
    assert_receive {:invalidation_registered, stream_pid, _reference}, 1_000
    assert_receive {:reauthorized, ^stream_pid, "test-owner"}, 1_000

    assert :ok = Local.publish(task, server: notification)
    assert_receive {:task_get_blocked, ^stream_pid, reference}, 1_000

    Process.sleep(510)
    send(stream_pid, {:continue_task_get, reference})

    conn = Elixir.Task.await(stream, 1_000)
    assert [acknowledgement, closing] = data_events(conn)
    assert acknowledgement["method"] == Protocol.notification(:subscriptions_acknowledged)
    assert closing["result"]["resultType"] == "complete"
  end

  test "uses exact owner identity for returned task snapshots", %{
    store: store,
    notification: notification,
    authorization: authorization
  } do
    Agent.update(authorization, &%{&1 | owner_key: 1})

    runtime =
      runtime(store, notification, authorization, self(),
        task_store: __MODULE__.MismatchedOwnerStore
      )

    task = create_task(runtime, store, 1.0, "task-numeric-owner")
    stream = start_stream(runtime, [task.id])
    conn = Elixir.Task.await(stream, 1_000)

    assert conn.status == 500
    assert data_events(conn) == []
    assert Jason.decode!(conn.resp_body)["error"]["message"] == "Internal error"
  end

  test "uses exact owner identity across pre-open reauthorization", %{
    store: store,
    notification: notification,
    authorization: authorization
  } do
    Agent.update(authorization, &Map.merge(&1, %{owner_key: 1, registration: :block}))
    runtime = runtime(store, notification, authorization, self())
    task = create_task(runtime, store, 1, "task-shared-numeric-owner")
    _other = create_task(runtime, store, 1.0, task.id)
    stream = start_stream(runtime, [task.id])

    assert_receive {:invalidation_registration_blocked, stream_pid, reference}, 1_000
    Agent.update(authorization, &%{&1 | owner_key: 1.0})
    send(stream_pid, {:continue_invalidation_registration, reference})

    conn = Elixir.Task.await(stream, 1_000)
    assert conn.status == 500
    assert Jason.decode!(conn.resp_body)["error"]["message"] == "Internal error"
    assert_receive {:invalidation_unregistered, ^reference}, 1_000
  end

  test "a delivery hint is resolved back through the durable store", %{
    store: store,
    authorization: authorization,
    task: task,
    notification: notification
  } do
    runtime =
      runtime(store, notification, authorization, self(),
        limits: [
          stream_keepalive_interval_ms: 1_000,
          stream_authorization_recheck_ms: 1_000,
          stream_max_lifetime_ms: 500
        ]
      )

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
    assert_receive {:reauthorized, ^stream_pid, "test-owner"}, 1_000
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

  test "cleanup drains queued signals for a closed subscription", %{
    store: store,
    authorization: authorization,
    task: task
  } do
    runtime =
      runtime(store, __MODULE__.QueuedOverflowNotification, authorization, self(),
        notification_options: [test: self()]
      )

    conn = runtime |> request([task.id], []) |> MCPPlug.call(runtime)
    assert conn.status == 200
    assert_receive {:notification_subscribed, subscription}, 1_000

    refute_receive {Notification, ^subscription, :ready}, 0
    refute_receive {Notification, ^subscription, :overflow}, 0
  end

  test "cleanup drains queued authorization invalidations", %{
    runtime: runtime,
    authorization: authorization
  } do
    Agent.update(authorization, &Map.put(&1, :invalidate_on_unregister, true))

    conn = runtime |> request([], []) |> MCPPlug.call(runtime)
    assert conn.status == 200
    assert_receive {:invalidation_registered, _, reference}, 1_000
    assert_receive {:invalidation_unregistered, ^reference}, 1_000
    refute_receive {Authorization, ^reference, :invalidated}, 0
  end

  test "emits keepalive comments and closes at the credential deadline", %{
    store: store,
    notification: notification,
    authorization: authorization,
    task: task
  } do
    expires_at = DateTime.add(DateTime.utc_now(), 150, :millisecond)
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

  test "rechecks credential expiry immediately before acknowledging the stream", %{
    runtime: runtime,
    authorization: authorization,
    task: task
  } do
    expires_at = DateTime.add(DateTime.utc_now(), 50, :millisecond)
    Agent.update(authorization, &Map.merge(&1, %{expires_at: expires_at, registration: :block}))

    stream = start_stream(runtime, [task.id])

    assert_receive {:invalidation_registration_blocked, stream_pid, reference}, 1_000
    wait_until_expired(expires_at)
    send(stream_pid, {:continue_invalidation_registration, reference})

    conn = Elixir.Task.await(stream, 1_000)
    assert conn.status == 401
    assert Jason.decode!(conn.resp_body)["error"]["message"] == "Credential has expired"
    assert_receive {:invalidation_unregistered, ^reference}, 1_000
  end

  test "reauthorizes changed policy immediately before acknowledging the stream", %{
    runtime: runtime,
    authorization: authorization,
    task: task
  } do
    Agent.update(authorization, &Map.put(&1, :registration, :block))
    stream = start_stream(runtime, [task.id])

    assert_receive {:invalidation_registration_blocked, stream_pid, reference}, 1_000
    Agent.update(authorization, &%{&1 | mode: :deny})
    send(stream_pid, {:continue_invalidation_registration, reference})

    conn = Elixir.Task.await(stream, 1_000)
    assert conn.status == 401
    assert Jason.decode!(conn.resp_body)["error"]["message"] == "credential rejected"

    assert Plug.Conn.get_resp_header(conn, "www-authenticate") == [
             ~s(Bearer error="invalid_token")
           ]

    assert_receive {:invalidation_unregistered, ^reference}, 1_000
  end

  test "rechecks a queued invalidation before acknowledging the stream", %{
    store: store,
    notification: notification,
    authorization: authorization,
    task: task
  } do
    {:ok, gate} = Agent.start_link(fn -> {:pass_then_block, 1} end)

    runtime =
      runtime(store, notification, authorization, self(),
        task_store: __MODULE__.BlockingStore,
        task_store_options: [agent: store, gate: gate, test: self()]
      )

    stream = start_stream(runtime, [task.id])
    assert_receive {:invalidation_registered, stream_pid, invalidation}, 1_000
    assert_receive {:reauthorized, ^stream_pid, "test-owner"}, 1_000
    assert_receive {:task_get_blocked, ^stream_pid, reference}, 1_000

    Agent.update(authorization, &%{&1 | mode: :deny})
    send(stream_pid, Authorization.invalidation(invalidation))
    send(stream_pid, {:continue_task_get, reference})

    conn = Elixir.Task.await(stream, 1_000)
    assert_receive {:reauthorized, ^stream_pid, "test-owner"}, 1_000
    assert conn.status == 401
    assert data_events(conn) == []

    assert Plug.Conn.get_resp_header(conn, "www-authenticate") == [
             ~s(Bearer error="invalid_token")
           ]
  end

  test "returns the committed connection when the acknowledgement chunk fails", %{
    runtime: runtime,
    task: task
  } do
    conn = request(runtime, [task.id], [])
    {_adapter, payload} = conn.adapter
    conn = %{conn | adapter: {__MODULE__.FirstChunkClosedAdapter, payload}}

    conn = MCPPlug.call(conn, runtime)

    assert conn.status == 200
    assert conn.state == :chunked
    assert conn.resp_body == ""
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
    task_store = Keyword.get(options, :task_store, Store)
    task_store_options = Keyword.get(options, :task_store_options, agent: store)
    cache = Keyword.get(options, :cache, TamaMCP.TestSupport.Cache)
    cache_options = Keyword.get(options, :cache_options, [])

    runtime_options = [
      server: TamaMCP.TestSupport.TaskRequiredServer,
      authorization: __MODULE__.Authorization,
      authorization_options: [agent: authorization, test: test],
      cache: cache,
      cache_options: cache_options,
      task_store: task_store,
      task_store_options: task_store_options,
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

    notifications = Keyword.get(options, :notifications, %{"taskIds" => task_ids})

    params = %{
      "_meta" => %{
        Protocol.meta_key(:protocol_version) => @version,
        Protocol.meta_key(:client_capabilities) => %{"extensions" => extensions},
        Protocol.meta_key(:client_info) => %{"name" => "phase3-test", "version" => "1.0.0"}
      },
      "notifications" => notifications
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

  defp wait_until_expired(expires_at) do
    remaining = DateTime.diff(expires_at, DateTime.utc_now(), :millisecond)
    if remaining >= 0, do: Process.sleep(remaining + 2)
  end

  @doc false
  def handle(name, _measurements, metadata, test), do: send(test, {:event, name, metadata})
end
