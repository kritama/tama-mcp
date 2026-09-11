defmodule TamaMCP.ToolTest.SideEffects do
  @moduledoc false

  @key {:tama_mcp_tool_test_side_effect, :hit}

  def key, do: @key

  def hit do
    :persistent_term.put(@key, true)
    :string
  end
end

defmodule TamaMCP.ToolTest do
  @moduledoc false

  alias TamaMCP.TestSupport.Tools.Headers
  alias TamaMCP.ToolTest.SideEffects

  use ExUnit.Case

  describe "accepted literal declarations" do
    test "atom names, primitive types, tuple types, and keyword options build a schema" do
      modules =
        Code.compile_string(
          """
          defmodule TamaMCP.ToolTest.LiteralsTool do
            use TamaMCP.Tool,
              task: :optional,
              scopes: ["test.literals"],
              description: "Declares only literal schema values."

            input_schema do
              field(:identifier, :string, required: true, min_length: 1)
              field(:count, :integer, default: 0)
              field(:status, {:enum, ["a", "b"]}, required: true)
              field(:tags, {:array, :string}, default: [])
            end

            output_schema do
              field(:status, {:enum, ["done"]}, required: true)
            end

            @impl true
            def call(_input, _context) do
              {:ok, TamaMCP.Response.success(structured_content: %{"status" => "done"})}
            end
          end
          """,
          "tool_test_literals.exs"
        )

      {mod, _bytecode} = List.keyfind!(modules, TamaMCP.ToolTest.LiteralsTool, 0)
      input = mod.input_schema()

      assert input["type"] == "object"
      assert input["additionalProperties"] == false
      assert input["required"] == ["identifier", "status"]
      assert input["properties"]["identifier"] == %{"type" => "string", "minLength" => 1}
      assert input["properties"]["count"] == %{"type" => "integer", "default" => 0}
      assert input["properties"]["status"] == %{"type" => "string", "enum" => ["a", "b"]}

      assert input["properties"]["tags"] == %{
               "type" => "array",
               "items" => %{"type" => "string"},
               "default" => []
             }

      assert mod.output_schema()["properties"]["status"]["enum"] == ["done"]
    end

    test "raw literal input and output schema maps are accepted" do
      modules =
        Code.compile_string(
          """
          defmodule TamaMCP.ToolTest.RawTool do
            use TamaMCP.Tool

            raw_input_schema(%{
              "type" => "object",
              "properties" => %{"x" => %{"type" => "integer"}},
              "additionalProperties" => false
            })

            raw_output_schema(%{"type" => "object", "properties" => %{}})

            @impl true
            def call(_input, _context) do
              {:ok, TamaMCP.Response.success(structured_content: %{"ok" => true})}
            end
          end
          """,
          "tool_test_raw.exs"
        )

      {mod, _bytecode} = List.keyfind!(modules, TamaMCP.ToolTest.RawTool, 0)
      assert mod.input_schema()["properties"]["x"]["type"] == "integer"
      assert mod.output_schema()["type"] == "object"
    end

    test "raw input schemas compile statically reachable parameter headers" do
      headers = Headers.parameter_headers()

      assert headers == [
               %{
                 header: "mcp-param-enabled",
                 name: "Enabled",
                 path: ["enabled"],
                 type: "boolean"
               },
               %{header: "mcp-param-note", name: "Note", path: ["note"], type: "string"},
               %{header: "mcp-param-region", name: "Region", path: ["region"], type: "string"},
               %{
                 header: "mcp-param-shard",
                 name: "Shard",
                 path: ["routing", "shard"],
                 type: "integer"
               }
             ]
    end

    test "instance-valued schema keywords are not scanned for parameter annotations" do
      schema = %{
        "type" => "object",
        "properties" => %{
          "route" => %{"type" => "string", "x-mcp-header" => "Route"},
          "settings" => %{
            "type" => "object",
            "const" => %{"x-mcp-header" => "literal"},
            "default" => %{"x-mcp-header" => "literal"},
            "examples" => [%{"x-mcp-header" => "literal"}]
          }
        }
      }

      [{module, _bytecode}] = compile_raw_tool(schema)

      assert module.parameter_headers() == [
               %{
                 header: "mcp-param-route",
                 name: "Route",
                 path: ["route"],
                 type: "string"
               }
             ]
    end
  end

  describe "rejected non-literal declarations" do
    test "a successful remote call is rejected before evaluation" do
      assert_raise CompileError, ~r/field type must be a literal.*String\.to_atom/, fn ->
        Code.compile_string(
          """
          defmodule TamaMCP.ToolTest.RemoteCallTool do
            use TamaMCP.Tool
            input_schema do
              field :value, String.to_atom("string")
            end
            def call(_i, _c), do: :ok
          end
          """,
          "tool_test_remote_call.exs"
        )
      end
    end

    test "an operator expression is rejected" do
      assert_raise CompileError, ~r/field type must be a literal/, fn ->
        Code.compile_string(
          """
          defmodule TamaMCP.ToolTest.OpTool do
            use TamaMCP.Tool
            input_schema do
              field :value, "a" <> "b"
            end
            def call(_i, _c), do: :ok
          end
          """,
          "tool_test_op.exs"
        )
      end
    end

    test "a module attribute reference is rejected" do
      assert_raise CompileError, ~r/field type must be a literal.*@t/, fn ->
        Code.compile_string(
          """
          defmodule TamaMCP.ToolTest.AttrTool do
            use TamaMCP.Tool
            @t :string
            input_schema do
              field :v, @t
            end
            def call(_i, _c), do: :ok
          end
          """,
          "tool_test_attr.exs"
        )
      end
    end

    test "a side-effecting call is rejected and never executed" do
      key = SideEffects.key()
      :persistent_term.erase(key)

      assert_raise CompileError, ~r/field type must be a literal/, fn ->
        Code.compile_string(
          """
          defmodule TamaMCP.ToolTest.SideEffectTool do
            use TamaMCP.Tool
            input_schema do
              field :value, TamaMCP.ToolTest.SideEffects.hit()
            end
            def call(_i, _c), do: :ok
          end
          """,
          "tool_test_side_effect.exs"
        )
      end

      refute :persistent_term.get(key, false),
             "a rejected non-literal expression must never be evaluated"
    end
  end

  describe "diagnostics" do
    test "errors point at the caller file, line, component, and rejected expression" do
      error =
        assert_raise CompileError, fn ->
          Code.compile_string(
            """
            defmodule TamaMCP.ToolTest.DiagTool do
              use TamaMCP.Tool
              input_schema do
                field :value, String.to_atom("string")
              end
              def call(_i, _c), do: :ok
            end
            """,
            "tool_test_diag.exs"
          )
        end

      assert error.file == "tool_test_diag.exs"
      assert error.line == 4
      assert Exception.message(error) =~ "field type must be a literal"
      assert Exception.message(error) =~ "String.to_atom"
    end
  end

  describe "strict declarations" do
    test "rejects extra field arguments" do
      assert_raise CompileError, ~r/exactly 2 or 3 arguments/, fn ->
        compile_tool("ExtraField", "field(:value, :string, [], :ignored)")
      end
    end

    test "rejects unknown and duplicate field options" do
      assert_raise CompileError, ~r/unknown field options/, fn ->
        compile_tool("UnknownFieldOption", "field(:value, :string, shortcut: true)")
      end

      assert_raise CompileError, ~r/duplicate field options/, fn ->
        compile_tool(
          "DuplicateFieldOption",
          "field(:value, :string, required: true, required: false)"
        )
      end
    end

    test "rejects non-boolean required and duplicate field names" do
      assert_raise CompileError, ~r/required option must be a boolean/, fn ->
        compile_tool("RequiredType", "field(:value, :string, required: :yes)")
      end

      assert_raise CompileError, ~r/duplicate field name/, fn ->
        compile_tool("DuplicateField", "field(:value, :string)\nfield(:value, :integer)")
      end
    end

    test "rejects repeated schema declarations" do
      assert_raise CompileError, ~r/input_schema may only be declared once/, fn ->
        Code.compile_string(
          """
          defmodule TamaMCP.ToolTest.RepeatedSchema do
            use TamaMCP.Tool
            input_schema do
              field(:first, :string)
            end
            raw_input_schema(%{"type" => "object"})
            def call(_input, _context), do: {:ok, TamaMCP.Response.success()}
          end
          """,
          "tool_test_repeated_schema.exs"
        )
      end
    end

    test "accepts mixed integer and float numeric enums" do
      modules = compile_tool("NumericEnum", "field(:value, {:enum, [1, 2.5]})")
      {module, _bytecode} = List.keyfind!(modules, TamaMCP.ToolTest.NumericEnum, 0)
      assert module.input_schema()["properties"]["value"]["type"] == "number"
    end

    test "rejects invalid parameter-header annotations at compile time" do
      invalid = [
        {%{"type" => "object", "x-mcp-header" => "Root"}, ~r/not statically reachable/},
        {header_schema(""), ~r/non-empty string/},
        {header_schema("bad name"), ~r/field-name token/},
        {header_schema("Count", "number"), ~r/string, integer, or boolean/},
        {
          %{
            "type" => "object",
            "properties" => %{
              "one" => %{"type" => "string", "x-mcp-header" => "Tenant"},
              "two" => %{"type" => "string", "x-mcp-header" => "tenant"}
            }
          },
          ~r/duplicate x-mcp-header/
        },
        {
          %{
            "type" => "object",
            "properties" => %{
              "value" => %{
                "oneOf" => [
                  %{"type" => "string", "x-mcp-header" => "Hidden"}
                ]
              }
            }
          },
          ~r/not statically reachable/
        },
        {
          %{
            "type" => "object",
            "$defs" => %{
              "hidden" => %{"type" => "string", "x-mcp-header" => "Hidden"}
            }
          },
          ~r/not statically reachable/
        }
      ]

      for {schema, message} <- invalid do
        assert_raise CompileError, message, fn -> compile_raw_tool(schema) end
      end
    end
  end

  test "validator cache refreshes when a tool module is recompiled" do
    module = TamaMCP.ToolTest.Reloaded
    original = Code.compiler_options()
    Code.compiler_options(ignore_module_conflict: true)
    on_exit(fn -> Code.compiler_options(original) end)

    compile_reloadable(module, ":string")
    assert :ok = TamaMCP.Schema.validate(TamaMCP.Tool.input_validator(module), %{"value" => "ok"})

    compile_reloadable(module, ":integer")
    assert :ok = TamaMCP.Schema.validate(TamaMCP.Tool.input_validator(module), %{"value" => 1})

    assert {:error, _details} =
             TamaMCP.Schema.validate(TamaMCP.Tool.input_validator(module), %{"value" => "stale"})
  end

  test "schema builder raises the nested error module" do
    assert_raise TamaMCP.Schema.Error, fn -> TamaMCP.Schema.type_schema(:unsupported) end
  end

  defp compile_tool(suffix, fields) do
    Code.compile_string(
      """
      defmodule TamaMCP.ToolTest.#{suffix} do
        use TamaMCP.Tool
        input_schema do
          #{fields}
        end
        def call(_input, _context), do: {:ok, TamaMCP.Response.success()}
      end
      """,
      "tool_test_#{Macro.underscore(suffix)}.exs"
    )
  end

  defp compile_reloadable(module, type) do
    Code.compile_string("""
    defmodule #{inspect(module)} do
      use TamaMCP.Tool
      input_schema do
        field(:value, #{type}, required: true)
      end
      def call(_input, _context), do: {:ok, TamaMCP.Response.success()}
    end
    """)
  end

  defp compile_raw_tool(schema) do
    suffix = System.unique_integer([:positive])

    Code.compile_string("""
    defmodule TamaMCP.ToolTest.RawHeader#{suffix} do
      use TamaMCP.Tool
      raw_input_schema(#{inspect(schema)})
      def call(_input, _context), do: {:ok, TamaMCP.Response.success()}
    end
    """)
  end

  defp header_schema(name, type \\ "string") do
    %{
      "type" => "object",
      "properties" => %{"value" => %{"type" => type, "x-mcp-header" => name}}
    }
  end
end
