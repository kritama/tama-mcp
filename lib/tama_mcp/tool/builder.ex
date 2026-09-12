defmodule TamaMCP.Tool.Builder do
  @moduledoc false

  alias TamaMCP.Schema
  alias TamaMCP.Tool.{Headers, Metadata}

  def before_compile(env) do
    attributes = attributes(env.module)
    {input, input_validator} = compile_schema!(attributes.input, :input, env)
    {output, output_validator} = compile_schema!(attributes.output, :output, env)
    headers = compile_headers!(input, env)

    metadata = %Metadata{
      task: attributes.task,
      scopes: attributes.scopes,
      description: attributes.description,
      title: attributes.title,
      annotations: attributes.annotations,
      headers: headers,
      input_schema: input,
      output_schema: output
    }

    definition = definition(attributes, input, output)
    ensure_callback!(env)

    quote do
      unquote(
        schema_functions(
          metadata,
          input,
          output,
          input_validator,
          output_validator,
          headers,
          attributes.task,
          definition
        )
      )

      unquote(policy_functions(attributes.scopes, attributes.annotations))
    end
  end

  defp attributes(module) do
    %{
      task: Module.get_attribute(module, :tama_mcp_task),
      scopes: Module.get_attribute(module, :tama_mcp_scopes),
      description: Module.get_attribute(module, :tama_mcp_description),
      title: Module.get_attribute(module, :tama_mcp_title),
      annotations: Module.get_attribute(module, :tama_mcp_annotations),
      input: Module.get_attribute(module, :tama_mcp_input_schema),
      output: Module.get_attribute(module, :tama_mcp_output_schema)
    }
  end

  defp compile_schema!(nil, :output, _env), do: {nil, nil}

  defp compile_schema!(nil, :input, _env) do
    schema = %{"type" => "object", "properties" => %{}, "additionalProperties" => false}
    {schema, compile!(schema, "default input schema")}
  end

  defp compile_schema!({allow_unknown?, fields}, kind, env) when is_boolean(allow_unknown?) do
    schema = Schema.build_object_schema(fields, allow_unknown_keys: allow_unknown?)
    validate_root!(schema, kind, env)
    {schema, compile!(schema, "#{kind} schema")}
  end

  defp compile_schema!({:raw, schema}, kind, env) do
    if kind == :input, do: validate_root!(schema, kind, env)
    {schema, compile!(schema, "#{kind} schema")}
  end

  defp validate_root!(schema, kind, env) do
    unless Map.get(schema, "type") == "object" do
      compile_error!(
        env,
        ~s|the #{kind} schema root must be a JSON object ("type" => "object"), got: | <>
          inspect(Map.get(schema, "type"))
      )
    end
  end

  defp compile!(schema, label) do
    case Schema.compile(schema) do
      {:ok, compiled} -> :erlang.term_to_binary(compiled, [:deterministic])
      {:error, reason} -> raise CompileError, description: "invalid #{label}: #{reason}"
    end
  end

  defp compile_headers!(schema, env) do
    case Headers.extract(schema) do
      {:ok, headers} -> headers
      {:error, reason} -> compile_error!(env, "invalid input schema: #{reason}")
    end
  end

  defp ensure_callback!(env) do
    unless Module.defines?(env.module, {:call, 2}) do
      compile_error!(
        env,
        "#{inspect(env.module)} defines a TamaMCP tool but does not implement call/2"
      )
    end
  end

  defp definition(attributes, input, output) do
    %{"inputSchema" => input}
    |> put("description", attributes.description)
    |> put("title", attributes.title)
    |> put("annotations", attributes.annotations)
    |> put("outputSchema", output)
  end

  defp put(map, _key, nil), do: map
  defp put(map, key, value), do: Map.put(map, key, value)

  defp schema_functions(
         metadata,
         input,
         output,
         input_validator,
         output_validator,
         headers,
         task,
         definition
       ) do
    quote do
      @doc false
      def tool_metadata, do: unquote(Macro.escape(metadata))
      @doc false
      def input_schema, do: unquote(Macro.escape(input))
      @doc false
      def output_schema, do: unquote(Macro.escape(output))
      @doc false
      def parameter_headers, do: unquote(Macro.escape(headers))
      @doc false
      def task_policy, do: unquote(task)
      @doc false
      def definition, do: unquote(Macro.escape(definition))
      @doc false
      def input_validator(cache, cache_options),
        do:
          TamaMCP.Tool.__validator__(
            __MODULE__,
            :input,
            unquote(input_validator),
            cache,
            cache_options
          )

      @doc false
      def output_validator(cache, cache_options),
        do:
          TamaMCP.Tool.__validator__(
            __MODULE__,
            :output,
            unquote(output_validator),
            cache,
            cache_options
          )
    end
  end

  defp policy_functions(scopes, annotations) do
    quote do
      @doc false
      def scopes, do: unquote(scopes)
      @doc false
      def annotations, do: unquote(Macro.escape(annotations))
    end
  end

  defp compile_error!(env, description) do
    raise CompileError, file: env.file, line: env.line, description: description
  end
end
