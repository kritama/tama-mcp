defmodule TamaMCP.Transport.StreamableHTTP.Events do
  @moduledoc false

  require Logger

  @max_value_bytes 512
  @base_keys [:method, :reason, :server, :status, :tool]

  def exception(exception), do: exception.__struct__ |> to_string() |> truncate()

  def log(exception) do
    Logger.warning("TamaMCP unexpected runtime failure: #{exception(exception)}")
  end

  def emit(runtime, suffix, measurements, metadata) do
    :telemetry.execute(runtime.telemetry_prefix ++ suffix, measurements, bound(metadata, runtime))
  end

  def bound(meta, runtime) do
    base = normalize_base(meta)
    merged = merge_safe(base, runtime.safe_metadata)
    fit(merged, base, runtime.limits.max_safe_metadata_bytes)
  end

  defp merge_safe(meta, nil), do: meta

  defp merge_safe(meta, safe_metadata) do
    extras =
      try do
        safe_metadata.(meta[:method] || meta[:reason] || "unknown", meta)
      rescue
        _exception -> %{}
      end

    merged = if is_map(extras), do: Map.merge(meta, extras), else: meta
    if json_safe?(merged), do: merged, else: meta
  end

  defp normalize_base(meta) do
    meta
    |> Map.take(@base_keys)
    |> Map.new(fn {key, value} -> {key, safe_value(value)} end)
  end

  defp fit(merged, base, limit) do
    cond do
      fits?(merged, limit) -> merged
      fits?(base, limit) -> base
      true -> %{}
    end
  end

  defp fits?(metadata, limit) do
    case Jason.encode(metadata) do
      {:ok, encoded} -> byte_size(encoded) <= limit
      {:error, _reason} -> false
    end
  end

  defp json_safe?(metadata), do: match?({:ok, _encoded}, Jason.encode(metadata))

  defp safe_value(value) when is_binary(value), do: truncate(value)
  defp safe_value(value) when is_atom(value), do: value
  defp safe_value(value) when is_number(value) or is_boolean(value) or is_nil(value), do: value
  defp safe_value(_value), do: "redacted"

  defp truncate(value) when byte_size(value) <= @max_value_bytes, do: value

  defp truncate(value) do
    value
    |> String.graphemes()
    |> Enum.reduce_while("", fn grapheme, result ->
      if byte_size(result) + byte_size(grapheme) > @max_value_bytes,
        do: {:halt, result},
        else: {:cont, result <> grapheme}
    end)
  end
end
