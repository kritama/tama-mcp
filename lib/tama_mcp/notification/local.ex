defmodule TamaMCP.Notification.Local do
  @moduledoc """
  Process-local reference implementation of `TamaMCP.Notification`.

  The adapter coalesces ingress by task ID and subscription in ETS, wakes its
  GenServer at most once while ingress is pending, and keeps each subscription
  queue inside the GenServer as a `TamaMCP.Notification.Buffer`. A newer
  revision of a pending task replaces the queued snapshot without consuming
  additional capacity, and a published revision that is equal to or older than
  the pending snapshot is ignored. The configured capacity counts distinct
  pending task IDs and covers both retained ingress and the queue. When that
  capacity would be exceeded, the adapter drops both, stops routing
  publications to the subscription, and signals overflow. This bounds ingress,
  adapter state, and the subscriber mailbox without making publishers wait on
  stream I/O.

  Start the adapter under the host supervision tree and pass its pid or name as
  `:server` in `:notification_options`.
  """

  use GenServer

  @behaviour TamaMCP.Notification

  alias TamaMCP.{Error, Notification, Task}
  alias TamaMCP.Notification.Buffer

  @ingress_key {__MODULE__, :ingress}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options \\ []) do
    {genserver_options, _adapter_options} = Keyword.split(options, [:name])
    GenServer.start_link(__MODULE__, %{}, genserver_options)
  end

  @impl true
  def subscribe(task_ids, subscriber, capacity, options)
      when is_list(task_ids) and is_pid(subscriber) and is_integer(capacity) and capacity > 0 do
    call(options, {:subscribe, Enum.uniq(task_ids), subscriber, capacity})
  end

  def subscribe(_task_ids, _subscriber, _capacity, _options),
    do: {:error, Error.internal()}

  @impl true
  def take(subscription, options) when is_reference(subscription) do
    call(options, {:take, subscription})
  end

  def take(_subscription, _options), do: {:error, Error.internal()}

  @impl true
  def unsubscribe(subscription, options) when is_reference(subscription) do
    call(options, {:unsubscribe, subscription})
  end

  def unsubscribe(_subscription, _options), do: {:error, Error.internal()}

  @impl true
  def publish(%Task{} = task, options) do
    case ingress(options) do
      {:ok, server, table} -> publish_ingress(server, table, task)
      :error -> {:error, Error.internal()}
    end
  rescue
    _exception -> {:error, Error.internal()}
  catch
    _kind, _reason -> {:error, Error.internal()}
  end

  def publish(_task, _options), do: {:error, Error.internal()}

  @impl true
  def init(_options) do
    ingress =
      :ets.new(__MODULE__, [
        :set,
        :public,
        read_concurrency: true,
        write_concurrency: true
      ])

    Process.put(@ingress_key, ingress)

    {:ok, %{subscriptions: %{}, monitors: %{}, ingress: ingress}}
  end

  @impl true
  def handle_call({:subscribe, task_ids, subscriber, capacity}, _from, state) do
    subscription = make_ref()
    monitor = Process.monitor(subscriber)

    entry = %{
      subscriber: subscriber,
      monitor: monitor,
      task_ids: MapSet.new(task_ids),
      buffer: Buffer.new(capacity)
    }

    state =
      state
      |> put_in([:subscriptions, subscription], entry)
      |> put_in([:monitors, monitor], subscription)
      |> index(subscription, entry.task_ids, capacity)

    {:reply, {:ok, subscription}, state}
  end

  def handle_call({:take, subscription}, _from, state) do
    case Map.get(state.subscriptions, subscription) do
      nil ->
        {:reply, {:error, :closed}, state}

      entry ->
        take_active(subscription, entry, state)
    end
  end

  def handle_call({:unsubscribe, subscription}, _from, state) do
    {:reply, :ok, remove(state, subscription)}
  end

  @impl true
  def handle_info({__MODULE__, ingress, :ready}, %{ingress: ingress} = state) do
    :ets.delete(ingress, :wake)
    {:noreply, drain_ingress(state)}
  end

  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    case Map.get(state.monitors, monitor) do
      nil -> {:noreply, state}
      subscription -> {:noreply, remove(state, subscription, false)}
    end
  end

  defp take_entry(subscription, entry, state) do
    case Buffer.take(entry.buffer) do
      {{:ok, task}, buffer} ->
        release_buffered(state.ingress, subscription)

        if Buffer.size(buffer) > 0,
          do: send(entry.subscriber, Notification.ready(subscription))

        {:reply, {:ok, task}, store_entry(state, subscription, %{entry | buffer: buffer})}

      {:empty, _buffer} ->
        {:reply, :empty, state}

      # The entry only reaches this branch after its buffer already entered
      # the terminal overflow state, so no overflow message is re-sent.
      {:overflow, _buffer} ->
        {:reply, {:error, :overflow}, state}

      {:closed, _buffer} ->
        {:reply, {:error, :closed}, state}
    end
  end

  defp take_active(subscription, entry, state) do
    case subscription_status(state.ingress, subscription) do
      {:overflow, _capacity} ->
        state = overflow(subscription, entry, state)
        {:reply, {:error, :overflow}, state}

      _active_or_closing ->
        take_entry(subscription, entry, state)
    end
  end

  defp enqueue(subscription, task, state) do
    case Map.get(state.subscriptions, subscription) do
      nil -> state
      entry -> retain_for_entry(subscription, entry, task, state)
    end
  end

  defp retain_for_entry(subscription, entry, task, state) do
    case Buffer.retain(entry.buffer, task) do
      {:retained, buffer} ->
        if Buffer.size(buffer) == 1,
          do: send(entry.subscriber, Notification.ready(subscription))

        store_entry(state, subscription, %{entry | buffer: buffer})

      {:replaced, buffer} ->
        store_entry(state, subscription, %{entry | buffer: buffer})

      {:ignored, _buffer} ->
        state

      {:overflow, buffer} ->
        overflow(subscription, %{entry | buffer: buffer}, state)
    end
  end

  defp store_entry(state, subscription, entry) do
    put_in(state, [:subscriptions, subscription], entry)
  end

  defp drain_ingress(state) do
    state =
      state.ingress
      |> :ets.select([{{{:overflow, :"$1"}, :_}, [], [:"$1"]}])
      |> Enum.reduce(state, &drain_overflow(&2, &1))

    state.ingress
    |> :ets.select([
      {{{:task, :"$1", :"$2"}, :ready, :_}, [], [{{:"$1", :"$2"}}]}
    ])
    |> Enum.reduce(state, fn {subscription, task_id}, acc ->
      drain_task(acc, subscription, task_id)
    end)
  end

  defp drain_overflow(state, subscription) do
    case :ets.take(state.ingress, {:overflow, subscription}) do
      [{{:overflow, ^subscription}, true}] ->
        clear_overflow_flag(state, subscription)

      _missing_or_invalid ->
        state
    end
  end

  defp clear_overflow_flag(state, subscription) do
    case Map.get(state.subscriptions, subscription) do
      %{buffer: buffer} = entry ->
        if Buffer.overflowed?(buffer) do
          :ets.delete(state.ingress, {:buffered, subscription})
          state
        else
          overflow(subscription, entry, state)
        end

      _closed_or_overflowed ->
        :ets.delete(state.ingress, {:buffered, subscription})
        state
    end
  end

  defp drain_task(state, subscription, task_id) do
    case :ets.take(state.ingress, {:task, subscription, task_id}) do
      [{{:task, ^subscription, ^task_id}, :ready, %Task{} = task}] ->
        case subscription_status(state.ingress, subscription) do
          {:active, _capacity} -> enqueue(subscription, task, state)
          _closed_or_overflowed -> state
        end

      _missing_or_invalid ->
        state
    end
  end

  defp index(state, subscription, task_ids, capacity) do
    :ets.insert(state.ingress, [
      {{:subscription, subscription}, :active, capacity},
      {{:buffered, subscription}, 0}
    ])

    Enum.each(task_ids, fn task_id ->
      :ets.insert(state.ingress, {{:route, task_id, subscription}, true})
    end)

    state
  end

  defp unindex(state, subscription, task_ids) do
    :ets.insert(state.ingress, {{:subscription, subscription}, :closed, 0})

    Enum.each(task_ids, fn task_id ->
      :ets.delete(state.ingress, {:route, task_id, subscription})
      :ets.delete(state.ingress, {:task, subscription, task_id})
    end)

    :ets.delete(state.ingress, {:overflow, subscription})
    :ets.delete(state.ingress, {:buffered, subscription})
    :ets.delete(state.ingress, {:subscription, subscription})

    state
  end

  defp remove(state, subscription, demonitor? \\ true) do
    case Map.pop(state.subscriptions, subscription) do
      {nil, _subscriptions} ->
        state

      {entry, subscriptions} ->
        if demonitor?, do: Process.demonitor(entry.monitor, [:flush])

        %{
          state
          | subscriptions: subscriptions,
            monitors: Map.delete(state.monitors, entry.monitor)
        }
        |> unindex(subscription, entry.task_ids)
    end
  end

  defp overflow(subscription, entry, state) do
    send(entry.subscriber, Notification.overflow(subscription))

    state
    |> unindex(subscription, entry.task_ids)
    |> put_in([:subscriptions, subscription], %{
      entry
      | buffer: Buffer.mark_overflow(entry.buffer)
    })
  end

  defp call(options, message) do
    case server(options) do
      nil -> {:error, Error.internal()}
      server -> GenServer.call(server, message)
    end
  catch
    :exit, _reason -> {:error, Error.internal()}
  end

  defp ingress(options) do
    with server when not is_nil(server) <- server(options),
         pid when is_pid(pid) <- GenServer.whereis(server),
         {:dictionary, dictionary} <- Process.info(pid, :dictionary),
         {@ingress_key, table} <- List.keyfind(dictionary, @ingress_key, 0) do
      {:ok, pid, table}
    else
      _missing -> :error
    end
  end

  defp publish_ingress(server, table, task) do
    wake? =
      table
      |> subscriptions_for(task.id)
      |> Enum.reduce(false, fn subscription, pending? ->
        retain_for_subscription(table, subscription, task) or pending?
      end)

    if wake? and :ets.insert_new(table, {:wake, true}),
      do: send(server, {__MODULE__, table, :ready})

    :ok
  end

  defp subscriptions_for(table, task_id) do
    :ets.select(table, [{{{:route, task_id, :"$1"}, :_}, [], [:"$1"]}])
  end

  defp retain_for_subscription(table, subscription, task) do
    case subscription_status(table, subscription) do
      {:active, capacity} -> retain_active(table, subscription, capacity, task)
      _closed_or_overflowed -> false
    end
  end

  defp retain_active(table, subscription, capacity, task) do
    key = {:task, subscription, task.id}

    if :ets.insert_new(table, {key, :reserving, task}) do
      buffered =
        :ets.update_counter(
          table,
          {:buffered, subscription},
          {2, 1},
          {{:buffered, subscription}, 0}
        )

      retain_reserved(table, subscription, capacity, key, buffered)
    else
      update_retained(table, subscription, capacity, key, task)
    end
  end

  defp retain_reserved(table, subscription, capacity, key, buffered) do
    case subscription_status(table, subscription) do
      {:active, ^capacity} when buffered <= capacity ->
        publish_reserved(table, subscription, key)

      {:active, ^capacity} ->
        overflow_ingress(table, subscription, capacity)

      _closed_or_overflowed ->
        discard_inactive(table, subscription, key)
    end
  end

  defp update_retained(table, subscription, capacity, key, task) do
    ready = {key, :ready, :_}
    updated = {:const, {key, :ready, task}}

    case :ets.select_replace(table, [{ready, [], [updated]}]) do
      1 ->
        retain_ready(table, subscription, capacity, key)

      0 ->
        update_reserving(table, subscription, key, task)
    end
  end

  defp update_reserving(table, subscription, key, task) do
    reserving = {key, :reserving, :_}
    updated = {:const, {key, :reserving, task}}

    case :ets.select_replace(table, [{reserving, [], [updated]}]) do
      1 ->
        false

      0 ->
        retain_for_subscription(table, subscription, task)
    end
  end

  defp retain_ready(table, subscription, capacity, key) do
    case subscription_status(table, subscription) do
      {:active, ^capacity} -> true
      _closed_or_overflowed -> discard_inactive(table, subscription, key)
    end
  end

  defp publish_reserved(table, subscription, key) do
    case :ets.update_element(table, key, {2, :ready}) do
      true ->
        true

      false ->
        release_buffered(table, subscription)
        false
    end
  end

  defp overflow_ingress(table, subscription, capacity) do
    key = {:subscription, subscription}
    active = {key, :active, capacity}
    overflowed = {key, :overflow, capacity}

    case :ets.select_replace(table, [{active, [], [{:const, overflowed}]}]) do
      1 ->
        :ets.match_delete(table, {{:task, subscription, :_}, :_, :_})
        :ets.insert(table, {{:buffered, subscription}, 0})
        :ets.insert(table, {{:overflow, subscription}, true})
        true

      0 ->
        false
    end
  end

  defp subscription_status(table, subscription) do
    case :ets.lookup(table, {:subscription, subscription}) do
      [{{:subscription, ^subscription}, status, capacity}] -> {status, capacity}
      _missing_or_invalid -> :closed
    end
  end

  defp discard_inactive(table, subscription, key) do
    :ets.delete(table, key)
    :ets.delete(table, {:buffered, subscription})
    false
  end

  defp release_buffered(table, subscription) do
    :ets.update_counter(table, {:buffered, subscription}, {2, -1, 0, 0})
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp server(options), do: Keyword.get(options, :server)
end
