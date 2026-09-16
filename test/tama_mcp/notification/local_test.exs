defmodule TamaMCP.Notification.LocalTest do
  @moduledoc false

  use ExUnit.Case

  alias TamaMCP.{Notification, Task}
  alias TamaMCP.Notification.Local

  defmodule PublishingNotification do
    @moduledoc false

    @behaviour TamaMCP.Notification

    @impl true
    def subscribe(_task_ids, _subscriber, _capacity, _options), do: {:ok, make_ref()}

    @impl true
    def take(_subscription, _options), do: :empty

    @impl true
    def unsubscribe(_subscription, _options), do: :ok

    @impl true
    def publish(task, options) do
      case Keyword.get(options, :mode, :ok) do
        :ok ->
          send(Keyword.fetch!(options, :test), {:published, task})
          :ok

        :raise ->
          raise "notification secret"

        :invalid ->
          {:adapter, "notification secret"}
      end
    end
  end

  setup do
    notification = start_supervised!(Local)
    {:ok, notification: notification, options: [server: notification]}
  end

  test "delivers subscribed task snapshots through a bounded pull queue", %{options: options} do
    first = task("task-1", 0)
    second = task("task-1", 1)
    unrelated = task("task-2", 0)

    assert {:ok, subscription} = Local.subscribe([first.id, first.id], self(), 2, options)
    assert :ok = Local.publish(unrelated, options)
    refute_receive {Notification, ^subscription, :ready}

    assert :ok = Local.publish(first, options)
    assert_receive {Notification, ^subscription, :ready}
    assert {:ok, ^first} = Local.take(subscription, options)

    assert :ok = Local.publish(second, options)
    assert_receive {Notification, ^subscription, :ready}
    assert {:ok, ^second} = Local.take(subscription, options)
    assert :empty = Local.take(subscription, options)
  end

  test "overflows before queue or subscriber mailbox growth becomes unbounded", %{
    options: options
  } do
    first = task("task-1", 0)
    second = task("task-2", 0)

    assert {:ok, subscription} = Local.subscribe([first.id, second.id], self(), 1, options)
    assert :ok = Local.publish(first, options)
    assert :ok = Local.publish(second, options)

    assert_receive {Notification, ^subscription, :ready}
    assert_receive {Notification, ^subscription, :overflow}
    assert {:error, :overflow} = Local.take(subscription, options)
    assert :ok = Local.unsubscribe(subscription, options)
    assert {:error, :closed} = Local.take(subscription, options)
  end

  test "coalesces a publication burst before it reaches the adapter mailbox", %{
    notification: notification,
    options: options
  } do
    assert {:ok, subscription} = Local.subscribe(["task-1"], self(), 2, options)
    latest = task("task-1", 500)
    :ok = :sys.suspend(notification)

    try do
      for revision <- 1..500 do
        assert :ok = Local.publish(task("task-1", revision), options)
      end

      assert {:message_queue_len, length} = Process.info(notification, :message_queue_len)
      assert length <= 1
    after
      :ok = :sys.resume(notification)
    end

    assert_receive {Notification, ^subscription, :ready}
    assert {:ok, ^latest} = Local.take(subscription, options)
    assert :empty = Local.take(subscription, options)
  end

  test "unsubscribe is idempotent and dead subscribers are removed", %{options: options} do
    task = task("task-1", 0)

    assert {:ok, subscription} = Local.subscribe([task.id], self(), 1, options)
    assert :ok = Local.unsubscribe(subscription, options)
    assert :ok = Local.unsubscribe(subscription, options)

    subscriber =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    assert {:ok, dead_subscription} = Local.subscribe([task.id], subscriber, 1, options)
    Process.exit(subscriber, :kill)

    assert eventually(fn -> Local.take(dead_subscription, options) == {:error, :closed} end)
  end

  test "rejects malformed calls with bounded package errors", %{options: options} do
    assert {:error, %TamaMCP.Error{}} = Local.subscribe(:invalid, self(), 1, options)
    assert {:error, %TamaMCP.Error{}} = Local.take(:invalid, options)
    assert {:error, %TamaMCP.Error{}} = Local.unsubscribe(:invalid, options)
    assert {:error, %TamaMCP.Error{}} = Local.publish(%{}, options)
    assert {:error, %TamaMCP.Error{}} = Local.publish(task("task-1", 0), [])
  end

  test "publish_committed contains failures and emits classified telemetry" do
    event = [:tama_mcp, :test, :notification, :publish]
    handler = "notification-publish-#{System.unique_integer([:positive])}"
    :ok = :telemetry.attach(handler, event, &__MODULE__.handle/4, self())
    on_exit(fn -> :telemetry.detach(handler) end)
    task = task("task-1", 0)

    options = [
      tama_mcp: [
        notification: PublishingNotification,
        notification_options: [test: self()],
        telemetry_prefix: [:tama_mcp, :test],
        server: "test"
      ]
    ]

    assert :ok = Notification.publish_committed(task, options)
    assert_receive {:published, ^task}
    assert_receive {:event, ^event, %{status: :ok, reason: :published}}

    for mode <- [:raise, :invalid] do
      failed = put_in(options, [:tama_mcp, :notification_options], test: self(), mode: mode)

      assert {:error, %TamaMCP.Error{message: "Internal error"}} =
               Notification.publish_committed(task, failed)

      assert_receive {:event, ^event, %{status: :error, reason: :publish_failed}}
    end

    assert :ok = Notification.publish_committed(task, tama_mcp: [notification: nil])
  end

  @doc false
  def handle(name, _measurements, metadata, test), do: send(test, {:event, name, metadata})

  defp task(id, revision) do
    {:ok, task} =
      Task.new(%{
        id: id,
        owner_key: "owner",
        method: "tools/call",
        request_id: "request-1",
        client_capabilities: %{},
        created_at: ~U[2026-09-15 12:00:00Z],
        last_updated_at: DateTime.add(~U[2026-09-15 12:00:00Z], revision, :microsecond),
        ttl_ms: 1_000,
        revision: revision
      })

    task
  end

  defp eventually(fun, attempts \\ 20)

  defp eventually(fun, attempts) do
    cond do
      fun.() ->
        true

      attempts == 0 ->
        false

      true ->
        Process.sleep(5)
        eventually(fun, attempts - 1)
    end
  end
end
