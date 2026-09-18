defmodule TamaMCP.Task.InputResponses do
  @moduledoc """
  Pure acceptance planner for `input_required` task input responses.

  The `TamaMCP.Task.Store.update/4` contract defines protocol-significant
  classification rules that every durable host adapter must apply identically:
  accept only responses for currently outstanding input-request keys, ignore
  unknown, already-answered, and superseded keys, record response history
  idempotently, and avoid revision advancement or worker signalling when no
  new response is accepted. `plan/3` packages those rules as pure package
  behavior so adapters own only the transactional commit of the returned plan
  and their durable wake-up.

  The planner performs no I/O, advances no revision, publishes no
  notifications, and does not depend on a persistence or queue implementation.
  """

  alias TamaMCP.{JSON, Task}

  defmodule Plan do
    @moduledoc """
    Acceptance plan returned by `TamaMCP.Task.InputResponses.plan/3`.

    `accepted` contains only the newly accepted responses, `recorded` is the
    complete merged response history, `remaining` holds only the still
    outstanding input requests, and `no_op` is `true` when nothing was
    accepted and the adapter must not advance the task revision or signal its
    worker.
    """

    defstruct accepted: %{}, recorded: %{}, remaining: %{}, no_op: false

    @type t :: %__MODULE__{
            accepted: map(),
            recorded: map(),
            remaining: map(),
            no_op: boolean()
          }
  end

  @doc """
  Plans which incoming input responses to accept for the current task state.

  `recorded` is the response history the host has already recorded for the
  task, mapping accepted response keys to response objects. `incoming` is the
  received `inputResponses` map.

  A response is accepted only when its key is currently outstanding in
  `task.input_requests` and not already present in `recorded`. Unknown keys,
  already-answered keys, and superseded keys (issued earlier but no longer
  outstanding) are ignored. Replaying an identical or conflicting response for
  an answered key is a no-op and never replaces recorded history. `remaining`
  is derived from `task.input_requests` only and never contains response
  objects. The task's `input_request_keys` lifetime history is untouched, so
  issued keys remain non-reusable under `TamaMCP.Task.transition/4`.

  The returned plan is deterministic and JSON-safe.

  Returns `{:error, :invalid_state}` when the task is not in `input_required`
  with outstanding requests and `{:error, :invalid_input}` when the task
  requests or either supplied map is not a string-keyed JSON object.
  """
  @spec plan(Task.t(), map(), map()) ::
          {:ok, Plan.t()} | {:error, :invalid_state | :invalid_input}
  def plan(%Task{} = task, recorded, incoming) do
    with {:ok, requests} <- outstanding_requests(task),
         :ok <- json_object(recorded),
         :ok <- json_object(incoming) do
      answered = Map.keys(recorded)

      accepted_keys =
        requests
        |> Map.keys()
        |> Enum.reject(&(&1 in answered or not Map.has_key?(incoming, &1)))

      accepted = select(incoming, accepted_keys)

      plan = %Plan{
        accepted: accepted,
        recorded: select(Map.merge(recorded, accepted), Map.keys(recorded) ++ accepted_keys),
        remaining: select(requests, Map.keys(requests) -- accepted_keys),
        no_op: accepted_keys == []
      }

      {:ok, plan}
    end
  end

  defp outstanding_requests(%Task{status: :input_required, input_requests: requests})
       when is_map(requests) do
    if JSON.value?(requests), do: {:ok, requests}, else: {:error, :invalid_input}
  end

  defp outstanding_requests(%Task{}), do: {:error, :invalid_state}

  defp json_object(map) when is_map(map) do
    if JSON.value?(map), do: :ok, else: {:error, :invalid_input}
  end

  defp json_object(_value), do: {:error, :invalid_input}

  defp select(source, keys) do
    keys
    |> Enum.sort()
    |> Enum.map(&{&1, Map.fetch!(source, &1)})
    |> Map.new()
  end
end
