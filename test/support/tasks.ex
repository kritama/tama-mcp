defmodule TamaMCP.TestSupport.Tasks.Clock do
  @moduledoc false

  @behaviour TamaMCP.Clock

  @now ~U[2026-09-14 12:00:00Z]

  @impl true
  def now(options), do: {:ok, Keyword.get(options, :now, @now)}
end

defmodule TamaMCP.TestSupport.Tasks.Identifier do
  @moduledoc false

  @behaviour TamaMCP.Identifier

  @impl true
  def generate(options), do: {:ok, Keyword.get(options, :task_id, "task-phase2-1")}
end

defmodule TamaMCP.TestSupport.Tasks.Store do
  @moduledoc false

  @behaviour TamaMCP.Task.Store

  alias TamaMCP.Task

  @input_responses :tama_mcp_test_input_responses

  def start_link, do: Agent.start_link(fn -> %{} end)

  @impl true
  def create(%Task{} = task, options) do
    Agent.get_and_update(agent(options), fn tasks ->
      key = {task.owner_key, task.id}

      if Map.has_key?(tasks, key),
        do: {{:error, :conflict}, tasks},
        else: {{:ok, task}, Map.put(tasks, key, task)}
    end)
  end

  @impl true
  def get(owner_key, task_id, options) do
    case Agent.get(agent(options), &Map.get(&1, {owner_key, task_id})) do
      nil -> {:error, :not_found}
      task -> {:ok, task}
    end
  end

  @impl true
  def transition(owner_key, task_id, revision, status, attributes, options) do
    Agent.get_and_update(agent(options), fn tasks ->
      key = {owner_key, task_id}

      case Map.get(tasks, key) do
        nil ->
          {{:error, :not_found}, tasks}

        %Task{revision: current} when current != revision ->
          {{:error, :conflict}, tasks}

        %Task{} = task ->
          apply_transition(tasks, key, task, status, attributes, options)
      end
    end)
  end

  @impl true
  def update(owner_key, task_id, input_responses, options) do
    result =
      Agent.get_and_update(agent(options), fn tasks ->
        key = {owner_key, task_id}

        case Map.get(tasks, key) do
          nil ->
            {{:error, :not_found}, tasks}

          %Task{status: :input_required} = task ->
            accept_input_responses(tasks, key, task, input_responses, options)

          %Task{} ->
            {{:error, :invalid_state}, tasks}
        end
      end)

    case result do
      {:ok, accepted} when map_size(accepted) == 0 ->
        :ok

      {:ok, accepted} ->
        notify(options, {:task_updated, task_id, accepted})
        :ok

      {:error, _reason} = error ->
        error
    end
  end

  @impl true
  def cancel(owner_key, task_id, options) do
    result =
      Agent.get_and_update(agent(options), fn tasks ->
        key = {owner_key, task_id}

        case Map.get(tasks, key) do
          nil ->
            {{:error, :not_found}, tasks}

          %Task{status: status} = task when status in [:working, :input_required] ->
            record_cancellation(tasks, key, task, options)

          %Task{} ->
            {{:error, :invalid_state}, tasks}
        end
      end)

    case result do
      {:ok, :recorded} ->
        notify(options, {:task_cancelled, task_id})
        :ok

      {:ok, :replayed} ->
        :ok

      {:error, _reason} = error ->
        error
    end
  end

  def input_responses(owner_key, task_id, options) do
    Agent.get(agent(options), &Map.get(&1, responses_key(owner_key, task_id), %{}))
  end

  def replace(owner_key, task_id, %Task{} = task, options) do
    Agent.update(agent(options), &Map.put(&1, {owner_key, task_id}, task))
  end

  defp agent(options), do: Keyword.fetch!(options, :agent)

  defp apply_transition(tasks, key, task, status, attributes, options) do
    validation_options = get_in(options, [:tama_mcp, :task_validation_options]) || []

    case Task.transition(task, status, attributes, validation_options) do
      {:ok, updated} -> {{:ok, updated}, Map.put(tasks, key, updated)}
      {:error, reason} -> {{:error, reason}, tasks}
    end
  end

  defp accept_input_responses(tasks, key, task, input_responses, options)
       when is_map(input_responses) do
    response_key = responses_key(task.owner_key, task.id)
    answered = Map.get(tasks, response_key, %{})

    accepted =
      input_responses
      |> Map.take(Map.keys(task.input_requests))
      |> Map.drop(Map.keys(answered))

    if map_size(accepted) == 0 do
      {{:ok, %{}}, tasks}
    else
      remaining = Map.drop(task.input_requests, Map.keys(accepted))
      validation_options = validation_options(options)

      case Task.transition(
             task,
             :input_required,
             %{input_requests: remaining, last_updated_at: next_updated_at(task)},
             validation_options
           ) do
        {:ok, updated} ->
          updated_tasks =
            tasks
            |> Map.put(key, updated)
            |> Map.put(response_key, Map.merge(answered, accepted))

          {{:ok, accepted}, updated_tasks}

        {:error, reason} ->
          {{:error, reason}, tasks}
      end
    end
  end

  defp accept_input_responses(tasks, _key, _task, _input_responses, _options),
    do: {{:error, :invalid_state}, tasks}

  defp record_cancellation(tasks, _key, %Task{cancellation_requested: true}, _options),
    do: {{:ok, :replayed}, tasks}

  defp record_cancellation(tasks, key, task, options) do
    case Task.transition(
           task,
           task.status,
           %{cancellation_requested: true, last_updated_at: next_updated_at(task)},
           validation_options(options)
         ) do
      {:ok, updated} -> {{:ok, :recorded}, Map.put(tasks, key, updated)}
      {:error, reason} -> {{:error, reason}, tasks}
    end
  end

  defp validation_options(options),
    do: get_in(options, [:tama_mcp, :task_validation_options]) || []

  defp responses_key(owner_key, task_id), do: {@input_responses, owner_key, task_id}
  defp next_updated_at(task), do: DateTime.add(task.last_updated_at, 1, :microsecond)

  defp notify(options, message) do
    case Keyword.get(options, :test) do
      pid when is_pid(pid) -> send(pid, message)
      _none -> :ok
    end
  end
end

defmodule TamaMCP.TestSupport.Tasks.Runner do
  @moduledoc false

  @behaviour TamaMCP.Task.Runner

  alias TamaMCP.Task
  alias TamaMCP.TestSupport.Tasks.Store

  @impl true
  def start(tool, input, context, options) do
    case Keyword.get(options, :result, :ok) do
      :ok -> create(tool, input, context, options)
      :raise -> raise "task runner secret must not leak"
      :throw -> throw("task runner secret must not leak")
      :exit -> exit("task runner secret must not leak")
      {:error, error} -> {:error, error}
      invalid -> invalid
    end
  end

  defp create(tool, input, context, options) do
    generated = Keyword.fetch!(options, :tama_mcp)

    {:ok, task} = build_task(context, generated)
    persist(task, generated, Keyword.get(options, :persistence, :valid))
    maybe_transition(task, generated, options)

    case Keyword.get(options, :test) do
      pid when is_pid(pid) -> send(pid, {:task_started, tool, input, context, task, generated})
      _none -> :ok
    end

    {:ok, task}
  end

  defp build_task(context, generated) do
    Task.new(
      %{
        id: generated[:task_id],
        owner_key: context.owner_key,
        method: generated[:method],
        request_id: generated[:request_id],
        status_message: "Queued for durable execution.",
        created_at: generated[:created_at],
        last_updated_at: generated[:created_at],
        ttl_ms: generated[:ttl_ms],
        poll_interval_ms: generated[:poll_interval_ms],
        original_params: generated[:original_params],
        client_capabilities: generated[:client_capabilities]
      },
      generated[:task_validation_options]
    )
  end

  defp persist(_task, _generated, :missing), do: :ok

  defp persist(task, generated, mode) do
    {:ok, ^task} = Store.create(task, generated[:task_store_options])

    case mode do
      :valid ->
        :ok

      :mismatched ->
        Store.replace(
          task.owner_key,
          task.id,
          %{task | request_id: "mismatched-request"},
          generated[:task_store_options]
        )

      :invalid ->
        Store.replace(
          task.owner_key,
          task.id,
          %{task | ttl_ms: 0},
          generated[:task_store_options]
        )
    end
  end

  defp maybe_transition(task, generated, options) do
    case Keyword.get(options, :transition_after_create) do
      {status, attributes} ->
        {:ok, _persisted} =
          Store.transition(
            task.owner_key,
            task.id,
            task.revision,
            status,
            attributes,
            generated[:task_store_options]
          )

        :ok

      nil ->
        :ok
    end
  end
end
