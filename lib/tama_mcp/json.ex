defmodule TamaMCP.JSON do
  @moduledoc false

  @spec value?(term()) :: boolean()
  def value?(value), do: safe?(value, :wire)

  @spec metadata?(term()) :: boolean()
  def metadata?(value), do: safe?(value, :metadata)

  defp safe?(nil, _kind), do: true
  defp safe?(value, _kind) when is_boolean(value) or is_number(value), do: true
  defp safe?(value, _kind) when is_binary(value), do: String.valid?(value)
  defp safe?(value, :metadata) when is_atom(value), do: true
  defp safe?([], _kind), do: true
  defp safe?([head | tail], kind), do: safe?(head, kind) and safe?(tail, kind)
  defp safe?(%_struct{}, _kind), do: false

  defp safe?(value, kind) when is_map(value) do
    Enum.all?(value, fn {key, item} -> safe_key?(key, kind) and safe?(item, kind) end)
  end

  defp safe?(_value, _kind), do: false

  defp safe_key?(key, _kind) when is_binary(key), do: String.valid?(key)
  defp safe_key?(key, :metadata) when is_atom(key), do: true
  defp safe_key?(_key, _kind), do: false
end
