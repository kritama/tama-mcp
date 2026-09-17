defmodule TamaMCP.Schema.Walker do
  @moduledoc false

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
  # `definitions` is a legacy container rather than a Draft 2020-12 keyword,
  # but references can still target it. Traverse it conservatively so hidden
  # annotations and nested dialect declarations cannot bypass validation.
  @schema_map_keywords ~w($defs definitions dependentSchemas patternProperties)

  @spec children(map(), boolean()) :: [term()]
  def children(schema, include_properties? \\ true) when is_map(schema) do
    direct_schemas(schema) ++
      array_schemas(schema) ++
      mapped_schemas(schema) ++
      property_schemas(schema, include_properties?)
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

  defp property_schemas(%{"properties" => properties}, true) when is_map(properties),
    do: Map.values(properties)

  defp property_schemas(_schema, _include_properties?), do: []

  defp values_for(schema, keys) do
    for key <- keys, Map.has_key?(schema, key), do: Map.fetch!(schema, key)
  end
end
