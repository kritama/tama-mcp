defmodule TamaMCPTest do
  use ExUnit.Case
  doctest TamaMCP

  test "exposes the single supported protocol version" do
    assert TamaMCP.protocol_version() == "2026-07-28"
  end

  test "exposes the tasks extension identifier" do
    assert TamaMCP.tasks_extension() == "io.modelcontextprotocol/tasks"
  end

  test "publishes the complete fixed protocol vocabulary" do
    assert TamaMCP.Protocol.methods()[:server_discover] == "server/discover"
    assert :tools_call in Map.keys(TamaMCP.Protocol.methods())

    assert TamaMCP.Protocol.name_scoped_methods() == [
             :tools_call,
             :tasks_get,
             :tasks_update,
             :tasks_cancel
           ]

    assert TamaMCP.Protocol.task_status(:completed) == "completed"

    assert Enum.sort(TamaMCP.Protocol.task_statuses()) ==
             ~w(cancelled completed failed input_required working)
  end
end
