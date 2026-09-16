defmodule TamaMCP.Notification.Local do
  @moduledoc """
  Process-local reference implementation of `TamaMCP.Notification`.

  The adapter coalesces ingress by subscribed task ID in ETS, wakes its
  GenServer at most once while ingress is pending, and keeps each subscription
  queue inside the GenServer. When the configured capacity would be exceeded,
  it drops the queue, stops routing publications to that subscription, and
  signals overflow. This bounds ingress, adapter state, and the subscriber
  mailbox without making publishers wait on stream I/O.

  Start the adapter under the host supervision tree and pass its pid or name as
  `:server` in `:notification_options`.
  """

  use GenServer

  @behaviour TamaMCP.Notification

  alias TamaMCP.{Error, Notification, Task}

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

    {:ok, %{subscriptions: %{}, task_subscriptions: %{}, monitors: %{}, ingress: ingress}}
  end

  @impl true
  def handle_call({:subscribe, task_ids, subscriber, capacity}, _from, state) do
    subscription = make_ref()
    monitor = Process.monitor(subscriber)

    entry = %{
      subscriber: subscriber,
      monitor: monitor,
      task_ids: MapSet.new(task_ids),
      capacity: capacity,
      queue: :queue.new(),
      size: 0,
      overflow: false
    }

    state =
      state
      |> put_in([:subscriptions, subscription], entry)
      |> put_in([:monitors, monitor], subscription)
      |> index(subscription, entry.task_ids)

    {:reply, {:ok, subscription}, state}
  end

  def handle_call({:take, subscription}, _from, state) do
    case Map.get(state.subscriptions, subscription) do
      nil ->
        {:reply, {:error, :closed}, state}

      %{overflow: true} ->
        {:reply, {:error, :overflow}, state}

      entry ->
        take_entry(subscription, entry, state)
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
    case :queue.out(entry.queue) do
      {{:value, task}, queue} ->
        updated = %{entry | queue: queue, size: entry.size - 1}

        if updated.size > 0,
          do: send(updated.subscriber, Notification.ready(subscription))

        {:reply, {:ok, task}, put_in(state, [:subscriptions, subscription], updated)}

      {:empty, _queue} ->
        {:reply, :empty, state}
    end
  end

  defp enqueue(subscription, task, state) do
    case Map.get(state.subscriptions, subscription) do
      %{overflow: false, size: size, capacity: capacity} = entry when size < capacity ->
        if size == 0, do: send(entry.subscriber, Notification.ready(subscription))

        updated = %{entry | queue: :queue.in(task, entry.queue), size: size + 1}
        put_in(state, [:subscriptions, subscription], updated)

      %{overflow: false} = entry ->
        send(entry.subscriber, Notification.overflow(subscription))

        state
        |> unindex(subscription, entry.task_ids)
        |> put_in([:subscriptions, subscription], %{
          entry
          | queue: :queue.new(),
            size: 0,
            overflow: true
        })

      _closed_or_overflowed ->
        state
    end
  end

  defp drain_ingress(state) do
    state.ingress
    |> :ets.select([{{{:task, :"$1"}, :_}, [], [:"$1"]}])
    |> Enum.reduce(state, &drain_task(&2, &1))
  end

  defp drain_task(state, task_id) do
    case :ets.take(state.ingress, {:task, task_id}) do
      [{{:task, ^task_id}, %Task{} = task}] ->
        subscriptions = Map.get(state.task_subscriptions, task_id, MapSet.new())
        Enum.reduce(subscriptions, state, &enqueue(&1, task, &2))

      _missing_or_invalid ->
        state
    end
  end

  defp index(state, subscription, task_ids) do
    Enum.reduce(task_ids, state, fn task_id, acc ->
      :ets.update_counter(
        acc.ingress,
        {:subscribed, task_id},
        {2, 1},
        {{:subscribed, task_id}, 0}
      )

      update_in(acc, [:task_subscriptions, task_id], fn subscriptions ->
        MapSet.put(subscriptions || MapSet.new(), subscription)
      end)
    end)
  end

  defp unindex(state, subscription, task_ids) do
    Enum.reduce(task_ids, state, &unindex_task(&2, &1, subscription))
  end

  defp unindex_task(state, task_id, subscription) do
    subscriptions =
      state.task_subscriptions
      |> Map.get(task_id, MapSet.new())
      |> MapSet.delete(subscription)

    if MapSet.size(subscriptions) == 0 do
      :ets.delete(state.ingress, {:subscribed, task_id})
      :ets.delete(state.ingress, {:task, task_id})
    else
      :ets.update_counter(state.ingress, {:subscribed, task_id}, {2, -1})
    end

    %{state | task_subscriptions: put_or_delete(state.task_subscriptions, task_id, subscriptions)}
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

  defp put_or_delete(index, task_id, subscriptions) do
    if MapSet.size(subscriptions) == 0,
      do: Map.delete(index, task_id),
      else: Map.put(index, task_id, subscriptions)
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
    if :ets.member(table, {:subscribed, task.id}) do
      :ets.insert(table, {{:task, task.id}, task})

      if :ets.insert_new(table, {:wake, true}),
        do: send(server, {__MODULE__, table, :ready})
    end

    :ok
  end

  defp server(options), do: Keyword.get(options, :server)
end
