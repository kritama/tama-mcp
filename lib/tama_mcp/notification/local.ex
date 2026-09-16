defmodule TamaMCP.Notification.Local do
  @moduledoc """
  Process-local reference implementation of `TamaMCP.Notification`.

  The adapter keeps each subscription queue inside one GenServer and sends at
  most one wake-up message while data is pending. When the configured capacity
  would be exceeded, it drops the queue, stops routing publications to that
  subscription, and signals overflow. This bounds both adapter state and the
  subscriber mailbox.

  Start the adapter under the host supervision tree and pass its pid or name as
  `:server` in `:notification_options`.
  """

  use GenServer

  @behaviour TamaMCP.Notification

  alias TamaMCP.{Error, Notification, Task}

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
    case server(options) do
      nil -> {:error, Error.internal()}
      server -> GenServer.cast(server, {:publish, task})
    end
  end

  def publish(_task, _options), do: {:error, Error.internal()}

  @impl true
  def init(_options) do
    {:ok, %{subscriptions: %{}, task_subscriptions: %{}, monitors: %{}}}
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
  def handle_cast({:publish, %Task{} = task}, state) do
    subscriptions = Map.get(state.task_subscriptions, task.id, MapSet.new())
    {:noreply, Enum.reduce(subscriptions, state, &enqueue(&1, task, &2))}
  end

  @impl true
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

  defp index(state, subscription, task_ids) do
    Enum.reduce(task_ids, state, fn task_id, acc ->
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

  defp server(options), do: Keyword.get(options, :server)
end
