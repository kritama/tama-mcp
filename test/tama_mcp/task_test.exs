defmodule TamaMCP.TaskTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias TamaMCP.{Conformance, Error, Response, Task}
  alias TamaMCP.TestSupport.Cache

  @created ~U[2026-09-14 12:00:00Z]
  @later ~U[2026-09-14 12:00:01Z]

  test "creates a bounded working task and schema-valid task handle" do
    task = task()

    assert task.status == :working
    assert task.revision == 0
    assert :ok = Task.validate(task)
    assert :ok = Conformance.validate(:create_task_result, Task.create_result(task), Cache)
    refute Map.has_key?(Task.create_result(task), "ownerKey")
  end

  test "implements every permitted state transition" do
    for next <- [:input_required, :completed, :failed, :cancelled] do
      assert {:ok, %Task{status: ^next, revision: 1}} = transition(task(), next)
    end

    input = task() |> transitioned!(:input_required)

    for next <- [:working, :completed, :failed, :cancelled] do
      assert {:ok, %Task{status: ^next, revision: 2}} = transition(input, next)
    end
  end

  test "rejects regressions and terminal payload mutation but permits exact replay" do
    terminal = [
      task() |> transitioned!(:completed),
      task() |> transitioned!(:failed),
      task() |> transitioned!(:cancelled)
    ]

    for finished <- terminal do
      assert {:ok, ^finished} =
               Task.transition(
                 finished,
                 finished.status,
                 replay_attributes(finished)
               )

      for next <- [:working, :input_required, :completed, :failed, :cancelled],
          next != finished.status do
        assert {:error, :invalid_state} =
                 Task.transition(finished, next, last_updated_at: later(60))
      end
    end

    completed = hd(terminal)

    assert {:error, :invalid_state} =
             Task.transition(completed, :completed,
               result: %{"changed" => true},
               last_updated_at: later(60)
             )

    assert {:error, :invalid_state} = Task.transition(task(), :unknown, last_updated_at: @later)
  end

  test "preserves input requests on same-state metadata updates" do
    input = task() |> transitioned!(:input_required)

    assert {:ok, updated} =
             Task.transition(input, :input_required,
               status_message: "Still waiting.",
               last_updated_at: ~U[2026-09-14 12:00:02Z]
             )

    assert updated.input_requests == input.input_requests
    assert updated.status_message == "Still waiting."
  end

  test "encodes every detailed task variant against the pinned schema" do
    tasks = [
      task(),
      transitioned!(task(), :input_required),
      transitioned!(task(), :completed),
      transitioned!(task(), :failed),
      transitioned!(task(), :cancelled)
    ]

    for task <- tasks do
      result = Task.get_result(task)
      assert :ok = Conformance.validate(:get_task_result, result, Cache)

      assert :ok =
               Conformance.validate(
                 status_kind(task.status),
                 Map.delete(result, "resultType"),
                 Cache
               )
    end
  end

  test "distinguishes completed tool errors from failed JSON-RPC execution" do
    tool_error =
      Response.tool_error(content: [Response.text("domain failure")])
      |> Response.encode()
      |> Map.put("resultType", "complete")

    completed = task() |> transitioned!(:completed, result: tool_error)
    failed = task() |> transitioned!(:failed)

    assert completed.status == :completed
    assert completed.result["isError"]
    assert failed.status == :failed
    assert %Error{} = failed.error
  end

  test "rejects invalid timestamps, TTLs, messages, and state payloads" do
    assert {:error, :invalid_task} = Task.new(Map.put(attributes(), :ttl_ms, 0))

    assert {:error, :invalid_task} =
             Task.new(Map.put(attributes(), :status_message, String.duplicate("x", 2_049)))

    assert {:error, :invalid_task} =
             Task.transition(task(), :completed,
               result: nil,
               last_updated_at: @later
             )

    assert {:error, :invalid_task} =
             Task.transition(task(), :working, last_updated_at: ~U[2026-09-14 11:59:59Z])
  end

  defp task do
    assert {:ok, task} = Task.new(attributes())
    task
  end

  defp attributes do
    %{
      id: "task-phase2-1",
      owner_key: "owner-1",
      method: "tools/call",
      request_id: "call-1",
      created_at: @created,
      last_updated_at: @created,
      ttl_ms: 86_400_000,
      poll_interval_ms: 1_000,
      original_params: %{"name" => "message", "arguments" => %{}}
    }
  end

  defp transitioned!(task, status, overrides \\ []) do
    assert {:ok, transitioned} = transition(task, status, overrides)
    transitioned
  end

  defp transition(task, status, overrides \\ [])

  defp transition(task, :working, overrides),
    do: Task.transition(task, :working, Keyword.put(overrides, :last_updated_at, @later))

  defp transition(task, :input_required, overrides) do
    attributes =
      [input_requests: %{}, last_updated_at: @later]
      |> Keyword.merge(overrides)

    Task.transition(task, :input_required, attributes)
  end

  defp transition(task, :completed, overrides) do
    result = %{"resultType" => "complete", "content" => [], "isError" => false}

    attributes = [result: result, last_updated_at: @later] |> Keyword.merge(overrides)
    Task.transition(task, :completed, attributes)
  end

  defp transition(task, :failed, overrides) do
    attributes =
      [error: Error.internal("Execution failed"), last_updated_at: @later]
      |> Keyword.merge(overrides)

    Task.transition(task, :failed, attributes)
  end

  defp transition(task, :cancelled, overrides),
    do: Task.transition(task, :cancelled, Keyword.put(overrides, :last_updated_at, @later))

  defp status_kind(:working), do: :working_task
  defp status_kind(:input_required), do: :input_required_task
  defp status_kind(:completed), do: :completed_task
  defp status_kind(:failed), do: :failed_task
  defp status_kind(:cancelled), do: :cancelled_task

  defp replay_attributes(task) do
    %{
      status_message: task.status_message,
      result: task.result,
      error: task.error,
      last_updated_at: later(60)
    }
  end

  defp later(seconds), do: DateTime.add(@created, seconds, :second)
end
