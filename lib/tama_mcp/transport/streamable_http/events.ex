defmodule TamaMCP.Transport.StreamableHTTP.Events do
  @moduledoc false

  require Logger

  def exception(exception), do: exception.__struct__ |> to_string()

  def log(exception) do
    Logger.warning("TamaMCP unexpected runtime failure: #{exception(exception)}")
  end

  def bound(meta, runtime) do
    case runtime.safe_metadata do
      nil -> meta
      safe_metadata -> merge_safe(meta, safe_metadata, runtime.limits.max_safe_metadata_bytes)
    end
  end

  defp merge_safe(meta, safe_metadata, limit) do
    extras =
      try do
        safe_metadata.(meta[:method] || meta[:reason] || "unknown", meta)
      rescue
        _exception -> %{}
      end

    merged = if is_map(extras), do: Map.merge(meta, extras), else: meta
    if fits?(merged, limit), do: merged, else: meta
  end

  defp fits?(metadata, limit) do
    safe = Map.new(metadata, fn {key, value} -> {key, safe_value(value)} end)

    case Jason.encode(safe) do
      {:ok, encoded} -> byte_size(encoded) <= limit
      {:error, _reason} -> false
    end
  end

  defp safe_value(value) when is_atom(value), do: Atom.to_string(value)
  defp safe_value(value), do: value
end
