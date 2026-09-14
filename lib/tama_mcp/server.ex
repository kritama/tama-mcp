defmodule TamaMCP.Server do
  @moduledoc """
  Compile-time server DSL.

  An application server declares its identity and compiles its tool catalog at
  build time:

      defmodule Example.Server do
        use TamaMCP.Server,
          name: "example",
          version: "1.0.0",
          instructions: "Use the available tools for bounded example work."

        tool Example.Tools.Inspect, name: "inspect"
        tool Example.Tools.Execute, name: "execute"
      end

  `use TamaMCP.Server` validates the required identity fields and rejects
  duplicate tool names during compilation. The catalog has a stable
  deterministic order (sorted by tool name) independent of module compilation
  order. Tool names are public compatibility APIs.

  The server DSL exposes only MCP `2026-07-28`. Applications cannot widen the
  supported protocol list. The package version and the application server
  version are separate values.
  """

  @doc false
  def __configure__(opts) do
    validate_options!(opts, [:name, :version, :instructions], "server options")
    name = Keyword.get(opts, :name)

    unless is_binary(name) and name != "" do
      raise CompileError, description: "server name is required and must be a non-empty string"
    end

    version = Keyword.get(opts, :version)

    unless is_binary(version) and version != "" do
      raise CompileError, description: "server version is required and must be a non-empty string"
    end

    instructions = Keyword.get(opts, :instructions)

    unless instructions == nil or (is_binary(instructions) and instructions != "") do
      raise CompileError, description: "server instructions must be a non-empty string"
    end

    {name, version, instructions}
  end

  defmacro __using__(opts) do
    {name, version, instructions} = __configure__(opts)

    quote bind_quoted: [
            name: name,
            version: version,
            instructions: instructions
          ] do
      import TamaMCP.Server, only: [tool: 2]

      @tama_mcp_server true
      @tama_mcp_server_name name
      @tama_mcp_server_version version
      @tama_mcp_server_instructions instructions
      @tama_mcp_server_tools []
      @before_compile TamaMCP.Server
    end
  end

  defmacro tool(module_ast, opts) do
    validate_options!(opts, [:name], "tool options")

    name =
      case Keyword.get(opts, :name) do
        name when is_binary(name) and name != "" ->
          name

        other ->
          raise CompileError,
            description:
              "tool name is required and must be a non-empty string, got: #{inspect(other)}"
      end

    tool_module =
      case Macro.expand(module_ast, __CALLER__) do
        atom when is_atom(atom) and not is_nil(atom) ->
          atom

        other ->
          raise CompileError,
            description: "tool must reference a module, got: #{inspect(other)}"
      end

    validate_tool_module!(tool_module, __CALLER__)

    quote bind_quoted: [module: tool_module, name: name] do
      @tama_mcp_server_tools [{name, module} | @tama_mcp_server_tools]
    end
  end

  # Every export the StreamableHTTP transport invokes on a tool module. Kept in
  # one place so the DSL boundary validates the complete runtime-facing contract.
  @tool_contract [
    tool_metadata: 0,
    scopes: 0,
    task_policy: 0,
    definition: 0,
    input_validator: 2,
    output_validator: 2,
    call: 2,
    parameter_headers: 0
  ]

  # `Code.ensure_compiled!/1` tells the parallel compiler the macro cannot
  # continue until this same-project tool module is compiled and loaded. This is
  # the Elixir-supported way to establish the compile dependency a DSL needs; it
  # reports an unavailable module or a compile cycle instead of silently passing.
  @doc false
  def validate_tool_module!(tool_module, caller) do
    Code.ensure_compiled!(tool_module)

    missing =
      Enum.reject(@tool_contract, fn {name, arity} ->
        function_exported?(tool_module, name, arity)
      end)

    if missing != [] do
      formatted = Enum.map_join(missing, ", ", fn {name, arity} -> "#{name}/#{arity}" end)

      raise CompileError,
        file: caller.file,
        line: caller.line,
        description:
          "module #{inspect(tool_module)} is not a compiled TamaMCP tool; missing " <>
            "#{formatted}. Define it with `use TamaMCP.Tool` before registering it on " <>
            "#{inspect(caller.module)}"
    end

    :ok
  end

  defmacro __before_compile__(env) do
    module = env.module

    name = Module.get_attribute(module, :tama_mcp_server_name)
    version = Module.get_attribute(module, :tama_mcp_server_version)
    instructions = Module.get_attribute(module, :tama_mcp_server_instructions)
    tools = Module.get_attribute(module, :tama_mcp_server_tools) || []

    ensure_unique_tool_names!(tools, module)
    catalog = build_catalog(tools)

    quote do
      unquote(server_defs_identity(name, version, instructions, catalog))
      unquote(server_defs_lookup(catalog))
    end
  end

  defp ensure_unique_tool_names!(tools, module) do
    names = Enum.map(tools, &elem(&1, 0))
    duplicates = names -- Enum.uniq(names)

    if duplicates != [] do
      raise CompileError,
        description:
          "duplicate tool name(s) on #{inspect(module)}: #{inspect(Enum.sort(duplicates))}"
    end
  end

  defp validate_options!(opts, allowed, label) do
    unless Keyword.keyword?(opts) do
      raise CompileError, description: "#{label} must be a keyword list"
    end

    keys = Keyword.keys(opts)
    unknown = Enum.reject(keys, &(&1 in allowed))
    duplicates = keys -- Enum.uniq(keys)

    if unknown != [] do
      raise CompileError, description: "unknown #{label}: #{inspect(Enum.uniq(unknown))}"
    end

    if duplicates != [] do
      raise CompileError, description: "duplicate #{label}: #{inspect(Enum.uniq(duplicates))}"
    end
  end

  defp build_catalog(tools) do
    tools
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {tool_name, tool_module} ->
      %{name: tool_name, module: tool_module}
    end)
  end

  defp server_defs_identity(name, version, instructions, catalog) do
    quote do
      @doc "Returns the server name."
      def name, do: unquote(name)

      @doc "Returns the application server version."
      def version, do: unquote(version)

      @doc "Returns the server instructions, or `nil` when none are configured."
      def instructions, do: unquote(instructions)

      @doc """
      Returns the compiled tool catalog in deterministic order.

      Each entry is `%{name: tool_name, module: tool_module}`.
      """
      def tools, do: unquote(Macro.escape(catalog))
    end
  end

  defp server_defs_lookup(catalog) do
    quote do
      @doc "Returns the registered tool names in deterministic order."
      def tool_names, do: unquote(Macro.escape(Enum.map(catalog, & &1.name)))

      @doc "Returns the tool module for an exact tool name, or `nil`."
      def tool(name) do
        case Enum.find(unquote(Macro.escape(catalog)), fn entry -> entry.name == name end) do
          nil -> nil
          entry -> entry.module
        end
      end
    end
  end
end
