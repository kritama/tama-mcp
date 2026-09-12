defmodule TamaMCP.SchemaTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias TamaMCP.Schema

  test "compiles schemas and returns bounded errors for invalid schemas" do
    assert {:ok, compiled} = Schema.compile(%{"type" => "string"})
    assert :ok = Schema.validate(compiled, "value")
    assert {:error, [detail]} = Schema.validate(compiled, 1)
    refute detail =~ "\n"

    assert {:error, reason} = Schema.compile(%{"type" => "not-a-json-schema-type"})
    assert reason =~ "invalid JSON schema"
  end

  test "accepts Draft 2020-12 schemas and rejects unsupported explicit dialects" do
    for dialect <- [
          "https://json-schema.org/draft/2020-12/schema",
          "https://json-schema.org/draft/2020-12/schema#"
        ] do
      assert {:ok, _compiled} = Schema.compile(%{"$schema" => dialect, "type" => "string"})
    end

    assert {:error, reason} =
             Schema.compile(%{
               "$schema" => "http://json-schema.org/draft-07/schema#",
               "type" => "object"
             })

    assert reason =~ "unsupported JSON Schema dialect"
    assert reason =~ "Draft 2020-12 only"
  end

  test "checks nested schemas without interpreting instance-valued keywords" do
    assert {:error, reason} =
             Schema.compile(%{
               "type" => "object",
               "$defs" => %{
                 "legacy" => %{
                   "$schema" => "http://json-schema.org/draft-07/schema#",
                   "type" => "string"
                 }
               }
             })

    assert reason =~ "unsupported JSON Schema dialect"

    assert {:ok, _compiled} =
             Schema.compile(%{
               "const" => %{"$schema" => "http://json-schema.org/draft-07/schema#"}
             })
  end

  test "builds raw, array, and object schemas with explicit openness" do
    raw = %{"type" => "object", "required" => ["id"]}
    assert Schema.type_schema({:raw, raw}) == raw
    assert Schema.type_schema({:raw, %{}}) == %{}

    assert Schema.type_schema({:array, :boolean}) == %{
             "type" => "array",
             "items" => %{"type" => "boolean"}
           }

    schema =
      Schema.build_object_schema([{:id, :integer, [required: true]}], allow_unknown_keys: true)

    assert schema["additionalProperties"] == true
    assert schema["required"] == ["id"]
  end

  test "validates enum shapes" do
    assert Schema.type_schema({:enum, [2, 1]}) == %{"type" => "integer", "enum" => [1, 2]}

    assert_raise Schema.Error, ~r/non-empty/, fn -> Schema.type_schema({:enum, []}) end

    assert_raise Schema.Error, ~r/all be strings/, fn ->
      Schema.type_schema({:enum, ["one", 2]})
    end
  end

  test "validates field option applicability and values" do
    assert Schema.field_schema(:string, min_length: 0, max_length: 3, pattern: "^[a-z]+$") == %{
             "type" => "string",
             "minLength" => 0,
             "maxLength" => 3,
             "pattern" => "^[a-z]+$"
           }

    assert Schema.field_schema(:number, min: 1, max: 2.5) == %{
             "type" => "number",
             "minimum" => 1,
             "maximum" => 2.5
           }

    assert_raise Schema.Error, ~r/non-negative/, fn ->
      Schema.field_schema(:string, min_length: -1)
    end

    assert_raise Schema.Error, ~r/applies only to string/, fn ->
      Schema.field_schema(:integer, min_length: 1)
    end

    assert_raise Schema.Error, ~r/must be numeric/, fn ->
      Schema.field_schema(:integer, min: "one")
    end

    assert_raise Schema.Error, ~r/apply only to number/, fn ->
      Schema.field_schema(:string, min: 1)
    end

    assert_raise Schema.Error, ~r/pattern applies only/, fn ->
      Schema.field_schema(:integer, pattern: "x")
    end
  end

  test "distinguishes an omitted default from an explicit JSON null default" do
    type = {:raw, %{"type" => ["string", "null"]}}

    refute Map.has_key?(Schema.field_schema(type), "default")
    assert Map.fetch!(Schema.field_schema(type, default: nil), "default") == nil
  end
end
