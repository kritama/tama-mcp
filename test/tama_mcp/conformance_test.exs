defmodule TamaMCP.ConformanceTest do
  @moduledoc false

  use ExUnit.Case
  import ExUnit.CaptureLog

  alias TamaMCP.{Authorization, Conformance, Error, Protocol, Task}
  alias TamaMCP.Notification.Local
  alias TamaMCP.TestSupport.Subscriptions.Fixtures, as: SubscriptionFixtures
  alias TamaMCP.TestSupport.Tasks.{Fixtures, Store}
  alias TamaMCP.Transport.StreamableHTTP.Plug, as: MCPPlug
  alias TamaMCP.Transport.StreamableHTTP.Runtime

  defmodule Cache do
    @moduledoc false

    @behaviour TamaMCP.Cache

    @impl true
    def fetch(key, loader, options) do
      send(Keyword.fetch!(options, :test), {:protocol_cache_fetch, key})
      {:ok, loader.()}
    end
  end

  defmodule StreamAuthorization do
    @moduledoc false

    use TamaMCP.Authorization

    @impl true
    def authenticate(_conn, options) do
      state = Agent.get(Keyword.fetch!(options, :agent), & &1)

      case state.mode do
        :ok ->
          {:ok,
           %TamaMCP.Authorization.Decision{
             principal: "fixture-principal",
             scopes: ["test.task_required"],
             owner_key: "test-owner",
             expires_at: state.expires_at
           }}

        :deny ->
          {:error, TamaMCP.Error.invalid_request("credential rejected")}
      end
    end

    @impl true
    def register_invalidation(_decision, subscriber, options) do
      reference = make_ref()
      send(Keyword.fetch!(options, :test), {:conformance_registered, subscriber, reference})
      {:ok, reference}
    end
  end

  defmodule OverflowNotification do
    @moduledoc false

    @behaviour TamaMCP.Notification

    @impl true
    def subscribe(_task_ids, subscriber, _capacity, _options) do
      reference = make_ref()
      Process.send_after(subscriber, TamaMCP.Notification.overflow(reference), 5)
      {:ok, reference}
    end

    @impl true
    def take(_subscription, _options), do: {:error, :overflow}

    @impl true
    def unsubscribe(_subscription, _options), do: :ok

    @impl true
    def publish(_task, _options), do: :ok
  end

  test "protocol validators are restored through the host cache adapter" do
    fixture = hd(Conformance.fixtures())

    assert :ok =
             Conformance.validate(
               :discover_request,
               fixture["request"]["body"],
               Cache,
               test: self()
             )

    assert_receive {:protocol_cache_fetch,
                    "tama_mcp:validator:1:Elixir.TamaMCP.Schema.Protocol:discover_request:" <>
                      _fingerprint}
  end

  test "the bundled core fixtures pass against the reference server" do
    runtime =
      MCPPlug.init(
        server: TamaMCP.TestSupport.Server,
        authorization: TamaMCP.TestSupport.Authorization,
        cache: TamaMCP.TestSupport.Cache
      )

    {result, log} =
      with_log(fn ->
        Conformance.run(&request(&1, runtime), TamaMCP.TestSupport.Cache)
      end)

    assert result == :ok
    assert log =~ "TamaMCP unexpected runtime failure: Elixir.RuntimeError"
  end

  test "the bundled task fixtures pass against the durable task reference adapters" do
    {:ok, store} = Store.start_link()

    runtime =
      MCPPlug.init(
        server: TamaMCP.TestSupport.TaskRequiredServer,
        authorization: TamaMCP.TestSupport.Authorization,
        cache: TamaMCP.TestSupport.Cache,
        task_store: Store,
        task_store_options: [agent: store, test: self()],
        task_runner: TamaMCP.TestSupport.Tasks.Runner,
        task_runner_options: [test: self()],
        clock: TamaMCP.TestSupport.Tasks.Clock,
        identifier: TamaMCP.TestSupport.Tasks.Identifier
      )

    assert :ok =
             Conformance.run(
               &task_request(&1, runtime, store),
               TamaMCP.TestSupport.Cache,
               Conformance.tasks_fixtures()
             )

    assert :ok = Conformance.validate_schema_fixtures(TamaMCP.TestSupport.Cache)

    assert length(Conformance.all_fixtures()) ==
             length(Conformance.core_fixtures()) + length(Conformance.tasks_fixtures()) +
               length(Conformance.subscription_fixtures())
  end

  test "the checked task fixtures match the deterministic fixture builder" do
    path = Path.expand("../fixtures/protocol/2026-07-28/tasks.json", __DIR__)
    checked = path |> File.read!() |> Jason.decode!()

    assert checked == Fixtures.document()
  end

  test "the checked subscription fixtures match the deterministic fixture builder" do
    path = Path.expand("../fixtures/protocol/2026-07-28/subscriptions.json", __DIR__)
    checked = path |> File.read!() |> Jason.decode!()

    assert checked == SubscriptionFixtures.document()
  end

  test "subscription fixtures validate ordered SSE and JSON failure contracts" do
    fixtures = Conformance.subscription_fixtures()

    responses =
      Map.new(fixtures, fn fixture ->
        {fixture["request"]["body"]["id"], fixture_response(fixture)}
      end)

    assert :ok =
             Conformance.run(
               &Map.fetch!(responses, &1["body"]["id"]),
               TamaMCP.TestSupport.Cache,
               fixtures
             )
  end

  test "the bundled subscription fixtures pass against the reference adapters" do
    assert :ok =
             Conformance.run(
               &subscription_request/1,
               TamaMCP.TestSupport.Cache,
               Conformance.subscription_fixtures()
             )
  end

  test "subscription verification reports event ordering and close drift" do
    fixture = hd(Conformance.subscription_fixtures())
    expected = fixture_response(fixture)

    drifted = %{
      expected
      | events: Enum.reverse(expected.events),
        close: "abrupt"
    }

    assert {:error, errors} =
             Conformance.verify(fixture, drifted, TamaMCP.TestSupport.Cache)

    assert "unexpected events" in errors
    assert "unexpected close" in errors
  end

  test "task validators are restored through the host cache adapter" do
    fixture = hd(Conformance.tasks_fixtures())

    assert :ok =
             Conformance.validate(
               :create_task_result,
               fixture["expected"]["body"]["result"],
               Cache,
               test: self()
             )

    assert_receive {:protocol_cache_fetch,
                    "tama_mcp:validator:1:Elixir.TamaMCP.Schema.Tasks:create_task_result:" <>
                      _fingerprint}
  end

  test "fixture verification reports response drift without raising" do
    fixture = hd(Conformance.fixtures())

    assert {:error, errors} =
             Conformance.verify(
               fixture,
               %{status: 500, headers: [], body: %{}},
               TamaMCP.TestSupport.Cache
             )

    assert "unexpected status" in errors
    assert "unexpected body" in errors
    assert Enum.any?(errors, &String.starts_with?(&1, "unexpected header"))
    assert "discover_response does not match the pinned schema" in errors
  end

  test "task fixtures validate the JSON-RPC envelope independently of the nested result" do
    fixture = hd(Conformance.tasks_fixtures())
    expected = fixture["expected"]

    response = %{
      status: expected["status"],
      headers: Enum.map(expected["headers"], fn {name, value} -> {name, value} end),
      body: Map.delete(expected["body"], "jsonrpc")
    }

    assert {:error, errors} =
             Conformance.verify(fixture, response, TamaMCP.TestSupport.Cache)

    assert "unexpected body" in errors
    assert "result_response does not match the pinned schema" in errors
    refute Enum.any?(errors, &String.starts_with?(&1, "create_task_result "))
  end

  test "schema fixtures report an inverted expectation without raising" do
    fixture = hd(Conformance.task_schema_fixtures())
    inverted = Map.put(fixture, "valid", false)

    assert {:error, [message]} =
             Conformance.validate_schema_fixtures(
               TamaMCP.TestSupport.Cache,
               [inverted]
             )

    assert message =~ fixture["name"]
    assert message =~ "unexpectedly matches the pinned schema"
  end

  test "bang validation and runner failures provide bounded diagnostics" do
    fixture = hd(Conformance.fixtures())

    assert :ok =
             Conformance.validate!(
               :discover_request,
               fixture["request"]["body"],
               TamaMCP.TestSupport.Cache
             )

    assert_raise TamaMCP.Schema.Error, fn ->
      Conformance.validate!(:discover_response, %{}, TamaMCP.TestSupport.Cache)
    end

    assert {:error, [message | _rest]} =
             Conformance.run(
               fn _request -> %{status: 500, headers: [], body: %{}} end,
               TamaMCP.TestSupport.Cache,
               [fixture]
             )

    assert String.starts_with?(message, "server/discover success:")
  end

  defp request(request, runtime) do
    conn =
      :post
      |> Plug.Test.conn("/", Jason.encode!(request["body"]))
      |> Map.put(:req_headers, Enum.map(request["headers"], &List.to_tuple/1))
      |> MCPPlug.call(runtime)

    %{
      status: conn.status,
      headers: conn.resp_headers,
      body: Jason.decode!(conn.resp_body)
    }
  end

  defp task_request(%{"setup" => setup} = task_request, runtime, store) do
    prepare(setup, runtime, store)
    request(task_request, runtime)
  end

  defp task_request(task_request, runtime, _store), do: request(task_request, runtime)

  defp prepare(%{"task" => wire}, runtime, _store) do
    validation_options =
      Runtime.task_validation_options(runtime, TamaMCP.TestSupport.Tools.TaskRequired)

    store_options = Runtime.effective_task_store_options(runtime, validation_options)
    {:ok, created_at, 0} = DateTime.from_iso8601(wire["createdAt"])

    {:ok, task} =
      Task.new(
        %{
          id: wire["taskId"],
          owner_key: "test-owner",
          method: Protocol.method(:tools_call),
          request_id: "fixture-setup-#{wire["taskId"]}",
          status_message: wire["statusMessage"],
          created_at: created_at,
          last_updated_at: created_at,
          ttl_ms: wire["ttlMs"],
          poll_interval_ms: wire["pollIntervalMs"],
          original_params: %{"name" => "task_required", "arguments" => %{}},
          client_capabilities: task_capabilities()
        },
        validation_options
      )

    assert {:ok, ^task} = Store.create(task, store_options)
    transition_setup(task, wire, store_options, validation_options)
  end

  defp transition_setup(task, %{"status" => "working"}, _store_options, _validation_options),
    do: task

  defp transition_setup(task, wire, store_options, validation_options) do
    {:ok, last_updated_at, 0} = DateTime.from_iso8601(wire["lastUpdatedAt"])
    status = status(wire["status"])

    attributes =
      %{last_updated_at: last_updated_at}
      |> put_payload(:input_requests, wire["inputRequests"])
      |> put_payload(:result, wire["result"])
      |> put_error(wire["error"])

    assert {:ok, transitioned} =
             Store.transition(
               task.owner_key,
               task.id,
               task.revision,
               status,
               attributes,
               Keyword.put(
                 store_options,
                 :tama_mcp,
                 task_validation_options: validation_options
               )
             )

    transitioned
  end

  defp put_payload(attributes, _key, nil), do: attributes
  defp put_payload(attributes, key, value), do: Map.put(attributes, key, value)

  defp put_error(attributes, nil), do: attributes

  defp put_error(attributes, error) do
    Map.put(
      attributes,
      :error,
      %Error{code: error["code"], message: error["message"], data: error["data"]}
    )
  end

  defp status("input_required"), do: :input_required
  defp status("completed"), do: :completed
  defp status("failed"), do: :failed
  defp status("cancelled"), do: :cancelled

  defp task_capabilities do
    %{
      "extensions" => %{Protocol.tasks_extension() => %{}},
      "elicitation" => %{"form" => %{}}
    }
  end

  defp subscription_request(request) do
    setup = request["setup"] || %{}
    {:ok, store} = Store.start_link()
    {:ok, notification} = Local.start_link()

    authorization_state = %{
      mode: :ok,
      expires_at:
        if(setup["authorization"] == "expired",
          do: DateTime.add(DateTime.utc_now(), -1, :second),
          else: nil
        )
    }

    {:ok, authorization} = Agent.start_link(fn -> authorization_state end)

    notification_module =
      if setup["close"] == "overflow", do: OverflowNotification, else: Local

    notification_options =
      if notification_module == OverflowNotification, do: [], else: [server: notification]

    runtime =
      MCPPlug.init(
        server: TamaMCP.TestSupport.TaskRequiredServer,
        authorization: StreamAuthorization,
        authorization_options: [agent: authorization, test: self()],
        cache: TamaMCP.TestSupport.Cache,
        task_store: Store,
        task_store_options: [agent: store],
        task_runner: TamaMCP.TestSupport.Tasks.Runner,
        notification: notification_module,
        notification_options: notification_options,
        limits: [
          stream_keepalive_interval_ms: 1_000,
          stream_authorization_recheck_ms: 1_000,
          stream_max_lifetime_ms: 250
        ]
      )

    tasks = prepare_subscription_tasks(setup["tasks"] || [], runtime)
    reconcile_subscription(setup["reconcile"], tasks, runtime)
    conn = subscription_conn(request)

    if setup == %{} or setup["authorization"] == "expired" do
      conn |> MCPPlug.call(runtime) |> normalize_response()
    else
      stream = Elixir.Task.async(fn -> MCPPlug.call(conn, runtime) end)
      assert_receive {:conformance_registered, stream_pid, invalidation}, 1_000
      control_subscription(setup, tasks, notification, authorization, stream_pid, invalidation)
      stream |> Elixir.Task.await(2_000) |> normalize_response()
    end
  end

  defp prepare_subscription_tasks(wire_tasks, runtime) do
    validation_options =
      Runtime.task_validation_options(runtime, TamaMCP.TestSupport.Tools.TaskRequired)

    store_options = Runtime.effective_task_store_options(runtime, validation_options)

    Map.new(wire_tasks, fn wire ->
      {:ok, created_at, 0} = DateTime.from_iso8601(wire["createdAt"])
      owner_key = Map.get(wire, "ownerKey", "test-owner")

      {:ok, task} =
        Task.new(
          %{
            id: wire["taskId"],
            owner_key: owner_key,
            method: Protocol.method(:tools_call),
            request_id: "fixture-#{wire["taskId"]}",
            status_message: wire["statusMessage"],
            created_at: created_at,
            last_updated_at: created_at,
            ttl_ms: wire["ttlMs"],
            poll_interval_ms: wire["pollIntervalMs"],
            client_capabilities: task_capabilities()
          },
          validation_options
        )

      assert {:ok, ^task} = Store.create(task, store_options)
      task = transition_subscription_task(task, wire, store_options)
      {task.id, task}
    end)
  end

  defp transition_subscription_task(task, %{"status" => "working"}, _store_options), do: task

  defp transition_subscription_task(task, %{"status" => "completed"} = wire, store_options) do
    {:ok, updated_at, 0} = DateTime.from_iso8601(wire["lastUpdatedAt"])

    assert {:ok, completed} =
             Store.transition(
               task.owner_key,
               task.id,
               task.revision,
               :completed,
               %{last_updated_at: updated_at, result: wire["result"]},
               store_options
             )

    completed
  end

  defp reconcile_subscription(nil, _tasks, _runtime), do: :ok

  defp reconcile_subscription(task_id, tasks, runtime) do
    task = Map.fetch!(tasks, task_id)

    assert {:ok, ^task} =
             Store.get(
               task.owner_key,
               task.id,
               Runtime.effective_task_store_options(runtime)
             )
  end

  defp control_subscription(
         setup,
         tasks,
         notification,
         authorization,
         stream_pid,
         invalidation
       ) do
    case setup do
      %{"publish" => task_id} ->
        assert :ok =
                 Local.publish(Map.fetch!(tasks, task_id), server: notification)

      %{"close" => "policy_invalidation"} ->
        Agent.update(authorization, &%{&1 | mode: :deny})
        send(stream_pid, Authorization.invalidation(invalidation))

      %{"close" => "overflow"} ->
        :ok

      _authorized_subset ->
        :ok
    end
  end

  defp subscription_conn(request) do
    :post
    |> Plug.Test.conn("/", Jason.encode!(request["body"]))
    |> Map.put(:req_headers, Enum.map(request["headers"], &List.to_tuple/1))
  end

  defp normalize_response(%Plug.Conn{state: :chunked} = conn) do
    events =
      conn.resp_body
      |> String.split("\n\n", trim: true)
      |> Enum.filter(&String.starts_with?(&1, "data: "))
      |> Enum.map(fn "data: " <> json -> Jason.decode!(json) end)

    close = if match?(%{"result" => _}, List.last(events)), do: "graceful", else: "abrupt"

    %{status: conn.status, headers: conn.resp_headers, events: events, close: close}
  end

  defp normalize_response(conn) do
    %{status: conn.status, headers: conn.resp_headers, body: Jason.decode!(conn.resp_body)}
  end

  defp fixture_response(%{"expected" => %{"events" => events} = expected}) do
    %{
      status: expected["status"],
      headers: Enum.map(expected["headers"], fn {name, value} -> {name, value} end),
      events: events,
      close: expected["close"]
    }
  end

  defp fixture_response(%{"expected" => expected}) do
    %{
      status: expected["status"],
      headers: Enum.map(expected["headers"], fn {name, value} -> {name, value} end),
      body: expected["body"]
    }
  end
end
