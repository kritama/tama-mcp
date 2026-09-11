defmodule TamaMCP.Tool.Headers do
  @moduledoc false

  @allowed_types ~w(string integer boolean)
  @token ~r/\A[!#$%&'*+\-.^_`|~0-9A-Za-z]+\z/
  @schema_keywords ~w(
    additionalProperties
    contains
    contentSchema
    else
    if
    items
    not
    propertyNames
    then
    unevaluatedItems
    unevaluatedProperties
  )
  @schema_array_keywords ~w(allOf anyOf oneOf prefixItems)
  @schema_map_keywords ~w($defs dependentSchemas patternProperties)

  @type descriptor :: %{
          header: String.t(),
          name: String.t(),
          path: [String.t()],
          type: String.t()
        }

  @spec extract(map()) :: {:ok, [descriptor()]} | {:error, String.t()}
  def extract(schema) when is_map(schema) do
    with {:ok, descriptors} <- scan(schema, [], false, true),
         :ok <- unique?(descriptors) do
      {:ok, Enum.sort_by(descriptors, & &1.header)}
    end
  end

  defp scan(%{} = schema, path, annotation_allowed?, properties_allowed?) do
    with {:ok, current} <- annotation(schema, path, annotation_allowed?),
         {:ok, properties} <- properties(schema, path, properties_allowed?),
         {:ok, other} <- other_values(schema, path) do
      {:ok, current ++ properties ++ other}
    end
  end

  defp scan(values, path, _annotation_allowed?, _properties_allowed?) when is_list(values) do
    collect(values, &scan(&1, path, false, false))
  end

  defp scan(_value, _path, _annotation_allowed?, _properties_allowed?), do: {:ok, []}

  defp annotation(schema, path, allowed?) do
    case Map.fetch(schema, "x-mcp-header") do
      :error ->
        {:ok, []}

      {:ok, _name} when not allowed? ->
        {:error, "x-mcp-header at #{location(path)} is not statically reachable"}

      {:ok, name} ->
        descriptor(schema, path, name)
    end
  end

  defp descriptor(schema, path, name) do
    type = schema["type"]

    cond do
      not is_binary(name) or name == "" ->
        {:error, "x-mcp-header at #{location(path)} must be a non-empty string"}

      not Regex.match?(@token, name) ->
        {:error, "x-mcp-header #{inspect(name)} must be a valid HTTP field-name token"}

      type not in @allowed_types ->
        {:error,
         "x-mcp-header #{inspect(name)} must annotate a string, integer, or boolean property"}

      true ->
        {:ok,
         [
           %{
             header: String.downcase("mcp-param-" <> name),
             name: name,
             path: path,
             type: type
           }
         ]}
    end
  end

  defp properties(schema, path, true) do
    case schema["properties"] do
      %{} = properties ->
        properties
        |> Enum.sort_by(&elem(&1, 0))
        |> collect(fn {name, child} -> scan(child, path ++ [to_string(name)], true, true) end)

      _absent_or_invalid ->
        {:ok, []}
    end
  end

  defp properties(schema, path, false) do
    case schema["properties"] do
      %{} = properties -> collect(Map.values(properties), &scan(&1, path, false, false))
      _absent_or_invalid -> {:ok, []}
    end
  end

  defp other_values(schema, path) do
    with {:ok, direct} <- collect(direct_schemas(schema), &scan(&1, path, false, false)),
         {:ok, arrays} <- collect(array_schemas(schema), &scan(&1, path, false, false)),
         {:ok, maps} <- collect(mapped_schemas(schema), &scan(&1, path, false, false)) do
      {:ok, direct ++ arrays ++ maps}
    end
  end

  defp direct_schemas(schema), do: values_for(schema, @schema_keywords)

  defp array_schemas(schema) do
    schema
    |> values_for(@schema_array_keywords)
    |> Enum.flat_map(fn
      values when is_list(values) -> values
      _invalid -> []
    end)
  end

  defp mapped_schemas(schema) do
    schema
    |> values_for(@schema_map_keywords)
    |> Enum.flat_map(fn
      values when is_map(values) -> Map.values(values)
      _invalid -> []
    end)
  end

  defp values_for(schema, keys) do
    for key <- keys, Map.has_key?(schema, key), do: Map.fetch!(schema, key)
  end

  defp collect(values, fun) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, accumulated} ->
      case fun.(value) do
        {:ok, found} -> {:cont, {:ok, accumulated ++ found}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp unique?(descriptors) do
    names = Enum.map(descriptors, &String.downcase(&1.name))

    case names -- Enum.uniq(names) do
      [] -> :ok
      [duplicate | _rest] -> {:error, "duplicate x-mcp-header name #{inspect(duplicate)}"}
    end
  end

  defp location([]), do: "the schema root"
  defp location(path), do: Enum.map_join(path, ".", &inspect/1)
end
