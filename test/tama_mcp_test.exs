defmodule TamaMCPTest do
  use ExUnit.Case
  doctest TamaMCP

  test "exposes the single supported protocol version" do
    assert TamaMCP.protocol_version() == "2026-07-28"
  end

  test "exposes the tasks extension identifier" do
    assert TamaMCP.tasks_extension() == "io.modelcontextprotocol/tasks"
  end
end
