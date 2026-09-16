defmodule TamaMCP.Notification do
  @moduledoc """
  Adapter-neutral delivery contract for committed task snapshots.

  A subscription is created only after the transport has authenticated the
  request and resolved the requested task IDs through the owner-bound task
  store. Adapters deliver bounded wake-up and overflow messages to the
  subscriber; the stream pulls each queued snapshot with `take/2`.

  Publishing is a best-effort hint after a durable task transition commits.
  It must not block, roll back, or reinterpret the transition. Clients recover
  missed or dropped notifications through `tasks/get`.

  An adapter sends `ready/1` when `take/2` can return a queued snapshot and
  `overflow/1` when the subscriber has exceeded its configured capacity. A
  ready signal may be coalesced. An adapter may also coalesce multiple pending
  snapshots for the same task because the transport re-fetches current durable
  state before delivery. It must never exceed the capacity supplied to
  `subscribe/4` or allow publisher work to wait on stream I/O.
  """

  alias TamaMCP.{Error, Task}

  @type subscription :: term()
  @type options :: keyword()

  @callback subscribe([String.t()], pid(), pos_integer(), options()) ::
              {:ok, subscription()} | {:error, Error.t()}

  @callback take(subscription(), options()) ::
              {:ok, Task.t()} | :empty | {:error, :closed | :overflow | Error.t()}

  @callback unsubscribe(subscription(), options()) :: :ok | {:error, Error.t()}

  @callback publish(Task.t(), options()) :: :ok | {:error, Error.t()}

  @doc """
  Publishes a task snapshot after its durable transition has committed.

  The options are the task-store options supplied by TamaMCP. With no
  configured adapter this is a no-op. Adapter failures are contained as bounded
  package errors and never alter the committed task.
  """
  @spec publish_committed(Task.t(), keyword()) :: :ok | {:error, Error.t()}
  def publish_committed(%Task{} = task, options) when is_list(options) do
    namespace = Keyword.get(options, :tama_mcp, options)

    case Keyword.get(namespace, :notification) do
      nil ->
        :ok

      adapter when is_atom(adapter) ->
        result = safe_publish(adapter, task, Keyword.get(namespace, :notification_options, []))
        emit(namespace, result)
        result

      _invalid ->
        {:error, Error.internal()}
    end
  end

  def publish_committed(_task, _options), do: {:error, Error.internal()}

  @doc "Builds the bounded wake-up message sent to a subscription process."
  @spec ready(subscription()) :: {module(), subscription(), :ready}
  def ready(subscription), do: {__MODULE__, subscription, :ready}

  @doc "Builds the overflow message sent before a lagging subscription closes."
  @spec overflow(subscription()) :: {module(), subscription(), :overflow}
  def overflow(subscription), do: {__MODULE__, subscription, :overflow}

  defp safe_publish(adapter, task, options) do
    case adapter.publish(task, options) do
      :ok -> :ok
      {:error, %Error{} = error} -> {:error, error}
      _invalid -> {:error, Error.internal()}
    end
  rescue
    _exception -> {:error, Error.internal()}
  catch
    _kind, _reason -> {:error, Error.internal()}
  end

  defp emit(namespace, result) do
    prefix = Keyword.get(namespace, :telemetry_prefix)

    if is_list(prefix) and prefix != [] and Enum.all?(prefix, &is_atom/1) do
      status = if result == :ok, do: :ok, else: :error

      metadata = %{
        server: bounded(Keyword.get(namespace, :server, "unknown")),
        method: "notifications/tasks",
        status: status,
        reason: if(status == :ok, do: :published, else: :publish_failed)
      }

      :telemetry.execute(prefix ++ [:notification, :publish], %{}, metadata)
    end

    :ok
  end

  defp bounded(value) when is_binary(value) and byte_size(value) <= 512, do: value

  defp bounded(value) when is_binary(value) do
    value
    |> String.graphemes()
    |> Enum.reduce_while("", fn grapheme, result ->
      if byte_size(result) + byte_size(grapheme) > 512,
        do: {:halt, result},
        else: {:cont, result <> grapheme}
    end)
  end

  defp bounded(_value), do: "unknown"
end
