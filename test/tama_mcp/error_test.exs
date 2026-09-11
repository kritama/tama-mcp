defmodule TamaMCP.ErrorTest do
  use ExUnit.Case, async: true

  test "constructors reject nil messages instead of encoding null" do
    assert_raise FunctionClauseError, fn -> TamaMCP.Error.parse(nil) end
    assert_raise FunctionClauseError, fn -> TamaMCP.Error.internal(nil) end
  end

  test "encoding omits non-JSON and oversized error data" do
    base = %TamaMCP.Error{code: -32_603, message: "failure", data: %{pid: self()}}
    refute Map.has_key?(TamaMCP.Error.encode(base, 100), "data")

    large = %{base | data: %{"detail" => String.duplicate("x", 100)}}
    refute Map.has_key?(TamaMCP.Error.encode(large, 16), "data")
  end

  test "encoding normalizes malformed manually constructed messages" do
    error = %TamaMCP.Error{code: -32_603, message: nil}
    assert TamaMCP.Error.encode(error)["message"] == "Internal error"
  end
end
