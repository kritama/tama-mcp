defmodule TamaMCP.Notification.BufferTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias TamaMCP.Notification.Buffer
  alias TamaMCP.Task

  test "creates buffers only with a positive capacity" do
    assert %Buffer{capacity: 3} = Buffer.new(3)
    assert_raise FunctionClauseError, fn -> Buffer.new(0) end
    assert_raise FunctionClauseError, fn -> Buffer.new(-1) end
    assert_raise FunctionClauseError, fn -> Buffer.new("3") end
  end

  test "retains and takes complete task snapshots in FIFO order" do
    buffer = Buffer.new(3)

    assert {:retained, buffer} = Buffer.retain(buffer, task("task-1", 1))
    assert {:retained, buffer} = Buffer.retain(buffer, task("task-2", 0))
    assert Buffer.size(buffer) == 2

    assert {{:ok, first}, buffer} = Buffer.take(buffer)
    assert first.id == "task-1"
    assert %Task{} = first

    assert {{:ok, second}, buffer} = Buffer.take(buffer)
    assert second.id == "task-2"

    assert {:empty, buffer} = Buffer.take(buffer)
    assert Buffer.size(buffer) == 0
  end

  test "a newer pending revision replaces the queued snapshot in place" do
    buffer = Buffer.new(2)

    assert {:retained, buffer} = Buffer.retain(buffer, task("task-1", 1))
    assert {:retained, buffer} = Buffer.retain(buffer, task("task-2", 0))
    assert {:replaced, buffer} = Buffer.retain(buffer, task("task-1", 3))
    assert Buffer.size(buffer) == 2

    assert {{:ok, first}, buffer} = Buffer.take(buffer)
    assert first.revision == 3

    assert {{:ok, second}, buffer} = Buffer.take(buffer)
    assert second.id == "task-2"
    assert {:empty, _} = Buffer.take(buffer)
  end

  test "equal and older revisions are ignored" do
    buffer = Buffer.new(1)

    assert {:retained, buffer} = Buffer.retain(buffer, task("task-1", 2))
    assert {:ignored, buffer} = Buffer.retain(buffer, task("task-1", 2))
    assert {:ignored, buffer} = Buffer.retain(buffer, task("task-1", 1))

    assert {{:ok, first}, _buffer} = Buffer.take(buffer)
    assert first.revision == 2
  end

  test "replacing a task does not duplicate it or move its position" do
    buffer = Buffer.new(3)

    buffer =
      buffer
      |> retain(task("task-1", 1))
      |> retain(task("task-2", 0))
      |> retain(task("task-3", 0))
      |> Buffer.retain(task("task-2", 5))
      |> elem(1)

    assert {{:ok, first}, buffer} = Buffer.take(buffer)
    assert {{:ok, second}, buffer} = Buffer.take(buffer)
    assert {{:ok, third}, buffer} = Buffer.take(buffer)
    assert {:empty, _} = Buffer.take(buffer)

    assert [first.id, second.id, third.id] == ["task-1", "task-2", "task-3"]
    assert second.revision == 5
  end

  test "capacity counts distinct pending task IDs at the exact boundary" do
    buffer = Buffer.new(2)

    buffer = retain(buffer, task("task-1", 0))
    buffer = retain(buffer, task("task-2", 0))
    assert Buffer.size(buffer) == 2

    assert {{:ok, _}, buffer} = Buffer.take(buffer)
    assert {:retained, buffer} = Buffer.retain(buffer, task("task-3", 0))
    assert Buffer.size(buffer) == 2
  end

  test "crossing capacity enters a terminal overflow state and drops retained content" do
    buffer = Buffer.new(2)

    buffer = retain(buffer, task("task-1", 0))
    buffer = retain(buffer, task("task-2", 0))

    assert {:overflow, buffer} = Buffer.retain(buffer, task("task-3", 0))
    assert Buffer.overflowed?(buffer)
    assert Buffer.size(buffer) == 0

    assert {:overflow, buffer} = Buffer.take(buffer)
    assert {:ignored, buffer} = Buffer.retain(buffer, task("task-4", 0))
    assert {:overflow, _} = Buffer.take(buffer)
  end

  test "replacing a pending snapshot never crosses capacity" do
    buffer = Buffer.new(1)

    buffer = retain(buffer, task("task-1", 0))

    assert {:replaced, buffer} = Buffer.retain(buffer, task("task-1", 9))
    refute Buffer.overflowed?(buffer)
    assert {{:ok, task}, _} = Buffer.take(buffer)
    assert task.revision == 9
  end

  test "mark_overflow drops retained content and is observed by take" do
    buffer = Buffer.new(2)
    buffer = retain(buffer, task("task-1", 0))

    buffer = Buffer.mark_overflow(buffer)

    assert Buffer.overflowed?(buffer)
    assert Buffer.size(buffer) == 0
    assert {:overflow, _} = Buffer.take(buffer)
    assert {:ignored, _} = Buffer.retain(buffer, task("task-1", 1))
  end

  test "close drops retained content and take reports closed" do
    buffer = Buffer.new(1)
    buffer = retain(buffer, task("task-1", 0))

    buffer = Buffer.close(buffer)

    assert Buffer.closed?(buffer)
    assert Buffer.size(buffer) == 0
    assert {:closed, _} = Buffer.take(buffer)
    assert {:ignored, _} = Buffer.retain(buffer, task("task-1", 1))
  end

  test "close takes precedence over a later mark_overflow" do
    buffer = Buffer.new(1) |> Buffer.close()
    buffer = Buffer.mark_overflow(buffer)
    assert {:closed, _} = Buffer.take(buffer)
  end

  defp retain(buffer, task), do: elem(Buffer.retain(buffer, task), 1)

  defp task(id, revision) do
    struct(Task, %{
      id: id,
      owner_key: "owner",
      method: "tools/call",
      request_id: "request-1",
      client_capabilities: %{},
      status: :working,
      created_at: ~U[2026-09-18 12:00:00Z],
      last_updated_at: ~U[2026-09-18 12:00:00Z],
      ttl_ms: 1_000,
      revision: revision
    })
  end
end
