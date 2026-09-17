defmodule TamaMCP.Schema do
  @moduledoc false
  # Internal schema builder and JSON Schema Draft 2020-12 validation.
  #
  # The tool DSL is an ergonomic builder over ordinary JSON Schema maps. This
  # module owns the builder and the jsonschex boundary so tools never touch the
  # validator directly. Schemas are compiled once and reused.

  alias __MODULE__.Walker
  alias TamaMCP.JSON

  @type compiled :: term()

  @dialects [
    "https://json-schema.org/draft/2020-12/schema",
    "https://json-schema.org/draft/2020-12/schema#"
  ]

  defmodule Error do
    @moduledoc false

    defexception [:message]
  end

  @doc """
  Compiles a JSON Schema Draft 2020-12 map for reuse.

  Returns `{:ok, compiled}` or `{:error, reason}` with a bounded reason.
  """
  @spec compile(map()) :: {:ok, compiled()} | {:error, String.t()}
  def compile(schema) when is_map(schema) do
    with :ok <- validate_json(schema),
         :ok <- validate_dialects(schema) do
      case JSONSchex.compile(schema) do
        {:ok, compiled} -> {:ok, compiled}
        {:error, reason} -> {:error, format_compile_error(reason)}
      end
    end
  end

  defp validate_json(schema) do
    if JSON.value?(schema) do
      :ok
    else
      {:error, "JSON Schema must contain only JSON values and UTF-8 string keys"}
    end
  end

  @doc "Validates data against a compiled schema. Returns `:ok` or `{:error, details}`."
  @spec validate(compiled(), term()) :: :ok | {:error, [String.t()]}
  def validate(compiled, data) do
    case JSONSchex.validate(compiled, data) do
      :ok -> :ok
      {:error, errors} -> {:error, Enum.map(errors, &format_validation_error/1)}
    end
  end

  @doc "Formats compile errors as bounded strings."
  @spec format_compile_error(term()) :: String.t()
  def format_compile_error(reason) do
    "invalid JSON schema: " <> bounded(JSONSchex.format_error(reason))
  end

  defp format_validation_error(error) do
    bounded(JSONSchex.format_error(error))
  end

  defp bounded(string) when is_binary(string) do
    case String.split(string, "\n") do
      [first | _] -> String.trim(first)
      [] -> "unknown schema error"
    end
  end

  @doc """
  Builds an object schema from declared fields.

  `fields` is a list of `{name, type, opts}` tuples in declaration order.
  Options: `:allow_unknown_keys` (default `false`, which emits
  `additionalProperties: false`).
  """
  @spec build_object_schema([{atom(), term(), keyword()}], keyword()) :: map()
  def build_object_schema(fields, opts \\ []) when is_list(fields) do
    allow_unknown? = Keyword.get(opts, :allow_unknown_keys, false)

    properties =
      fields
      |> Enum.map(fn {name, type, field_opts} ->
        {to_string(name), field_schema(type, field_opts)}
      end)
      |> Map.new()

    required =
      fields
      |> Enum.filter(fn {_name, _type, opts} -> Keyword.get(opts, :required, false) end)
      |> Enum.map(&elem(&1, 0))
      |> Enum.map(&to_string/1)
      |> Enum.sort()

    schema = %{"type" => "object", "properties" => properties}
    schema = if required == [], do: schema, else: Map.put(schema, "required", required)
    Map.put(schema, "additionalProperties", allow_unknown?)
  end

  @doc "Builds the schema map for a single declared field type."
  @spec field_schema(term(), keyword()) :: map()
  def field_schema(type, opts \\ []) do
    schema = type_schema(type)
    apply_common_options(schema, opts, type)
  end

  @primitive_types [:string, :integer, :number, :boolean]

  @doc "Builds the base schema map for a field type."
  @spec type_schema(term()) :: map()
  def type_schema(type) do
    case type do
      {:enum, values} ->
        enum_schema(values)

      {:array, item} ->
        %{"type" => "array", "items" => type_schema(item)}

      {:raw, map} when is_map(map) ->
        map

      primitive when primitive in @primitive_types ->
        %{"type" => to_string(primitive)}

      other ->
        raise Error,
          message: "unsupported field type: #{inspect(other)}"
    end
  end

  defp enum_schema(values) when is_list(values) and values != [] do
    kind = enum_kind!(values)
    Map.put(%{"type" => kind}, "enum", Enum.sort_by(values, &to_string/1))
  end

  defp enum_schema(_),
    do: raise(Error, message: "enum values must be a non-empty list")

  defp validate_dialects(schema) do
    with :ok <- validate_dialect(schema) do
      Enum.reduce_while(Walker.children(schema), :ok, &validate_child/2)
    end
  end

  defp validate_child(child, :ok) when is_map(child) do
    case validate_dialects(child) do
      :ok -> {:cont, :ok}
      {:error, _reason} = error -> {:halt, error}
    end
  end

  defp validate_child(_boolean_or_invalid, :ok), do: {:cont, :ok}

  defp validate_dialect(schema) do
    case Map.fetch(schema, "$schema") do
      :error ->
        :ok

      {:ok, dialect} when dialect in @dialects ->
        :ok

      {:ok, dialect} ->
        {:error,
         "unsupported JSON Schema dialect #{inspect(dialect)}; " <>
           "TamaMCP supports Draft 2020-12 only"}
    end
  end

  defp enum_kind!(values) do
    cond do
      Enum.all?(values, &is_binary/1) ->
        "string"

      Enum.all?(values, &is_integer/1) ->
        "integer"

      Enum.all?(values, &is_number/1) ->
        "number"

      true ->
        raise Error,
          message: "enum values must all be strings, integers, or numbers"
    end
  end

  defp apply_common_options(schema, opts, type) do
    schema
    |> maybe_put("title", Keyword.get(opts, :title))
    |> maybe_put("description", Keyword.get(opts, :description))
    |> maybe_put_option("default", opts, :default)
    |> maybe_put(
      "minLength",
      validated_length(Keyword.get(opts, :min_length), type, :min_length)
    )
    |> maybe_put(
      "maxLength",
      validated_length(Keyword.get(opts, :max_length), type, :max_length)
    )
    |> maybe_put("minimum", validated_number_bound(Keyword.get(opts, :min), type))
    |> maybe_put("maximum", validated_number_bound(Keyword.get(opts, :max), type))
    |> maybe_put("pattern", validated_pattern(Keyword.get(opts, :pattern), type))
  end

  defp maybe_put(schema, _key, nil), do: schema
  defp maybe_put(schema, key, value), do: Map.put(schema, key, value)

  defp maybe_put_option(schema, key, opts, option) do
    case Keyword.fetch(opts, option) do
      {:ok, value} -> Map.put(schema, key, value)
      :error -> schema
    end
  end

  defp validated_length(value, :string, _option) when is_integer(value) and value >= 0,
    do: value

  defp validated_length(value, :string, option) when is_integer(value),
    do: raise(Error, message: "#{option} must be a non-negative integer")

  defp validated_length(nil, _type, _option), do: nil

  defp validated_length(_value, type, option),
    do: raise(Error, message: "#{option} applies only to string fields (got #{type})")

  defp validated_number_bound(nil, _type), do: nil

  defp validated_number_bound(value, type) when type in [:integer, :number] do
    if(is_number(value), do: value, else: number_bound_error(value, type))
  end

  defp validated_number_bound(_value, type),
    do: raise(Error, message: "min/max apply only to number fields (got #{type})")

  defp number_bound_error(value, type),
    do:
      raise(Error,
        message: "min/max must be numeric for #{type} fields (got #{inspect(value)})"
      )

  defp validated_pattern(value, :string) when is_binary(value) and value != "", do: value
  defp validated_pattern(nil, _type), do: nil

  defp validated_pattern(_value, type),
    do: raise(Error, message: "pattern applies only to string fields (got #{type})")
end
