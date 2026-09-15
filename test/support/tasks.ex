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
    case get(owner_key, task_id, options) do
      {:ok, %Task{status: :input_required, input_requests: requests}} ->
        accepted = Map.take(input_responses, Map.keys(requests))
        notify(options, {:task_updated, task_id, accepted})
        :ok

      {:ok, %Task{}} ->
        {:error, :invalid_state}

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  @impl true
  def cancel(owner_key, task_id, options) do
    case get(owner_key, task_id, options) do
      {:ok, %Task{status: status}} when status in [:working, :input_required] ->
        notify(options, {:task_cancelled, task_id})
        :ok

      {:ok, %Task{}} ->
        {:error, :invalid_state}

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  defp agent(options), do: Keyword.fetch!(options, :agent)

  defp apply_transition(tasks, key, task, status, attributes, options) do
    validation_options = get_in(options, [:tama_mcp, :task_validation_options]) || []

    case Task.transition(task, status, attributes, validation_options) do
      {:ok, updated} -> {{:ok, updated}, Map.put(tasks, key, updated)}
      {:error, reason} -> {{:error, reason}, tasks}
    end
  end

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
      {:error, error} -> {:error, error}
      invalid -> invalid
    end
  end

  defp create(tool, input, context, options) do
    generated = Keyword.fetch!(options, :tama_mcp)

    {:ok, task} =
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
          original_params: generated[:original_params]
        },
        generated[:task_validation_options]
      )

    {:ok, task} = Store.create(task, generated[:task_store_options])
    maybe_transition(task, generated, options)

    case Keyword.get(options, :test) do
      pid when is_pid(pid) -> send(pid, {:task_started, tool, input, context, task})
      _none -> :ok
    end

    {:ok, task}
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
