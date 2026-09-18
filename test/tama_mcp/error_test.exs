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

  test "encoding rejects directly and recursively embedded encodable structs" do
    struct = %TamaMCP.TestSupport.Encodable{secret: "must-not-escape"}
    assert {:ok, _encoded} = Jason.encode(struct)

    direct = %TamaMCP.Error{code: -32_603, message: "failure", data: struct}
    nested = %{direct | data: %{"nested" => [struct]}}

    refute Map.has_key?(TamaMCP.Error.encode(direct), "data")
    refute Map.has_key?(TamaMCP.Error.encode(nested), "data")
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

  describe "decode/1" do
    test "decodes nil as an explicit absent error" do
      assert {:ok, nil} = TamaMCP.Error.decode(nil)
      assert {:ok, nil} = TamaMCP.Error.decode(nil, 16)
    end

    test "round-trips every constructor without data" do
      errors = [
        TamaMCP.Error.parse(),
        TamaMCP.Error.invalid_request("invalid"),
        TamaMCP.Error.method_not_found("missing"),
        TamaMCP.Error.invalid_params("invalid params"),
        TamaMCP.Error.internal(),
        TamaMCP.Error.header_mismatch("mismatch")
      ]

      for error <- errors do
        assert {:ok, ^error} = TamaMCP.Error.decode(TamaMCP.Error.encode(error))
      end
    end

    test "round-trips bounded JSON-safe data" do
      capability = %{"extensions" => %{TamaMCP.Protocol.tasks_extension() => %{}}}
      missing = TamaMCP.Error.missing_required_client_capability(capability)
      assert {:ok, ^missing} = TamaMCP.Error.decode(TamaMCP.Error.encode(missing))

      unsupported = TamaMCP.Error.unsupported_protocol_version("old")
      assert {:ok, ^unsupported} = TamaMCP.Error.decode(TamaMCP.Error.encode(unsupported))

      direct = %TamaMCP.Error{code: -32_603, message: "failure", data: %{"list" => [1, "two"]}}
      assert {:ok, ^direct} = TamaMCP.Error.decode(TamaMCP.Error.encode(direct))
    end

    test "round-trips a 512-byte message" do
      message = String.duplicate("m", 512)
      error = %TamaMCP.Error{code: -32_603, message: message}
      assert {:ok, ^error} = TamaMCP.Error.decode(TamaMCP.Error.encode(error))
    end

    test "rejects malformed error maps" do
      valid = TamaMCP.Error.encode(TamaMCP.Error.internal())

      for encoded <- [
            %{},
            %{"code" => -32_603},
            %{"message" => "failure"},
            %{"code" => "-32603", "message" => "failure"},
            %{"code" => -32_603.0, "message" => "failure"},
            %{"code" => true, "message" => "failure"},
            %{"code" => nil, "message" => "failure"},
            %{"code" => -32_603, "message" => nil},
            %{"code" => -32_603, "message" => ""},
            %{"code" => -32_603, "message" => <<0xFF, 0xFE, "failure">>},
            %{"code" => -32_603, "message" => String.duplicate("m", 513)},
            Map.put(valid, "unexpected", true),
            %{:code => -32_603, :message => "failure"}
          ] do
        assert {:error, :invalid_error} = TamaMCP.Error.decode(encoded)
      end
    end

    test "rejects unsafe or non-object data" do
      base = %{"code" => -32_603, "message" => "failure"}

      for data <- [
            ["an array"],
            %{pid: self()},
            %{"nested" => [make_ref()]},
            %TamaMCP.TestSupport.Encodable{secret: "no"},
            %{1 => "integer key"}
          ] do
        assert {:error, :invalid_error} = TamaMCP.Error.decode(Map.put(base, "data", data))
      end
    end

    test "rejects data beyond the byte bound" do
      base = %{"code" => -32_603, "message" => "failure"}
      oversized = Map.put(base, "data", %{"detail" => String.duplicate("x", 100)})
      assert {:error, :invalid_error} = TamaMCP.Error.decode(oversized, 16)

      assert {:ok, %TamaMCP.Error{data: %{"detail" => _}}} =
               TamaMCP.Error.decode(oversized, 8_192)
    end
  end
end
