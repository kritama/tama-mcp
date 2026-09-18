defmodule TamaMCP.Task do
  @moduledoc """
  TamaMCP-owned durable task value and transition rules.

  Adapter-only fields such as `owner_key`, `original_params`,
  `client_capabilities`, cancellation intent, and `revision` are never encoded
  on the MCP wire.
  """

  alias TamaMCP.{Error, JSON, Protocol, RequestID}
  alias TamaMCP.Task.Validation

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
  @payload_checks %{
    working: [
      {:absent, :input_requests},
      {:absent, :result},
      {:absent, :error}
    ],
    input_required: [
      {:json_object, :input_requests},
      {:absent, :result},
      {:absent, :error},
      {:schema, :input_requests, TamaMCP.Schema.Tasks, :input_requests},
      {:supported_input_requests, :input_requests, :client_capabilities},
      {:recorded_keys, :input_requests, :input_request_keys}
    ],
    completed: [
      {:absent, :input_requests},
      {:json_object, :result},
      {:absent, :error},
      {:schema, :result, TamaMCP.Schema.Protocol, :call_tool_result},
      {:tool_output, :result}
    ],
    failed: [
      {:absent, :input_requests},
      {:absent, :result},
      {:struct, :error, Error},
      {:schema, {:encoded_error, :error}, TamaMCP.Schema.Tasks, :error}
    ],
    cancelled: [
      {:absent, :input_requests},
      {:absent, :result},
      {:absent, :error}
    ]
  }
  @common_checks [
    {:non_empty_binary, :id},
    {:present, :owner_key},
    {:non_empty_binary, :method},
    {:binary_or_integer, :request_id, RequestID.max_string_bytes()},
    {:one_of, :status, @statuses},
    {:utc_datetime, :created_at},
    {:utc_datetime, :last_updated_at},
    {:not_before, :last_updated_at, :created_at},
    {:bounded_positive_integer, :ttl_ms, {:option, :max_task_ttl_ms, 604_800_000},
     @maximum_protocol_integer},
    {:optional_bounded_positive_integer, :poll_interval_ms, @maximum_protocol_integer},
    {:optional_utf8_bytes, :status_message, {:option, :max_status_message_bytes, 2_048}},
    {:optional_json_object, :original_params},
    {:json_object, :client_capabilities},
    {:unique_binary_list, :input_request_keys},
    {:max_items, :input_request_keys, {:option, :max_input_request_keys_per_task, 256}},
    {:boolean, :cancellation_requested},
    {:non_negative_integer, :revision}
  ]

  @enforce_keys [
    :id,
    :owner_key,
    :method,
    :request_id,
    :client_capabilities,
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
    :client_capabilities,
    input_request_keys: [],
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
          input_request_keys: [String.t()],
          input_requests: map() | nil,
          result: map() | nil,
          error: Error.t() | nil,
          original_params: map() | nil,
          client_capabilities: map(),
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
          input_request_keys: [],
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
    validation = Validation.new(task, options)

    if Validation.valid?(validation, @common_checks) and payload?(validation, task.status) and
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

      with {:ok, candidate} <- state_payload(candidate, status, attributes, options),
           :ok <- validate(candidate, options) do
        {:ok, candidate}
      end
    else
      _invalid -> {:error, :invalid_task}
    end
  end

  defp state_payload(task, :working, _attributes, _options),
    do: {:ok, %{task | input_requests: nil, result: nil, error: nil}}

  defp state_payload(task, :input_required, attributes, options) do
    requests = Map.get(attributes, :input_requests, task.input_requests)
    maximum = Keyword.get(options, :max_input_request_keys_per_task, 256)

    with {:ok, keys} <- issue_input_request_keys(task, requests, maximum) do
      {:ok,
       %{
         task
         | input_request_keys: keys,
           input_requests: requests,
           result: nil,
           error: nil
       }}
    end
  end

  defp state_payload(task, :completed, attributes, _options),
    do: {:ok, %{task | input_requests: nil, result: attributes[:result], error: nil}}

  defp state_payload(task, :failed, attributes, _options),
    do: {:ok, %{task | input_requests: nil, result: nil, error: attributes[:error]}}

  defp state_payload(task, :cancelled, _attributes, _options),
    do: {:ok, %{task | input_requests: nil, result: nil, error: nil}}

  defp issue_input_request_keys(task, requests, maximum)
       when is_list(task.input_request_keys) and is_map(requests) and is_integer(maximum) and
              maximum > 0 do
    current = if is_map(task.input_requests), do: task.input_requests, else: %{}

    requests
    |> Enum.reduce_while(
      {:ok, MapSet.new(task.input_request_keys)},
      &record_input_request_key(&1, &2, current, maximum)
    )
    |> case do
      {:ok, issued} -> {:ok, issued |> Enum.to_list() |> Enum.sort()}
      {:error, :invalid_task} = error -> error
    end
  end

  defp issue_input_request_keys(_task, _requests, _maximum), do: {:error, :invalid_task}

  defp record_input_request_key({key, request}, {:ok, issued}, current, maximum) do
    case {Map.fetch(current, key), MapSet.member?(issued, key)} do
      {{:ok, ^request}, _issued?} -> {:cont, {:ok, issued}}
      {_new_or_changed, true} -> {:halt, {:error, :invalid_task}}
      {_new_or_changed, false} -> record_new_input_request_key(key, issued, maximum)
    end
  end

  defp record_new_input_request_key(key, issued, maximum) do
    if MapSet.size(issued) < maximum,
      do: {:cont, {:ok, MapSet.put(issued, key)}},
      else: {:halt, {:error, :invalid_task}}
  end

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

  defp payload?(validation, status) do
    Validation.valid?(validation, Map.fetch!(@payload_checks, status))
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
