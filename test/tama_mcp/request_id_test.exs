defmodule TamaMCP.RequestIDTest do
  use ExUnit.Case, async: true

  alias TamaMCP.RequestID

  doctest TamaMCP.RequestID

  describe "encode/1" do
    test "tags string and integer identity" do
      assert {:ok, %{"type" => "string", "value" => "42"}} = RequestID.encode("42")
      assert {:ok, %{"type" => "integer", "value" => 42}} = RequestID.encode(42)
      assert {:ok, %{"type" => "string", "value" => ""}} = RequestID.encode("")
      assert {:ok, %{"type" => "integer", "value" => 0}} = RequestID.encode(0)
    end

    test "rejects values that cannot round-trip through decode/1" do
      for id <- [
            <<0xFF, 0xFE, "id">>,
            String.duplicate("a", RequestID.max_string_bytes() + 1),
            nil,
            true,
            42.0,
            ["42"]
          ] do
        assert {:error, :invalid_request_id} = RequestID.encode(id)
      end

      boundary = String.duplicate("a", RequestID.max_string_bytes())
      assert {:ok, %{"value" => ^boundary}} = RequestID.encode(boundary)
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
        assert {:ok, encoded} = RequestID.encode(id)
        assert {:ok, ^id} = RequestID.decode(encoded)
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

    test "enforces the shared byte bound on string values" do
      assert 512 = RequestID.max_string_bytes()

      boundary = String.duplicate("a", RequestID.max_string_bytes())

      assert {:ok, ^boundary} =
               RequestID.decode(%{"type" => "string", "value" => boundary})

      oversized = String.duplicate("a", RequestID.max_string_bytes() + 1)

      assert {:error, :invalid_request_id} =
               RequestID.decode(%{"type" => "string", "value" => oversized})

      multibyte_boundary = String.duplicate("é", div(RequestID.max_string_bytes(), 2))
      assert byte_size(multibyte_boundary) == RequestID.max_string_bytes()

      assert {:ok, ^multibyte_boundary} =
               RequestID.decode(%{"type" => "string", "value" => multibyte_boundary})

      assert {:error, :invalid_request_id} =
               RequestID.decode(%{
                 "type" => "string",
                 "value" => String.duplicate("é", div(RequestID.max_string_bytes(), 2) + 1)
               })
    end

    test "never creates atoms from persisted input" do
      unique = "a brand new value #{System.unique_integer([:positive])}"

      assert {:ok, value} = RequestID.decode(%{"type" => "string", "value" => unique})

      assert is_binary(value)

      assert_raise(ArgumentError, fn ->
        String.to_existing_atom(value)
      end)
    end
  end
end
