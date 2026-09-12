defmodule TamaMCP.ServerTest do
  @moduledoc false

  use ExUnit.Case

  alias TamaMCP.TestSupport.Server
  alias TamaMCP.TestSupport.Tools

  describe "tool/2 catalog (positive, separate support files)" do
    test "compiles the support tools and server into a deterministic catalog" do
      assert Server.name() == "tama-mcp-test"
      assert Server.version() == "0.0.1-test"

      assert Server.tool_names() == [
               "context",
               "echo",
               "failing",
               "headers",
               "invalid",
               "invalid_output",
               "null",
               "protocol_failing",
               "result",
               "slow"
             ]

      assert Server.tools() == [
               %{name: "context", module: Tools.Context},
               %{name: "echo", module: Tools.Echo},
               %{name: "failing", module: Tools.Failing},
               %{name: "headers", module: Tools.Headers},
               %{name: "invalid", module: Tools.Invalid},
               %{name: "invalid_output", module: Tools.InvalidOutput},
               %{name: "null", module: Tools.Null},
               %{name: "protocol_failing", module: Tools.ProtocolFailing},
               %{name: "result", module: Tools.Result},
               %{name: "slow", module: Tools.Slow}
             ]
    end

    test "server.tool/1 resolves an exact name and misses unknown names" do
      assert Server.tool("echo") == Tools.Echo
      assert Server.tool("protocol_failing") == Tools.ProtocolFailing
      assert Server.tool("unknown") == nil
    end
  end

  describe "tool/2 compile-time contract (negative)" do
    test "missing and malformed server identity fails at compile time" do
      assert_raise CompileError, ~r/server name is required/, fn ->
        Code.compile_string(~S"""
        defmodule TamaMCP.ServerTest.NoName do
          use TamaMCP.Server, version: "1"
        end
        """)
      end

      assert_raise CompileError, ~r/server version is required/, fn ->
        Code.compile_string(~S"""
        defmodule TamaMCP.ServerTest.NoVersion do
          use TamaMCP.Server, name: "x"
        end
        """)
      end

      assert_raise CompileError, ~r/server instructions/, fn ->
        Code.compile_string(~S"""
        defmodule TamaMCP.ServerTest.BadInstructions do
          use TamaMCP.Server, name: "x", version: "1", instructions: 1
        end
        """)
      end
    end

    test "unknown and duplicate server options fail at compile time" do
      assert_raise CompileError, ~r/unknown server options/, fn ->
        Code.compile_string(~S"""
        defmodule TamaMCP.ServerTest.UnknownOption do
          use TamaMCP.Server, name: "x", version: "1", shortcut: true
        end
        """)
      end

      assert_raise CompileError, ~r/duplicate server options/, fn ->
        Code.compile_string(~S"""
        defmodule TamaMCP.ServerTest.DuplicateOption do
          use TamaMCP.Server, name: "x", name: "y", version: "1"
        end
        """)
      end
    end

    test "a module that does not exist fails server compilation via Code.ensure_compiled!/1" do
      assert_raise ArgumentError, ~r/could not load module/, fn ->
        Code.compile_string(
          server_source("TamaMCP.ServerTest.MissingServer", "TamaMCP.ServerTest.MissingTool"),
          "server_test_missing.exs"
        )
      end
    end

    test "a compiled module without the tool contract fails at the tool declaration" do
      Code.compile_string(
        """
        defmodule TamaMCP.ServerTest.NotATool do
          def hi, do: :there
        end
        """,
        "server_test_not_a_tool.exs"
      )

      assert_raise CompileError, ~r/not a compiled TamaMCP tool; missing tool_metadata\/0/, fn ->
        Code.compile_string(
          server_source("TamaMCP.ServerTest.BadServer", "TamaMCP.ServerTest.NotATool"),
          "server_test_bad.exs"
        )
      end
    end

    test "a partially spoofed module missing call/2 fails at compile time" do
      Code.compile_string(
        """
        defmodule TamaMCP.ServerTest.PartialTool do
          def tool_metadata, do: %{name: "partial"}
          def task_policy, do: :disabled
          def definition, do: %{"inputSchema" => %{}}
          def input_validator(_cache, _options), do: nil
          def output_validator(_cache, _options), do: nil
        end
        """,
        "server_test_partial_tool.exs"
      )

      error =
        assert_raise CompileError, ~r/missing .*call\/2/, fn ->
          Code.compile_string(
            server_source("TamaMCP.ServerTest.PartialServer", "TamaMCP.ServerTest.PartialTool"),
            "server_test_partial.exs"
          )
        end

      assert Exception.message(error) =~ "missing call/2"
    end

    test "duplicate tool names fail during __before_compile__/1" do
      assert_raise CompileError, ~r/duplicate tool name/, fn ->
        Code.compile_string(
          """
          defmodule TamaMCP.ServerTest.DupServer do
            use TamaMCP.Server, name: "dup", version: "1.0.0"
            tool TamaMCP.TestSupport.Tools.Echo, name: "dup"
            tool TamaMCP.TestSupport.Tools.Echo, name: "dup"
          end
          """,
          "server_test_dup.exs"
        )
      end
    end
  end

  defp server_source(server_module, tool_module) do
    """
    defmodule #{server_module} do
      use TamaMCP.Server, name: "probe", version: "0.0.1"
      tool #{tool_module}, name: "probe_tool"
    end
    """
  end
end
