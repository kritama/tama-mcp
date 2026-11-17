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

  test "returns bounded errors for malformed keyword values instead of raising" do
    assert {:error, "invalid JSON schema: Keyword '$ref' must be a string, got: 5"} =
             Schema.compile(%{"$ref" => 5})

    assert {:error, "invalid JSON schema: malformed schema keyword value"} =
             Schema.compile(%{"type" => "array", "items" => [%{"type" => "string"}]})
  end

  test "fails closed at validation for unresolved and remote references" do
    for ref <- ["#/$defs/missing", "https://tama.test/schemas/remote.json"] do
      assert {:ok, compiled} = Schema.compile(%{"$ref" => ref})
      assert {:error, ["Reference not found: " <> ^ref]} = Schema.validate(compiled, %{})
    end
  end

  test "renders array indices in nested error locations as decimal segments" do
    {:ok, compiled} =
      Schema.compile(%{
        "type" => "object",
        "properties" => %{
          "rows" => %{
            "type" => "array",
            "items" => %{
              "type" => "object",
              "properties" => %{"tags" => %{"type" => "array", "items" => %{"type" => "string"}}}
            }
          }
        }
      })

    for index <- [0, 200, 300] do
      rows = List.duplicate(%{}, index) ++ [%{"tags" => ["ok", 7]}]

      assert {:error, [detail]} = Schema.validate(compiled, %{"rows" => rows})
      assert detail == "At /rows/#{index}/tags/1: Expected type string, got integer"
      assert String.valid?(detail)
      assert {:ok, _json} = Jason.encode([detail])
    end

    {:ok, top_level} = Schema.compile(%{"type" => "array", "items" => %{"type" => "string"}})

    assert {:error, ["At /1: Expected type string, got integer"]} =
             Schema.validate(top_level, ["ok", 1])

    {:ok, named} =
      Schema.compile(%{
        "properties" => %{"a" => %{"properties" => %{"b" => %{"type" => "null"}}}}
      })

    assert {:error, ["At /a/b: Expected type null, got integer"]} =
             Schema.validate(named, %{"a" => %{"b" => 1}})
  end

  test "resolves local, recursive, anchored, embedded, and dynamic references" do
    {:ok, local} =
      Schema.compile(%{
        "$schema" => "https://json-schema.org/draft/2020-12/schema",
        "$defs" => %{
          "positive" => %{"type" => "integer", "minimum" => 1},
          "item" => %{
            "type" => "object",
            "properties" => %{"count" => %{"$ref" => "#/$defs/positive"}},
            "required" => ["count"]
          }
        },
        "$ref" => "#/$defs/item"
      })

    assert :ok = Schema.validate(local, %{"count" => 2})
    assert {:error, [detail]} = Schema.validate(local, %{"count" => 0})
    assert detail =~ "/count"
    assert {:error, [_detail]} = Schema.validate(local, %{})

    {:ok, sibling} =
      Schema.compile(%{
        "$defs" => %{"text" => %{"type" => "string"}},
        "$ref" => "#/$defs/text",
        "minLength" => 3
      })

    assert :ok = Schema.validate(sibling, "abc")
    assert {:error, _details} = Schema.validate(sibling, "ab")

    {:ok, recursive} =
      Schema.compile(%{
        "$defs" => %{
          "node" => %{
            "type" => "object",
            "properties" => %{
              "value" => %{"type" => "integer"},
              "children" => %{"type" => "array", "items" => %{"$ref" => "#/$defs/node"}}
            },
            "additionalProperties" => false
          }
        },
        "$ref" => "#/$defs/node"
      })

    assert :ok = Schema.validate(recursive, %{"value" => 1, "children" => [%{"value" => 2}]})

    assert {:error, [detail]} =
             Schema.validate(recursive, %{"children" => [%{"children" => [%{"value" => "x"}]}]})

    assert detail =~ "/children/0/children/0/value"

    {:ok, anchored} =
      Schema.compile(%{
        "$defs" => %{"number" => %{"$anchor" => "number", "type" => "number"}},
        "properties" => %{"value" => %{"$ref" => "#number"}}
      })

    assert :ok = Schema.validate(anchored, %{"value" => 1.5})
    assert {:error, _details} = Schema.validate(anchored, %{"value" => "x"})

    {:ok, embedded} =
      Schema.compile(%{
        "$id" => "https://tama.test/schemas/root",
        "$defs" => %{"flag" => %{"$id" => "flag", "type" => "boolean"}},
        "properties" => %{"enabled" => %{"$ref" => "flag"}}
      })

    assert :ok = Schema.validate(embedded, %{"enabled" => true})
    assert {:error, _details} = Schema.validate(embedded, %{"enabled" => 1})

    {:ok, dynamic} =
      Schema.compile(%{
        "$id" => "https://tama.test/schemas/tree",
        "$dynamicAnchor" => "node",
        "type" => "object",
        "properties" => %{
          "children" => %{"type" => "array", "items" => %{"$dynamicRef" => "#node"}}
        }
      })

    assert :ok = Schema.validate(dynamic, %{"children" => [%{"children" => []}]})
    assert {:error, _details} = Schema.validate(dynamic, %{"children" => [1]})
  end

  test "rejects non-JSON terms anywhere in a schema" do
    invalid = [
      %{"type" => "object", "const" => :ok},
      %{"type" => "object", "properties" => %{"value" => %{type: "string"}}}
    ]

    for schema <- invalid do
      assert {:error, reason} = Schema.compile(schema)
      assert reason == "JSON Schema must contain only JSON values and UTF-8 string keys"
    end
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

  test "preserves required field declaration order" do
    schema =
      Schema.build_object_schema([
        {:z, :string, [required: true]},
        {:optional, :string, []},
        {:a, :string, [required: true]}
      ])

    assert schema["required"] == ["z", "a"]
  end

  test "builds object, nullable, and recursively composed field types" do
    assert Schema.type_schema(:object) == %{"type" => "object"}

    assert Schema.type_schema({:array, :object}) == %{
             "type" => "array",
             "items" => %{"type" => "object"}
           }

    assert Schema.type_schema({:nullable, {:array, :object}}) == %{
             "anyOf" => [
               %{"type" => "array", "items" => %{"type" => "object"}},
               %{"type" => "null"}
             ]
           }

    assert Schema.type_schema(
             {:object, [{:identifier, :string, [required: true, min_length: 1]}], false}
           ) == %{
             "type" => "object",
             "properties" => %{
               "identifier" => %{"type" => "string", "minLength" => 1}
             },
             "required" => ["identifier"],
             "additionalProperties" => false
           }
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

  test "applies type-specific constraints to nullable primitive fields" do
    string_schema =
      Schema.field_schema({:nullable, :string},
        min_length: 2,
        max_length: 4,
        pattern: "^[a-z]+$"
      )

    assert string_schema == %{
             "anyOf" => [%{"type" => "string"}, %{"type" => "null"}],
             "minLength" => 2,
             "maxLength" => 4,
             "pattern" => "^[a-z]+$"
           }

    assert {:ok, string_validator} = Schema.compile(string_schema)
    assert :ok = Schema.validate(string_validator, nil)
    assert :ok = Schema.validate(string_validator, "word")
    assert {:error, _details} = Schema.validate(string_validator, "a")
    assert {:error, _details} = Schema.validate(string_validator, "UP")

    number_schema = Schema.field_schema({:nullable, :number}, min: 1, max: 2.5)

    assert number_schema == %{
             "anyOf" => [%{"type" => "number"}, %{"type" => "null"}],
             "minimum" => 1,
             "maximum" => 2.5
           }

    assert {:ok, number_validator} = Schema.compile(number_schema)
    assert :ok = Schema.validate(number_validator, nil)
    assert :ok = Schema.validate(number_validator, 1.5)
    assert {:error, _details} = Schema.validate(number_validator, 0)

    assert_raise Schema.Error, ~r/applies only to string/, fn ->
      Schema.field_schema({:nullable, :integer}, min_length: 1)
    end

    assert_raise Schema.Error, ~r/apply only to number/, fn ->
      Schema.field_schema({:nullable, :string}, min: 1)
    end
  end

  test "distinguishes an omitted default from an explicit JSON null default" do
    type = {:raw, %{"type" => ["string", "null"]}}

    refute Map.has_key?(Schema.field_schema(type), "default")
    assert Map.fetch!(Schema.field_schema(type, default: nil), "default") == nil
  end
end
