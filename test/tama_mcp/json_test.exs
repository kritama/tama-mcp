defmodule TamaMCP.JSONTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias TamaMCP.JSON

  test "wire values contain only native JSON types and string object keys" do
    assert JSON.value?(%{"items" => [nil, true, 1, 1.5, "value", %{}]})

    refute JSON.value?(%{atom: "key"})
    refute JSON.value?(:value)
    refute JSON.value?({:tuple, "value"})
    refute JSON.value?(["value" | :improper])
    refute JSON.value?(<<255>>)
  end

  test "metadata permits telemetry atoms but never structs" do
    assert JSON.metadata?(%{status: :ok, nested: [%{"value" => true}]})

    refute JSON.metadata?(%TamaMCP.TestSupport.Encodable{secret: "must-not-escape"})

    refute JSON.metadata?(%{
             adapter: %TamaMCP.TestSupport.Encodable{secret: "must-not-escape"}
           })
  end

  test "protocol metadata enforces the MCP key-name grammar" do
    assert JSON.meta_object?(%{
             "progressToken" => 1,
             "example.com/value_name-1" => %{"nested key" => true},
             "io.modelcontextprotocol/serverInfo" => %{}
           })

    for key <- ["bad key", "/name", "1example.com/name", "example-.com/name", "_name"] do
      refute JSON.meta_object?(%{key => true})
    end
  end

  test "extension identifiers require a metadata prefix" do
    assert JSON.extension_identifier?("io.modelcontextprotocol/tasks")
    assert JSON.extension_identifier?("com.example/feature")

    refute JSON.extension_identifier?("tasks")
    refute JSON.extension_identifier?("bad key")
  end
end
