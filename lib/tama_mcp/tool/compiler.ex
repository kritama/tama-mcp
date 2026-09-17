defmodule TamaMCP.Tool.Compiler do
  @moduledoc false

  alias TamaMCP.Authorization.Challenge
  alias TamaMCP.Tool.Builder

  @task_policies [:disabled, :optional, :required]
  @tool_options [:task, :scopes, :description, :title, :annotations]
  @schema_options [:allow_unknown_keys]
  @field_options [
    :required,
    :title,
    :description,
    :default,
    :min_length,
    :max_length,
    :min,
    :max,
    :pattern
  ]
  @object_options [:allow_unknown_keys | @field_options]
  @variant_options [:allow_unknown_keys]
  @max_variants 16
  @annotation_keys [:title, :readOnlyHint, :destructiveHint, :idempotentHint, :openWorldHint]

  @spec configure(keyword()) ::
          {atom(), [String.t()], String.t() | nil, String.t() | nil, map() | nil}
  def configure(opts) do
    validate_keyword_options!(opts, @tool_options, "tool options")

    task = Keyword.get(opts, :task, :disabled)

    unless task in @task_policies do
      raise CompileError,
        description:
          "invalid task policy #{inspect(task)}; expected one of #{inspect(@task_policies)}"
    end

    scopes = Keyword.get(opts, :scopes, [])

    unless valid_scopes?(scopes) do
      raise CompileError,
        description: "tool scopes must be a list of unique valid OAuth scope tokens"
    end

    description = optional_string!(Keyword.get(opts, :description), "tool description")
    title = optional_string!(Keyword.get(opts, :title), "tool title")
    annotations = build_annotations(Keyword.get(opts, :annotations, []))

    {task, scopes, description, title, annotations}
  end

  def schema_options!(expr, caller, label) do
    opts = literal_value!(expr, caller, "#{label} options")
    validate_keyword_options!(opts, @schema_options, "#{label} options", caller)

    allow_unknown? = Keyword.get(opts, :allow_unknown_keys, false)

    unless is_boolean(allow_unknown?) do
      raise compile_error(caller, "#{label} allow_unknown_keys must be a boolean")
    end

    Keyword.put_new(opts, :allow_unknown_keys, false)
  end

  def ensure_schema_available!(caller, kind) do
    attribute = declaration_attribute(kind)

    if Module.get_attribute(caller.module, attribute) do
      raise compile_error(caller, "#{kind}_schema may only be declared once")
    end

    Module.put_attribute(caller.module, attribute, true)
  end

  def literal_schema!(expr, name, caller) do
    case literal_value!(expr, caller, "#{name} schema") do
      map when is_map(map) ->
        map

      other ->
        raise compile_error(
                caller,
                "#{name}/1 expects a JSON Schema map literal, got: #{inspect(other)}"
              )
    end
  end

  def collect_schema(block, schema_opts, kind, caller) do
    expressions = block_expressions(block)

    case Enum.any?(expressions, &variant_expression?/1) do
      false ->
        {:object, Keyword.fetch!(schema_opts, :allow_unknown_keys),
         collect_fields(expressions, caller)}

      true ->
        collect_variants(expressions, schema_opts, kind, caller)
    end
  end

  def literal_value!(expr, caller, label) do
    unless Macro.quoted_literal?(expr) do
      raise compile_error(
              caller,
              "#{label} must be a literal, got: #{Macro.to_string(expr)}",
              source_line(expr, caller)
            )
    end

    {value, _binding} = Code.eval_quoted(expr, [], caller)
    value
  end

  def before_compile(env) do
    Builder.before_compile(env)
  end

  defp validate_keyword_options!(opts, allowed, label, caller \\ nil) do
    unless Keyword.keyword?(opts) do
      raise compile_error(caller, "#{label} must be a keyword list, got: #{inspect(opts)}")
    end

    keys = Keyword.keys(opts)
    unknown = Enum.reject(keys, &(&1 in allowed))
    duplicates = keys -- Enum.uniq(keys)

    if unknown != [] do
      raise compile_error(caller, "unknown #{label}: #{inspect(Enum.uniq(unknown))}")
    end

    if duplicates != [] do
      raise compile_error(caller, "duplicate #{label}: #{inspect(Enum.uniq(duplicates))}")
    end

    :ok
  end

  defp valid_scopes?(scopes) do
    is_list(scopes) and Enum.all?(scopes, &Challenge.scope?/1) and
      length(scopes) == length(Enum.uniq(scopes))
  end

  defp optional_string!(nil, _label), do: nil
  defp optional_string!(value, _label) when is_binary(value) and value != "", do: value

  defp optional_string!(value, label) do
    raise CompileError, description: "#{label} must be a non-empty string, got: #{inspect(value)}"
  end

  defp build_annotations(annotations) do
    validate_keyword_options!(annotations, @annotation_keys, "tool annotations")
    built = Enum.map(annotations, fn {key, value} -> build_annotation!(key, value) end)
    if built == [], do: nil, else: Map.new(built)
  end

  defp build_annotation!(:title, value) when is_binary(value) and value != "",
    do: {:title, value}

  defp build_annotation!(key, value) when key != :title and is_boolean(value), do: {key, value}

  defp build_annotation!(key, _value) do
    raise CompileError,
      description:
        "tool annotation #{inspect(key)} must be a boolean (or a non-empty string for :title)"
  end

  defp collect_fields(expressions, caller) when is_list(expressions) do
    fields = Enum.map(expressions, &parse_declaration!(&1, caller))
    validate_unique_names!(fields, "field", caller)
    fields
  end

  defp collect_nested_fields(nil, name, caller, line) do
    raise compile_error(
            caller,
            "nested object #{inspect(name)} must declare at least one field",
            line
          )
  end

  defp collect_nested_fields({:__block__, _meta, []}, name, caller, line) do
    collect_nested_fields(nil, name, caller, line)
  end

  defp collect_nested_fields(block, _name, caller, _line) do
    block
    |> block_expressions()
    |> collect_fields(caller)
  end

  defp collect_variants(_expressions, _schema_opts, :input, caller) do
    raise compile_error(caller, "variants are only allowed in output_schema")
  end

  defp collect_variants(expressions, schema_opts, :output, caller) do
    unless Enum.all?(expressions, &variant_expression?/1) do
      raise compile_error(caller, "cannot mix field or object declarations with variants")
    end

    if Keyword.fetch!(schema_opts, :allow_unknown_keys) do
      raise compile_error(caller, "output_schema allow_unknown_keys does not apply to variants")
    end

    variants = Enum.map(expressions, &parse_variant!(&1, caller))
    validate_variant_count!(variants, caller)
    validate_unique_names!(variants, "variant", caller)
    {:variants, variants}
  end

  defp validate_variant_count!(variants, caller) when length(variants) < 2 do
    raise compile_error(caller, "output_schema must declare at least two variants")
  end

  defp validate_variant_count!(variants, caller) when length(variants) > @max_variants do
    raise compile_error(caller, "output_schema may declare at most #{@max_variants} variants")
  end

  defp validate_variant_count!(_variants, _caller), do: :ok

  defp validate_unique_names!(declarations, label, caller) do
    names = Enum.map(declarations, &elem(&1, 0))
    duplicates = names -- Enum.uniq(names)

    if duplicates != [] do
      raise compile_error(
              caller,
              "duplicate #{label} name(s): #{inspect(Enum.uniq(duplicates))}"
            )
    end
  end

  defp block_expressions({:__block__, _meta, expressions}), do: expressions
  defp block_expressions(expressions) when is_list(expressions), do: expressions
  defp block_expressions(expression), do: [expression]

  defp variant_expression?({:variant, _meta, _args}), do: true
  defp variant_expression?(_expression), do: false

  defp parse_declaration!({:field, meta, args}, caller),
    do: parse_field_args!(args, meta, caller)

  defp parse_declaration!({:field, meta, args, _context}, caller),
    do: parse_field_args!(args, meta, caller)

  defp parse_declaration!({:object, meta, args}, caller),
    do: parse_object_args!(args, meta, caller)

  defp parse_declaration!(expression, caller) do
    raise compile_error(
            caller,
            "only field/2, field/3, or object declarations are allowed inside object schemas, got: " <>
              Macro.to_string(expression),
            source_line(expression, caller)
          )
  end

  defp parse_object_args!([name_expr, [do: block]], meta, caller) do
    parse_object_values!(name_expr, [], block, meta, caller)
  end

  defp parse_object_args!([name_expr, opts_expr, [do: block]], meta, caller) do
    opts = literal_value!(opts_expr, caller, "object options")
    parse_object_values!(name_expr, opts, block, meta, caller)
  end

  defp parse_object_args!(args, meta, caller) do
    raise compile_error(
            caller,
            "object expects a name, optional options, and a do block, got: #{length(args)} arguments",
            Keyword.get(meta, :line, caller.line)
          )
  end

  defp parse_object_values!(name_expr, opts, block, meta, caller) do
    line = Keyword.get(meta, :line, caller.line)
    name = literal_name!(name_expr, "object", caller, line)
    validate_keyword_options!(opts, @object_options, "object options", caller)
    allow_unknown? = boolean_option!(opts, :allow_unknown_keys, false, "object", caller, line)
    field_opts = Keyword.delete(opts, :allow_unknown_keys)
    validate_field_options!(field_opts, caller, line)
    fields = collect_nested_fields(block, name, caller, line)
    {name, {:object, fields, allow_unknown?}, field_opts}
  end

  defp parse_variant!({:variant, meta, [name_expr, [do: block]]}, caller) do
    parse_variant_values!(name_expr, [], block, meta, caller)
  end

  defp parse_variant!({:variant, meta, [name_expr, opts_expr, [do: block]]}, caller) do
    opts = literal_value!(opts_expr, caller, "variant options")
    parse_variant_values!(name_expr, opts, block, meta, caller)
  end

  defp parse_variant!({:variant, meta, args}, caller) do
    raise compile_error(
            caller,
            "variant expects a name, optional options, and a do block, got: #{length(args)} arguments",
            Keyword.get(meta, :line, caller.line)
          )
  end

  defp parse_variant_values!(name_expr, opts, nil, meta, caller) do
    line = Keyword.get(meta, :line, caller.line)
    name = literal_name!(name_expr, "variant", caller, line)
    validate_variant_options!(opts, caller, line)
    raise compile_error(caller, "variant #{inspect(name)} must declare at least one field", line)
  end

  defp parse_variant_values!(name_expr, opts, block, meta, caller) do
    line = Keyword.get(meta, :line, caller.line)
    name = literal_name!(name_expr, "variant", caller, line)
    allow_unknown? = validate_variant_options!(opts, caller, line)
    fields = block |> block_expressions() |> collect_fields(caller)
    ensure_variant_fields!(fields, name, caller, line)
    {name, allow_unknown?, fields}
  end

  defp ensure_variant_fields!([], name, caller, line) do
    raise compile_error(caller, "variant #{inspect(name)} must declare at least one field", line)
  end

  defp ensure_variant_fields!(_fields, _name, _caller, _line), do: :ok

  defp validate_variant_options!(opts, caller, line) do
    validate_keyword_options!(opts, @variant_options, "variant options", caller)
    boolean_option!(opts, :allow_unknown_keys, false, "variant", caller, line)
  end

  defp parse_field_args!([name_expr, type_expr], meta, caller) do
    parse_field_values!(name_expr, type_expr, [], meta, caller)
  end

  defp parse_field_args!([name_expr, type_expr, opts_expr], meta, caller) do
    opts = literal_value!(opts_expr, caller, "field options")
    parse_field_values!(name_expr, type_expr, opts, meta, caller)
  end

  defp parse_field_args!(args, meta, caller) do
    raise compile_error(
            caller,
            "field expects exactly 2 or 3 arguments, got: #{length(args)}",
            Keyword.get(meta, :line, caller.line)
          )
  end

  defp parse_field_values!(name_expr, type_expr, opts, meta, caller) do
    line = Keyword.get(meta, :line, caller.line)
    name = literal_field_name!(name_expr, caller, line)
    type = literal_value!(type_expr, caller, "field type")

    validate_field_options!(opts, caller, line)
    {name, type, opts}
  end

  defp literal_field_name!(expr, caller, line) do
    name = literal_value!(expr, caller, "field name")

    if is_atom(name) and not is_nil(name) do
      name
    else
      raise compile_error(caller, "field name must be an atom, got: #{inspect(name)}", line)
    end
  end

  defp literal_name!(expr, label, caller, line) do
    name = literal_value!(expr, caller, "#{label} name")

    if is_atom(name) and not is_nil(name) and Atom.to_string(name) != "" do
      name
    else
      raise compile_error(
              caller,
              "#{label} name must be a non-empty atom, got: #{inspect(name)}",
              line
            )
    end
  end

  defp boolean_option!(opts, key, default, label, caller, line) do
    case Keyword.fetch(opts, key) do
      :error ->
        default

      {:ok, value} when is_boolean(value) ->
        value

      {:ok, _value} ->
        raise compile_error(caller, "#{label} #{key} must be a boolean", line)
    end
  end

  defp validate_field_options!(opts, caller, line) do
    validate_keyword_options!(opts, @field_options, "field options", caller)

    case Keyword.fetch(opts, :required) do
      :error ->
        :ok

      {:ok, value} when is_boolean(value) ->
        :ok

      {:ok, _value} ->
        raise compile_error(caller, "field required option must be a boolean", line)
    end

    validate_optional_field_string!(opts, :title, caller, line)
    validate_optional_field_string!(opts, :description, caller, line)
  end

  defp validate_optional_field_string!(opts, key, caller, line) do
    case Keyword.fetch(opts, key) do
      :error ->
        :ok

      {:ok, value} when is_binary(value) and value != "" ->
        :ok

      {:ok, _value} ->
        raise compile_error(caller, "field #{key} must be a non-empty string", line)
    end
  end

  defp declaration_attribute(:input), do: :tama_mcp_input_schema_declared
  defp declaration_attribute(:output), do: :tama_mcp_output_schema_declared

  defp source_line({_, meta, _}, caller) when is_list(meta),
    do: Keyword.get(meta, :line, caller.line)

  defp source_line(_expr, caller), do: caller.line

  defp compile_error(caller, description, line \\ nil)
  defp compile_error(nil, description, _line), do: %CompileError{description: description}

  defp compile_error(caller, description, line) do
    %CompileError{file: caller.file, line: line || caller.line, description: description}
  end
end
