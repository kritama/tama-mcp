defmodule TamaMCP.Task do
  @moduledoc """
  TamaMCP-owned durable task value and transition rules.

  Adapter-only fields such as `owner_key`, `original_params`, cancellation
  intent, and `revision` are never encoded on the MCP wire.
  """

  alias TamaMCP.{Error, JSON, Protocol}
  alias TamaMCP.Schema.Protocol, as: ProtocolSchema
  alias TamaMCP.Schema.Tasks, as: TasksSchema

  @statuses [:working, :input_required, :completed, :failed, :cancelled]
  @terminal [:completed, :failed, :cancelled]
  @maximum_protocol_integer 9_007_199_254_740_991
  @transitions %{
    working: [:input_required, :completed, :failed, :cancelled],
    input_required: [:working, :completed, :failed, :cancelled],
    completed: [],
    failed: [],
    cancelled: []
  }

  @enforce_keys [
    :id,
    :owner_key,
    :method,
    :request_id,
    :status,
    :created_at,
    :last_updated_at,
    :ttl_ms
  ]
  defstruct [
    :id,
    :owner_key,
    :method,
    :request_id,
    :status,
    :status_message,
    :created_at,
    :last_updated_at,
    :ttl_ms,
    :poll_interval_ms,
    :input_requests,
    :result,
    :error,
    :original_params,
    cancellation_requested: false,
    revision: 0
  ]

  @type status :: :working | :input_required | :completed | :failed | :cancelled
  @type t :: %__MODULE__{
          id: String.t(),
          owner_key: term(),
          method: String.t(),
          request_id: String.t() | integer(),
          status: status(),
          status_message: String.t() | nil,
          created_at: DateTime.t(),
          last_updated_at: DateTime.t(),
          ttl_ms: pos_integer(),
          poll_interval_ms: pos_integer() | nil,
          input_requests: map() | nil,
          result: map() | nil,
          error: Error.t() | nil,
          original_params: map() | nil,
          cancellation_requested: boolean(),
          revision: non_neg_integer()
        }

  @doc """
  Creates the deterministic initial `working` task value.

  The validation options are the same bounds accepted by `validate/2`.
  Applications using non-default runtime limits must pass those effective
  options when constructing the task.
  """
  @spec new(map() | keyword(), keyword()) :: {:ok, t()} | {:error, :invalid_task}
  def new(attributes, options \\ []) do
    attributes = Map.new(attributes)

    task =
      struct(
        __MODULE__,
        Map.merge(attributes, %{
          status: :working,
          input_requests: nil,
          result: nil,
          error: nil,
          cancellation_requested: false,
          revision: 0
        })
      )

    case validate(task, options) do
      :ok -> {:ok, task}
      {:error, :invalid_task} -> {:error, :invalid_task}
    end
  rescue
    _exception -> {:error, :invalid_task}
  end

  @doc """
  Validates the package task invariant.

  In addition to task metadata and state, validation bounds the complete
  encoded `tasks/get` result. Runtime adapters receive the effective result
  limit, error-data limit, and server metadata through their reserved
  validation options.
  """
  @spec validate(t(), keyword()) :: :ok | {:error, :invalid_task}
  def validate(%__MODULE__{} = task, options \\ []) do
    maximum = Keyword.get(options, :max_status_message_bytes, 2_048)
    maximum_ttl = Keyword.get(options, :max_task_ttl_ms, 604_800_000)

    if common?(task, maximum, maximum_ttl) and payload?(task, options) and
         result_size?(task, options),
       do: :ok,
       else: {:error, :invalid_task}
  rescue
    _exception -> {:error, :invalid_task}
  catch
    _kind, _reason -> {:error, :invalid_task}
  end

  @doc """
  Applies one explicit, revision-advancing task transition.

  Every committed transition must strictly advance `last_updated_at`. The
  validation options must match those used when constructing the task.
  """
  @spec transition(t(), status(), map() | keyword(), keyword()) ::
          {:ok, t()} | {:error, :invalid_state | :invalid_task}
  def transition(%__MODULE__{} = task, next_status, attributes \\ %{}, options \\ []) do
    attributes = Map.new(attributes)

    cond do
      next_status not in @statuses ->
        {:error, :invalid_state}

      task.status in @terminal ->
        terminal_replay(task, next_status, attributes)

      next_status == task.status and next_status in [:working, :input_required] ->
        update(task, next_status, attributes, options)

      next_status in Map.fetch!(@transitions, task.status) ->
        update(task, next_status, attributes, options)

      true ->
        {:error, :invalid_state}
    end
  rescue
    _exception -> {:error, :invalid_task}
  end

  @doc "Returns whether the task is in a terminal state."
  @spec terminal?(t()) :: boolean()
  def terminal?(%__MODULE__{status: status}), do: status in @terminal

  @doc "Encodes the initial task handle returned by task-augmented execution."
  @spec create_result(t()) :: map()
  def create_result(%__MODULE__{} = task) do
    task |> base() |> Map.put("resultType", Protocol.result_type(:task))
  end

  @doc "Encodes the detailed task returned by `tasks/get`."
  @spec get_result(t(), pos_integer()) :: map()
  def get_result(%__MODULE__{} = task, max_error_data_bytes \\ 8_192) do
    result = task |> base() |> Map.put("resultType", Protocol.result_type(:complete))
    payload(result, task, max_error_data_bytes)
  end

  defp update(task, status, attributes, options) do
    with %DateTime{} = updated_at <- attributes[:last_updated_at],
         :gt <- DateTime.compare(updated_at, task.last_updated_at) do
      candidate =
        task
        |> Map.merge(%{
          status: status,
          status_message: Map.get(attributes, :status_message, task.status_message),
          last_updated_at: updated_at,
          poll_interval_ms: Map.get(attributes, :poll_interval_ms, task.poll_interval_ms),
          cancellation_requested:
            Map.get(attributes, :cancellation_requested, task.cancellation_requested),
          revision: task.revision + 1
        })
        |> state_payload(status, attributes)

      case validate(candidate, options) do
        :ok -> {:ok, candidate}
        {:error, :invalid_task} -> {:error, :invalid_task}
      end
    else
      _invalid -> {:error, :invalid_task}
    end
  end

  defp state_payload(task, :working, _attributes),
    do: %{task | input_requests: nil, result: nil, error: nil}

  defp state_payload(task, :input_required, attributes),
    do: %{
      task
      | input_requests: Map.get(attributes, :input_requests, task.input_requests),
        result: nil,
        error: nil
    }

  defp state_payload(task, :completed, attributes),
    do: %{task | input_requests: nil, result: attributes[:result], error: nil}

  defp state_payload(task, :failed, attributes),
    do: %{task | input_requests: nil, result: nil, error: attributes[:error]}

  defp state_payload(task, :cancelled, _attributes),
    do: %{task | input_requests: nil, result: nil, error: nil}

  defp terminal_replay(task, next_status, attributes) do
    if next_status == task.status and replay_payload(task, attributes) == terminal_payload(task),
      do: {:ok, task},
      else: {:error, :invalid_state}
  end

  defp replay_payload(task, attributes) do
    %{
      status_message: Map.get(attributes, :status_message, task.status_message),
      result: Map.get(attributes, :result, task.result),
      error: Map.get(attributes, :error, task.error)
    }
  end

  defp terminal_payload(task) do
    %{status_message: task.status_message, result: task.result, error: task.error}
  end

  defp common?(task, maximum, maximum_ttl) do
    identity?(task) and timestamps?(task) and timing?(task, maximum_ttl) and
      metadata?(task, maximum)
  end

  defp identity?(task) do
    is_binary(task.id) and task.id != "" and not is_nil(task.owner_key) and
      is_binary(task.method) and task.method != "" and
      (is_binary(task.request_id) or is_integer(task.request_id)) and task.status in @statuses
  end

  defp timestamps?(task) do
    match?(%DateTime{}, task.created_at) and utc?(task.created_at) and
      match?(%DateTime{}, task.last_updated_at) and utc?(task.last_updated_at) and
      DateTime.compare(task.last_updated_at, task.created_at) != :lt
  end

  defp timing?(task, maximum_ttl) do
    is_integer(maximum_ttl) and maximum_ttl > 0 and
      is_integer(task.ttl_ms) and task.ttl_ms > 0 and
      task.ttl_ms <= min(maximum_ttl, @maximum_protocol_integer) and
      (is_nil(task.poll_interval_ms) or
         (is_integer(task.poll_interval_ms) and task.poll_interval_ms > 0 and
            task.poll_interval_ms <= @maximum_protocol_integer))
  end

  defp metadata?(task, maximum) do
    status_message?(task.status_message, maximum) and original_params?(task.original_params) and
      is_boolean(task.cancellation_requested) and is_integer(task.revision) and task.revision >= 0
  end

  defp original_params?(nil), do: true
  defp original_params?(params), do: is_map(params) and JSON.value?(params)

  defp payload?(%__MODULE__{status: :working} = task, _options),
    do: is_nil(task.input_requests) and is_nil(task.result) and is_nil(task.error)

  defp payload?(%__MODULE__{status: :input_required} = task, options),
    do:
      is_map(task.input_requests) and JSON.value?(task.input_requests) and is_nil(task.result) and
        is_nil(task.error) and
        schema_valid?(TasksSchema, :input_requests, task.input_requests, options)

  defp payload?(%__MODULE__{status: :completed} = task, options),
    do:
      is_nil(task.input_requests) and is_map(task.result) and JSON.value?(task.result) and
        is_nil(task.error) and
        schema_valid?(ProtocolSchema, :call_tool_result, task.result, options)

  defp payload?(%__MODULE__{status: :failed} = task, _options),
    do: is_nil(task.input_requests) and is_nil(task.result) and match?(%Error{}, task.error)

  defp payload?(%__MODULE__{status: :cancelled} = task, _options),
    do: is_nil(task.input_requests) and is_nil(task.result) and is_nil(task.error)

  defp schema_valid?(schema, kind, value, options) do
    cache = Keyword.get(options, :cache)
    cache_options = Keyword.get(options, :cache_options, [])

    is_atom(cache) and not is_nil(cache) and Keyword.keyword?(cache_options) and
      schema.validate(kind, value, cache, cache_options) == :ok
  end

  defp result_size?(task, options) do
    maximum = Keyword.get(options, :max_result_bytes, 1_048_576)
    maximum_error = Keyword.get(options, :max_error_data_bytes, 8_192)
    metadata = Keyword.get(options, :result_metadata, %{})

    result =
      task
      |> get_result(maximum_error)
      |> put_result_metadata(metadata)

    is_integer(maximum) and maximum > 0 and is_map(metadata) and JSON.value?(metadata) and
      match?({:ok, encoded} when byte_size(encoded) <= maximum, Jason.encode(result))
  rescue
    _exception -> false
  end

  defp put_result_metadata(result, metadata) when map_size(metadata) == 0, do: result
  defp put_result_metadata(result, metadata), do: Map.put(result, "_meta", metadata)

  defp status_message?(nil, _maximum), do: true

  defp status_message?(message, maximum),
    do: is_binary(message) and String.valid?(message) and byte_size(message) <= maximum

  defp utc?(%DateTime{utc_offset: 0, std_offset: 0}), do: true
  defp utc?(_datetime), do: false

  defp base(task) do
    %{
      "taskId" => task.id,
      "status" => Protocol.task_status(task.status),
      "createdAt" => DateTime.to_iso8601(task.created_at),
      "lastUpdatedAt" => DateTime.to_iso8601(task.last_updated_at),
      "ttlMs" => task.ttl_ms
    }
    |> put("statusMessage", task.status_message)
    |> put("pollIntervalMs", task.poll_interval_ms)
  end

  defp payload(result, %{status: :input_required, input_requests: requests}, _maximum),
    do: Map.put(result, "inputRequests", requests)

  defp payload(result, %{status: :completed, result: completed}, _maximum),
    do: Map.put(result, "result", completed)

  defp payload(result, %{status: :failed, error: error}, maximum),
    do: Map.put(result, "error", Error.encode(error, maximum))

  defp payload(result, _task, _maximum), do: result

  defp put(map, _key, nil), do: map
  defp put(map, key, value), do: Map.put(map, key, value)
end
