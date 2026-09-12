defmodule TamaMCP.Tool.Validator do
  @moduledoc false

  alias TamaMCP.Schema

  @cache_version 1

  @spec fetch(module(), :input | :output, binary(), module(), keyword()) ::
          Schema.compiled()
  def fetch(module, kind, encoded, cache, cache_options) do
    key = cache_key(module, kind, encoded)
    loader = fn -> restore!(encoded) end

    case cache.fetch(key, loader, cache_options) do
      {:ok, compiled} -> compiled
      {:error, _reason} -> raise Schema.Error, message: "validator cache failed"
      _invalid -> raise Schema.Error, message: "validator cache returned an invalid result"
    end
  end

  defp cache_key(module, kind, encoded) do
    fingerprint = :crypto.hash(:sha256, encoded) |> Base.url_encode64(padding: false)

    Enum.join(
      ["tama_mcp", "validator", @cache_version, Atom.to_string(module), kind, fingerprint],
      ":"
    )
  end

  defp restore!(encoded) do
    :erlang.binary_to_term(encoded, [:safe])
  end
end
