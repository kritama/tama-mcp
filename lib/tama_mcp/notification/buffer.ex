defmodule TamaMCP.Notification.Buffer do
  @moduledoc """
  Reusable, revision-aware, bounded notification buffer.

  This is the package-owned state machine behind subscription capacity. It
  retains complete `%TamaMCP.Task{}` snapshots for distinct task IDs,
  coalesces revisions, and enforces a positive capacity without performing I/O
  or blocking publishers. Host adapters that own their routing (for example a
  clustered adapter routed through Phoenix.PubSub) delegate the
  revision, ordering, and capacity decisions to this primitive while owning
  subscription processes, topics, and delivery.

  Semantics:

    * A newer revision of a task with a pending snapshot replaces that
      snapshot in place. It keeps its queue position, does not duplicate the
      task, and does not consume additional capacity.
    * A published revision that is equal to or older than the pending
      snapshot for the same task is ignored.
    * Capacity counts distinct pending task IDs, not publications.
    * FIFO order between distinct task IDs is deterministic.
    * Publishing a distinct task ID while the buffer is at capacity moves the
      buffer into a single terminal overflow state. The documented drop
      policy discards every retained snapshot; the buffer keeps no content
      after overflow and ignores further publications.
    * `close/1` is a separate terminal state for torn-down subscriptions.

  Snapshots remain complete package values. The transport may still re-fetch
  durable current state through `tasks/get` before delivery; the buffer is a
  wake-up and ordering aid, not the source of truth.
  """

  alias TamaMCP.Task

  @type t :: %__MODULE__{}

  @type retain_status :: :retained | :replaced | :ignored | :overflow

  @type take_result :: {:ok, Task.t()} | :empty | :overflow | :closed

  @enforce_keys [:capacity]
  defstruct capacity: nil,
            queue: :queue.new(),
            size: 0,
            revisions: %{},
            overflowed: false,
            closed: false

  @doc "Creates an empty buffer with a positive capacity."
  @spec new(pos_integer()) :: t()
  def new(capacity) when is_integer(capacity) and capacity > 0 do
    %__MODULE__{capacity: capacity}
  end

  @doc """
  Retains a committed task snapshot in the buffer.

  Returns the outcome and the (possibly updated) buffer:

    * `:retained` — the task ID was not pending and a queue slot was free.
    * `:replaced` — a newer revision replaced the pending snapshot in place.
    * `:ignored` — the revision was equal to or older than the pending
      snapshot, or the buffer is already overflowed or closed.
    * `:overflow` — the task ID was not pending and the buffer was at
      capacity. The buffer entered its terminal overflow state and dropped
      every retained snapshot.
  """
  @spec retain(t(), Task.t()) :: {retain_status(), t()}
  def retain(%__MODULE__{closed: true} = buffer, _task), do: {:ignored, buffer}
  def retain(%__MODULE__{overflowed: true} = buffer, _task), do: {:ignored, buffer}

  def retain(%__MODULE__{} = buffer, %Task{} = task) do
    case Map.fetch(buffer.revisions, task.id) do
      {:ok, revision} when revision >= task.revision ->
        {:ignored, buffer}

      {:ok, _stale_revision} ->
        {:replaced,
         %{
           buffer
           | queue: replace(buffer.queue, task),
             revisions: Map.put(buffer.revisions, task.id, task.revision)
         }}

      :error ->
        if buffer.size >= buffer.capacity do
          {:overflow, mark_overflow(buffer)}
        else
          {
            :retained,
            %{
              buffer
              | queue: :queue.in(task, buffer.queue),
                size: buffer.size + 1,
                revisions: Map.put(buffer.revisions, task.id, task.revision)
            }
          }
        end
    end
  end

  @doc """
  Takes the next queued snapshot in FIFO order.

  Returns the result and the (possibly updated) buffer: `{:ok, task}` for the
  next snapshot, `:empty` when the buffer is active but nothing is pending,
  `:overflow` for a buffer in its terminal overflow state, and `:closed` for
  a closed buffer.
  """
  @spec take(t()) :: {take_result(), t()}
  def take(%__MODULE__{closed: true} = buffer), do: {:closed, buffer}
  def take(%__MODULE__{overflowed: true} = buffer), do: {:overflow, buffer}

  def take(%__MODULE__{} = buffer) do
    case :queue.out(buffer.queue) do
      {{:value, task}, queue} ->
        {{:ok, task},
         %{
           buffer
           | queue: queue,
             size: buffer.size - 1,
             revisions: Map.delete(buffer.revisions, task.id)
         }}

      {:empty, _queue} ->
        {:empty, buffer}
    end
  end

  @doc """
  Moves the buffer into its terminal overflow state, dropping every retained
  snapshot. A closed buffer stays closed.
  """
  @spec mark_overflow(t()) :: t()
  def mark_overflow(%__MODULE__{closed: true} = buffer), do: buffer

  def mark_overflow(%__MODULE__{} = buffer) do
    %{buffer | queue: :queue.new(), size: 0, revisions: %{}, overflowed: true}
  end

  @doc """
  Closes the buffer for a torn-down subscription, dropping every retained
  snapshot. `take/1` then reports `:closed` and `retain/2` ignores
  publications.
  """
  @spec close(t()) :: t()
  def close(%__MODULE__{} = buffer) do
    %{buffer | queue: :queue.new(), size: 0, revisions: %{}, closed: true}
  end

  @doc "Returns the number of distinct pending task IDs."
  @spec size(t()) :: non_neg_integer()
  def size(%__MODULE__{size: size}), do: size

  @doc "Returns true when the buffer is in its terminal overflow state."
  @spec overflowed?(t()) :: boolean()
  def overflowed?(%__MODULE__{overflowed: overflowed}), do: overflowed

  @doc "Returns true when the buffer is closed."
  @spec closed?(t()) :: boolean()
  def closed?(%__MODULE__{closed: closed}), do: closed

  defp replace(queue, task) do
    queue
    |> :queue.to_list()
    |> Enum.map(fn
      %Task{id: id} when id == task.id -> task
      other -> other
    end)
    |> Enum.reduce(:queue.new(), fn item, acc -> :queue.in(item, acc) end)
  end
end
