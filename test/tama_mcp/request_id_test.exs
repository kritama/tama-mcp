defmodule TamaMCP.RequestIDTest do
  use ExUnit.Case, async: true

  alias TamaMCP.RequestID

  doctest TamaMCP.RequestID

  describe "encode/1" do
    test "tags string and integer identity" do
      assert RequestID.encode("42") == %{"type" => "string", "value" => "42"}
      assert RequestID.encode(42) == %{"type" => "integer", "value" => 42}
      assert RequestID.encode("") == %{"type" => "string", "value" => ""}
      assert RequestID.encode(0) == %{"type" => "integer", "value" => 0}
    end

    test "encodes protocol boundary integers exactly" do
      boundary = [
        -32_700,
        -32_603,
        -2_147_483_648,
        2_147_483_647,
        -4_294_967_296,
        4_294_967_295,
        -9_223_372_036_854_775_808,
        9_223_372_036_854_775_807
      ]

      for id <- boundary do
        assert {:ok, ^id} = RequestID.decode(RequestID.encode(id))
      end
    end
  end

  describe "decode/1" do
    test "round-trips strings and integers without type coercion" do
      assert {:ok, "42"} = RequestID.decode(%{"type" => "string", "value" => "42"})
      assert {:ok, 42} = RequestID.decode(%{"type" => "integer", "value" => 42})

      assert {:ok, "conformance-request"} =
               RequestID.decode(%{"type" => "string", "value" => "conformance-request"})

      assert {:ok, -32_700} = RequestID.decode(%{"type" => "integer", "value" => -32_700})
    end

    test "rejects untagged and mistyped values" do
      for value <- [
            nil,
            true,
            false,
            42,
            42.0,
            "42",
            ["42"],
            %{"nested" => "map"},
            :an_atom
          ] do
        assert {:error, :invalid_request_id} = RequestID.decode(value)
      end
    end

    test "rejects malformed tagged maps" do
      for tagged <- [
            %{"value" => "42"},
            %{"type" => "str", "value" => "42"},
            %{"type" => "boolean", "value" => true},
            %{"type" => "float", "value" => 42.0},
            %{"type" => "string", "value" => 42},
            %{"type" => "integer", "value" => "42"},
            %{"type" => "integer", "value" => 42.0},
            %{"type" => "integer", "value" => true},
            %{"type" => "string", "value" => ["42"]},
            %{"type" => "string", "value" => %{"value" => "42"}},
            %{"type" => "string", "value" => nil},
            %{"type" => "integer", "value" => 42, "extra" => true},
            %{:type => "integer", :value => 42},
            %{"type" => "integer", "value" => 42, :extra => true}
          ] do
        assert {:error, :invalid_request_id} = RequestID.decode(tagged)
      end
    end

    test "rejects invalid UTF-8 string values" do
      assert {:error, :invalid_request_id} =
               RequestID.decode(%{"type" => "string", "value" => <<0xFF, 0xFE, "id">>})
    end

    test "never creates atoms from persisted input" do
      assert {:ok, value} =
               RequestID.decode(%{"type" => "string", "value" => "a brand new value"})

      assert is_binary(value)
    end
  end
end
