defmodule TamaMCP.Conformance.Notification do
  @moduledoc """
  Acceptance harness for the `TamaMCP.Notification` behaviour.

  `check/2` exercises the documented delivery contract through the public
  callbacks only. The harness spawns its own subscriber processes, so the host
  supplies:

    * `:adapter_options` — the keyword list passed to every adapter callback.
    * `:task_factory` — a 0-arity function returning a fresh, valid
      `working` task with a unique ID on every call.
    * `:setup` / `:cleanup` — optional 0-arity functions around the checks.
    * `:strict_revisions` — optional boolean, default `false`. Hosts whose
      adapter ignores published snapshots with an equal or older revision set
      it to `true` to additionally verify stale-revision rejection.

  Every check follows the contract invariants: `ready/1` may be coalesced,
  snapshots may be replaced or coalesced by task ID, delivery order across
  tasks is not guaranteed, and `overflow/1` is terminal. The capacity covers
  both retained ingress and the subscriber queue, and repeated revisions of a
  single task must never overflow it.

  A violated contract rule raises `TamaMCP.Conformance.Failure` naming the
  callback and rule. Host configuration problems raise `ArgumentError`.

  Minimal host example:

      test "my notification adapter conforms" do
        {:ok, server} = TamaMCP.MyNotifications.start_link()

        :ok =
          TamaMCP.Conformance.Notification.check(
            TamaMCP.MyNotifications,
            adapter_options: [server: server],
            task_factory: fn -> fresh_task() end
          )
      end
  """

  alias TamaMCP.Conformance.Failure
  alias TamaMCP.{Error, Notification, Task}

  @wait_ms 5_000
  @poll_ms 10

  @doc """
  Runs the `TamaMCP.Notification` contract suite against `adapter`.

  Returns `:ok` when every check passes and raises
  `TamaMCP.Conformance.Failure` on the first violated rule. See the
  moduledoc for the required and optional options.
  """
  @spec check(module(), keyword()) :: :ok
  def check(adapter, options) when is_atom(adapter) and is_list(options) do
    ctx = context!(adapter, options)
    casualty = spawn(fn -> Process.sleep(:infinity) end)

    try do
      ctx.setup.()

      lifecycle(ctx)
      delivery(ctx)
      same_task_capacity(ctx)
      overflow_terminal(ctx)
      revision_ordering(ctx)
      subscriber_death(ctx, casualty)
      :ok
    after
      ctx.cleanup.()

      for relay <- Process.get(:tama_mcp_conformance_relays, []) do
        Process.exit(relay, :kill)
      end

      Process.exit(casualty, :kill)
    end
  end

  defp context!(adapter, options) do
    factory = required_function!(options, :task_factory)
    sample = factory.()

    case sample do
      %Task{status: :working} ->
        :ok

      _invalid ->
        raise(
          ArgumentError,
          ":task_factory must return a %TamaMCP.Task{} in :working status"
        )
    end

    %{
      adapter: adapter,
      adapter_options: required_keyword!(options, :adapter_options),
      factory: factory,
      strict_revisions: Keyword.get(options, :strict_revisions, false),
      setup: optional_function(options, :setup, fn -> :ok end),
      cleanup: optional_function(options, :cleanup, fn -> :ok end)
    }
  end

  defp required_keyword!(options, key) do
    case Keyword.get(options, key) do
      keyword when is_list(keyword) ->
        keyword

      _invalid ->
        raise(ArgumentError, ":#{key} must be a keyword list")
    end
  end

  defp required_function!(options, key) do
    case Keyword.get(options, key) do
      fun when is_function(fun, 0) ->
        fun

      _invalid ->
        raise(ArgumentError, ":#{key} must be a 0-arity function")
    end
  end

  defp optional_function(options, key, default) do
    case Keyword.get(options, key, default) do
      fun when is_function(fun, 0) ->
        fun

      _invalid ->
        raise(ArgumentError, ":#{key} must be a 0-arity function")
    end
  end

  # Subscriber plumbing ------------------------------------------------------

  defp spawn_relay do
    parent = self()
    relay = spawn(fn -> relay_loop(parent) end)

    Process.put(:tama_mcp_conformance_relays, [
      relay | Process.get(:tama_mcp_conformance_relays, [])
    ])

    relay
  end

  defp relay_loop(parent) do
    receive do
      message ->
        send(parent, {:conformance_subscriber, message})
        relay_loop(parent)
    end
  end

  defp wait_message(matcher?, callback, rule) do
    deadline = System.monotonic_time(:millisecond) + @wait_ms
    wait_message(matcher?, callback, rule, deadline)
  end

  defp wait_message(matcher?, callback, rule, deadline) do
    receive do
      {:conformance_subscriber, message} ->
        cond do
          matcher?.(message) -> :matched
          System.monotonic_time(:millisecond) >= deadline -> fail!(callback, rule)
          true -> wait_message(matcher?, callback, rule, deadline)
        end
    after
      @poll_ms ->
        if System.monotonic_time(:millisecond) >= deadline do
          fail!(callback, rule)
        else
          wait_message(matcher?, callback, rule, deadline)
        end
    end
  end

  defp flush_subscriber do
    receive do
      {:conformance_subscriber, message} ->
        [message | flush_subscriber()]
    after
      5 -> []
    end
  end

  defp ready?(subscription), do: &(&1 == {Notification, subscription, :ready})

  defp overflow?(subscription), do: &(&1 == {Notification, subscription, :overflow})

  # Invocations ---------------------------------------------------------------

  defp call!(callback, fun) do
    fun.()
  rescue
    exception ->
      fail!(callback, "must not raise on contract-valid calls", Exception.message(exception))
  catch
    kind, reason ->
      fail!(callback, "must not raise on contract-valid calls", "#{kind}: #{bounded(reason)}")
  end

  defp subscribe!(ctx, task_ids, subscriber, capacity) do
    case call!("subscribe/4", fn ->
           ctx.adapter.subscribe(task_ids, subscriber, capacity, ctx.adapter_options)
         end) do
      {:ok, subscription} when not is_nil(subscription) ->
        subscription

      {:error, %Error{}} ->
        fail!("subscribe/4", "a valid subscription must succeed")

      other ->
        fail!(
          "subscribe/4",
          "must return {:ok, subscription} or {:error, %TamaMCP.Error{}}",
          bounded(other)
        )
    end
  end

  defp take!(ctx, subscription) do
    case call!("take/2", fn -> ctx.adapter.take(subscription, ctx.adapter_options) end) do
      {:ok, %Task{}} ->
        :ok

      :empty ->
        :empty

      {:error, :closed} ->
        :closed

      {:error, :overflow} ->
        :overflow

      {:error, %Error{}} ->
        :error

      other ->
        fail!(
          "take/2",
          "must return {:ok, task}, :empty, or {:error, :closed | :overflow | %TamaMCP.Error{}}",
          bounded(other)
        )
    end
  end

  defp take_snapshot!(ctx, subscription, task_id, rule) do
    case call!("take/2", fn -> ctx.adapter.take(subscription, ctx.adapter_options) end) do
      {:ok, %Task{} = task} when task.id == task_id ->
        task

      {:ok, %Task{}} ->
        fail!("take/2", rule, "delivered a snapshot for an unsubscribed task ID")

      other ->
        fail!("take/2", rule, bounded(other))
    end
  end

  defp drain!(ctx, subscription, limit) do
    drain_step(ctx, subscription, limit, []) |> Enum.reverse()
  end

  defp drain_step(_ctx, _subscription, 0, delivered), do: delivered

  defp drain_step(ctx, subscription, remaining, delivered) do
    case call!("take/2", fn -> ctx.adapter.take(subscription, ctx.adapter_options) end) do
      {:ok, %Task{} = task} ->
        drain_step(ctx, subscription, remaining - 1, [task | delivered])

      :empty ->
        delivered

      {:error, :overflow} ->
        delivered

      {:error, :closed} ->
        fail!("take/2", "a live subscription must not report :closed before unsubscribe")

      other ->
        fail!("take/2", "must return {:ok, task}, :empty, or a bounded error", bounded(other))
    end
  end

  defp unsubscribe!(ctx, subscription) do
    case call!("unsubscribe/2", fn ->
           ctx.adapter.unsubscribe(subscription, ctx.adapter_options)
         end) do
      :ok ->
        :ok

      {:error, %Error{}} ->
        fail!("unsubscribe/2", "an idempotent unsubscribe must succeed")

      other ->
        fail!(
          "unsubscribe/2",
          "must return :ok or {:error, %TamaMCP.Error{}}",
          bounded(other)
        )
    end
  end

  defp publish!(ctx, task) do
    case call!("publish/2", fn -> ctx.adapter.publish(task, ctx.adapter_options) end) do
      :ok ->
        :ok

      {:error, %Error{}} ->
        fail!("publish/2", "publishing a committed snapshot to a healthy adapter must succeed")

      other ->
        fail!(
          "publish/2",
          "must return :ok or {:error, %TamaMCP.Error{}}",
          bounded(other)
        )
    end
  end

  # Checks --------------------------------------------------------------------

  defp lifecycle(ctx) do
    task = ctx.factory.()
    subscriber = spawn_relay()
    subscription = subscribe!(ctx, [task.id], subscriber, 4)

    unless take!(ctx, subscription) == :empty,
      do: fail!("take/2", "an empty subscription must return :empty")

    unsubscribe!(ctx, subscription)

    unless take!(ctx, subscription) in [:closed, :overflow],
      do: fail!("take/2", "a taken-after-unsubscribe result must report :closed")

    :ok
  end

  defp delivery(ctx) do
    task = ctx.factory.()
    snapshot = advance(task, 10)
    subscription = subscribe!(ctx, [task.id], spawn_relay(), 4)

    try do
      publish!(ctx, snapshot)

      wait_message(
        ready?(subscription),
        "publish/2",
        "must send a ready hint when a snapshot is queued"
      )

      delivered =
        take_snapshot!(
          ctx,
          subscription,
          task.id,
          "a queued snapshot must be deliverable through take/2"
        )

      unless delivered.revision == snapshot.revision and
               delivered.status == snapshot.status and
               delivered.status_message == snapshot.status_message,
             do:
               fail!(
                 "take/2",
                 "must return the complete committed snapshot",
                 "expected revision #{snapshot.revision}, got #{delivered.revision}"
               )

      unless take!(ctx, subscription) in [:empty, :closed, :overflow],
        do: fail!("take/2", "a drained subscription must eventually return :empty")

      unsubscribe!(ctx, subscription)
    after
      flush_subscriber()
    end

    :ok
  end

  defp same_task_capacity(ctx) do
    task = ctx.factory.()
    capacity = 2
    subscription = subscribe!(ctx, [task.id], spawn_relay(), capacity)

    try do
      Enum.each(chain(task, 6), fn snapshot ->
        publish!(ctx, snapshot)
        take_available!(ctx, subscription, task.id)
        drain!(ctx, subscription, 4)
      end)

      if Enum.any?(flush_subscriber(), overflow?(subscription)) do
        fail!(
          "publish/2",
          "repeated revisions of a single task must never overflow the capacity while the subscriber keeps up"
        )
      end

      unsubscribe!(ctx, subscription)
    after
      flush_subscriber()
    end
  end

  defp take_available!(ctx, subscription, task_id, attempt \\ 0) do
    result = call!("take/2", fn -> ctx.adapter.take(subscription, ctx.adapter_options) end)

    case result do
      {:ok, %Task{} = task} when task.id == task_id ->
        task

      :empty ->
        if attempt >= 50 do
          fail!("take/2", "a queued snapshot must be deliverable through take/2")
        else
          Process.sleep(@poll_ms)
          take_available!(ctx, subscription, task_id, attempt + 1)
        end

      other ->
        fail!("take/2", "must return {:ok, task} for the published task", bounded(other))
    end
  end

  defp overflow_terminal(ctx) do
    primary = ctx.factory.()
    first = ctx.factory.()
    second = ctx.factory.()
    capacity = 2
    subscription = subscribe!(ctx, [primary.id, first.id, second.id], spawn_relay(), capacity)

    try do
      [a, b, c] =
        [advance(primary, 10), advance(first, 10), advance(second, 10)]

      publish!(ctx, a)
      publish!(ctx, b)
      publish!(ctx, c)

      wait_message(
        overflow?(subscription),
        "publish/2",
        "a capacity overflow must send overflow/1"
      )

      Process.sleep(50)
      publish!(ctx, b)
      Process.sleep(50)

      leftovers = flush_subscriber()

      if Enum.any?(leftovers, overflow?(subscription)),
        do:
          fail!(
            "publish/2",
            "overflow must be a single terminal condition per subscription"
          )

      unless take!(ctx, subscription) in [:overflow, :closed],
        do:
          fail!(
            "take/2",
            "a take after overflow must report :overflow or :closed"
          )

      unsubscribe!(ctx, subscription)
    after
      flush_subscriber()
    end
  end

  defp revision_ordering(ctx) do
    task = ctx.factory.()
    newer = advance(advance(task, 10), 20)
    older = advance(task, 10)
    subscription = subscribe!(ctx, [task.id], spawn_relay(), 4)

    try do
      publish!(ctx, older)
      Process.sleep(30)
      publish!(ctx, newer)
      Process.sleep(30)

      revisions =
        drain!(ctx, subscription, 8)
        |> Enum.map(& &1.revision)

      unless sorted_non_decreasing?(revisions),
        do:
          fail!(
            "take/2",
            "delivered snapshots for one task must not regress in revision",
            bounded(revisions)
          )

      unsubscribe!(ctx, subscription)
    after
      flush_subscriber()
    end

    if ctx.strict_revisions do
      strict_stale(ctx)
    end

    :ok
  end

  defp strict_stale(ctx) do
    task = ctx.factory.()
    newer = advance(advance(task, 10), 20)
    subscription = subscribe!(ctx, [task.id], spawn_relay(), 4)
    older = advance(task, 10)

    try do
      publish!(ctx, newer)
      Process.sleep(30)
      publish!(ctx, older)
      Process.sleep(30)

      revisions = drain!(ctx, subscription, 8) |> Enum.map(& &1.revision)

      if revisions == [],
        do:
          fail!(
            "publish/2",
            "a newer published snapshot must still be delivered",
            bounded(revisions)
          )

      unless Enum.all?(revisions, &(&1 >= newer.revision)),
        do:
          fail!(
            "publish/2",
            "a published snapshot with an equal or older revision must be ignored",
            bounded(revisions)
          )
    after
      unsubscribe!(ctx, subscription)
      flush_subscriber()
    end
  end

  defp subscriber_death(ctx, casualty) do
    task = ctx.factory.()
    subscription = subscribe!(ctx, [task.id], casualty, 2)

    publish!(ctx, advance(task, 10))
    Process.sleep(50)
    Process.exit(casualty, :kill)
    Process.sleep(50)

    unsubscribe!(ctx, subscription)

    unless take!(ctx, subscription) in [:closed, :overflow],
      do:
        fail!(
          "take/2",
          "a take after the subscriber died must report :closed or :overflow"
        )

    publish!(ctx, advance(task, 20))
    :ok
  end

  # Fixtures ------------------------------------------------------------------

  defp chain(task, steps) do
    {_last, list} =
      Enum.reduce(1..steps, {task, []}, fn _step, {current, built} ->
        {advance(current, 1), [current | built]}
      end)

    Enum.reverse(list)
  end

  defp advance(task, milliseconds) do
    {:ok, next} =
      Task.transition(
        task,
        :working,
        %{
          status_message: "Conformance step #{task.revision + 1}",
          last_updated_at: DateTime.add(task.last_updated_at, milliseconds, :millisecond)
        },
        []
      )

    next
  end

  defp sorted_non_decreasing?([]), do: true
  defp sorted_non_decreasing?([_only]), do: true

  defp sorted_non_decreasing?([head | tail]) do
    [next | rest] = tail
    head <= next and sorted_non_decreasing?([next | rest])
  end

  @spec fail!(String.t(), String.t()) :: no_return
  @spec fail!(String.t(), String.t(), term()) :: no_return

  defp fail!(callback, rule, details \\ nil) do
    raise Failure, callback: callback, rule: rule, details: details
  end

  defp bounded(term) when is_binary(term), do: term
  defp bounded(term), do: inspect(term, limit: 40)
end
