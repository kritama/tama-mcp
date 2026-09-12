defmodule TamaMCP.JSON do
  @moduledoc false

  @meta_label ~r/\A[A-Za-z](?:[A-Za-z0-9-]*[A-Za-z0-9])?\z/
  @meta_name ~r/\A(?:[A-Za-z0-9](?:[A-Za-z0-9_.-]*[A-Za-z0-9])?)?\z/

  @spec value?(term()) :: boolean()
  def value?(value), do: safe?(value, :wire)

  @spec metadata?(term()) :: boolean()
  def metadata?(value), do: safe?(value, :metadata)

  @spec meta_object?(term()) :: boolean()
  def meta_object?(value) when is_map(value) do
    not is_struct(value) and value?(value) and Enum.all?(Map.keys(value), &meta_key?/1)
  end

  def meta_object?(_value), do: false

  @spec meta_key?(term()) :: boolean()
  def meta_key?(key) when is_binary(key) do
    String.valid?(key) and valid_meta_key?(String.split(key, "/"))
  end

  def meta_key?(_key), do: false

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

  defp valid_meta_key?([name]), do: Regex.match?(@meta_name, name)

  defp valid_meta_key?([prefix, name]) do
    valid_meta_prefix?(prefix) and Regex.match?(@meta_name, name)
  end

  defp valid_meta_key?(_segments), do: false

  defp valid_meta_prefix?(prefix) do
    prefix
    |> String.split(".")
    |> Enum.all?(&Regex.match?(@meta_label, &1))
  end
end
