defmodule TamaMCP.Task.StoreTest do
  use ExUnit.Case

  alias TamaMCP.{Error, Task}
  alias TamaMCP.TestSupport.Tasks.Store

  @created ~U[2026-09-14 12:00:00Z]

  setup do
    {:ok, store} = Store.start_link()
    {:ok, store: store, options: [agent: store]}
  end

  test "creation is atomic and lookup is owner-bound", %{options: options} do
    task = task()

    assert {:ok, ^task} = Store.create(task, options)
    assert {:error, :conflict} = Store.create(task, options)
    assert {:ok, ^task} = Store.get(task.owner_key, task.id, options)
    assert {:error, :not_found} = Store.get("another-owner", task.id, options)
  end

  test "compare-and-update permits only one terminal race winner", %{options: options} do
    task = task()
    assert {:ok, ^task} = Store.create(task, options)

    assert {:error, :conflict} =
             Store.transition(
               task.owner_key,
               task.id,
               1,
               :cancelled,
               %{last_updated_at: later(1)},
               options
             )

    assert {:ok, failed} =
             Store.transition(
               task.owner_key,
               task.id,
               0,
               :failed,
               %{
                 error: Error.internal("Task TTL expired"),
                 last_updated_at: later(1)
               },
               options
             )

    assert failed.status == :failed

    assert {:error, :conflict} =
             Store.transition(
               task.owner_key,
               task.id,
               0,
               :completed,
               %{
                 result: %{"resultType" => "complete", "content" => [], "isError" => false},
                 last_updated_at: later(2)
               },
               options
             )

    assert {:error, :invalid_state} = Store.cancel(task.owner_key, task.id, options)
    assert {:ok, ^failed} = Store.get(task.owner_key, task.id, options)
  end

  defp task do
    assert {:ok, task} =
             Task.new(%{
               id: "task-store-1",
               owner_key: "owner-1",
               method: "tools/call",
               request_id: "request-1",
               created_at: @created,
               last_updated_at: @created,
               ttl_ms: 60_000,
               original_params: %{"name" => "message", "arguments" => %{}}
             })

    task
  end

  defp later(seconds), do: DateTime.add(@created, seconds, :second)
end
