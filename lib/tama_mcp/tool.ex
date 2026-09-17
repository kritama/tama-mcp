defmodule TamaMCP.Tool do
  @moduledoc """
  Compile-time tool DSL.

  A tool declares metadata, task policy, schemas, and a `call/2` callback.
  Schema blocks accept literal field, nested object, and output variant
  declarations. Every declared object defaults to `additionalProperties:
  false`.
  """

  alias TamaMCP.Cache.Validator
  alias TamaMCP.Tool.Compiler

  @callback call(input :: map(), context :: TamaMCP.Context.t()) ::
              {:ok, TamaMCP.Response.t()} | {:error, TamaMCP.Error.t()}

  defmodule Metadata do
    @moduledoc "Compiled metadata and wire schemas for a tool."

    @type header :: %{
            header: String.t(),
            name: String.t(),
            path: [String.t()],
            type: String.t()
          }

    defstruct [
      :task,
      :scopes,
      :description,
      :title,
      :annotations,
      :headers,
      :input_schema,
      :output_schema
    ]

    @type t :: %__MODULE__{
            task: :disabled | :optional | :required,
            scopes: [String.t()],
            description: String.t() | nil,
            title: String.t() | nil,
            annotations: map() | nil,
            headers: [header()],
            input_schema: map(),
            output_schema: map() | nil
          }
  end

  @doc """
  Declares a tool at compile time.

  Registers the `TamaMCP.Tool` behaviour and generates the compiled metadata,
  wire schemas, and helper functions consumed by `TamaMCP.Server` when the tool
  is listed. Schema bodies are declared with `input_schema/2`,
  `output_schema/2`, `raw_input_schema/1`, and `raw_output_schema/1`; the tool
  logic is the required `call/2` callback.

  ## Options

    * `:task` - task execution policy, one of `:disabled` (default), `:optional`,
      or `:required`.
    * `:scopes` - list of unique OAuth scope tokens required to call the tool
      (default `[]`).
    * `:description` - optional non-empty string shown in `tools/list`.
    * `:title` - optional non-empty human-readable tool title.
    * `:annotations` - keyword list of MCP tool annotations. `:title` accepts a
      non-empty string; the hints `:readOnlyHint`, `:destructiveHint`,
      `:idempotentHint`, and `:openWorldHint` accept booleans. An empty list
      compiles to no annotations.

  Any invalid option raises a `CompileError` with a bounded description.

  ## Example

      defmodule Example.Tools.Echo do
        use TamaMCP.Tool,
          task: :disabled,
          scopes: ["example.echo"],
          description: "Echoes the provided message back to the caller.",
          annotations: [readOnlyHint: true, idempotentHint: true]

        input_schema do
          field(:message, :string, required: true, min_length: 1)
        end

        @impl true
        def call(%{"message" => message}, _context) do
          {:ok,
           TamaMCP.Response.success(
             content: [TamaMCP.Response.text(message)],
             structured_content: %{"message" => message}
           )}
        end
      end
  """
  defmacro __using__(opts) do
    {task, scopes, description, title, annotations} = __configure__(opts)

    quote bind_quoted: [
            task: task,
            scopes: scopes,
            description: description,
            title: title,
            annotations: Macro.escape(annotations)
          ] do
      import TamaMCP.Tool,
        only: [
          input_schema: 1,
          input_schema: 2,
          output_schema: 1,
          output_schema: 2,
          raw_input_schema: 1,
          raw_output_schema: 1
        ]

      @behaviour TamaMCP.Tool
      @tama_mcp_tool true
      @tama_mcp_task task
      @tama_mcp_scopes scopes
      @tama_mcp_description description
      @tama_mcp_title title
      @tama_mcp_annotations annotations
      @tama_mcp_input_schema nil
      @tama_mcp_output_schema nil
      @before_compile TamaMCP.Tool
    end
  end

  @doc false
  def __configure__(opts), do: Compiler.configure(opts)

  defmacro input_schema(opts \\ [], do: block) do
    Compiler.ensure_schema_available!(__CALLER__, :input)
    schema_opts = Compiler.schema_options!(opts, __CALLER__, "input_schema")
    schema = Compiler.collect_schema(block, schema_opts, :input, __CALLER__)

    quote do
      @tama_mcp_input_schema unquote(Macro.escape(schema))
    end
  end

  defmacro output_schema(opts \\ [], do: block) do
    Compiler.ensure_schema_available!(__CALLER__, :output)
    schema_opts = Compiler.schema_options!(opts, __CALLER__, "output_schema")
    schema = Compiler.collect_schema(block, schema_opts, :output, __CALLER__)

    quote do
      @tama_mcp_output_schema unquote(Macro.escape(schema))
    end
  end

  defmacro raw_input_schema(schema) do
    Compiler.ensure_schema_available!(__CALLER__, :input)
    schema = Compiler.literal_schema!(schema, "raw_input_schema", __CALLER__)

    quote do
      @tama_mcp_input_schema {:raw, unquote(Macro.escape(schema))}
    end
  end

  defmacro raw_output_schema(schema) do
    Compiler.ensure_schema_available!(__CALLER__, :output)
    schema = Compiler.literal_schema!(schema, "raw_output_schema", __CALLER__)

    quote do
      @tama_mcp_output_schema {:raw, unquote(Macro.escape(schema))}
    end
  end

  defmacro __before_compile__(env), do: Compiler.before_compile(env)

  @doc false
  def input_validator(module, cache, cache_options \\ []) do
    module.input_validator(cache, cache_options)
  end

  @doc false
  def output_validator(module, cache, cache_options \\ []) do
    module.output_validator(cache, cache_options)
  end

  @doc false
  def __validator__(nil, _cache, _cache_options), do: nil

  def __validator__(artifact, cache, cache_options) do
    Validator.fetch(artifact, cache, cache_options)
  end
end
