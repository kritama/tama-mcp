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

  test "constructors expose stable codes, reasons, statuses, and bounded messages" do
    errors = [
      TamaMCP.Error.parse(),
      TamaMCP.Error.invalid_request("invalid"),
      TamaMCP.Error.method_not_found("missing"),
      TamaMCP.Error.invalid_params("invalid params"),
      TamaMCP.Error.internal(),
      TamaMCP.Error.header_mismatch("mismatch")
    ]

    assert Enum.map(errors, &TamaMCP.Error.reason/1) == [
             :parse_error,
             :invalid_request,
             :method_not_found,
             :invalid_params,
             :internal_error,
             :header_mismatch
           ]

    assert Enum.map(errors, &TamaMCP.Error.status/1) == [400, 400, 404, 400, 500, 400]

    encoded =
      %TamaMCP.Error{code: -32_603, message: String.duplicate("é", 400)}
      |> TamaMCP.Error.encode()

    assert byte_size(encoded["message"]) <= 512
    assert String.valid?(encoded["message"])
  end

  test "capability and version errors include safe protocol data" do
    capability = %{"extensions" => %{TamaMCP.Protocol.tasks_extension() => %{}}}
    missing = TamaMCP.Error.missing_required_client_capability(capability)

    assert missing.code == -32_021
    assert missing.data == %{"requiredCapabilities" => capability}
    assert missing.message =~ "extensions"

    custom = TamaMCP.Error.missing_required_client_capability(capability, "required")
    assert custom.message == "required"

    unsupported = TamaMCP.Error.unsupported_protocol_version("old")
    assert unsupported.data == %{"requested" => "old", "supported" => ["2026-07-28"]}
  end

  test "unknown error codes fail closed as internal failures" do
    error = %TamaMCP.Error{code: 123, message: "unknown"}
    assert TamaMCP.Error.reason(error) == :unknown
    assert TamaMCP.Error.status(error) == 500
  end
end
