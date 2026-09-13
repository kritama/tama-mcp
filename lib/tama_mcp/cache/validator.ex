defmodule TamaMCP.Cache.Validator do
  @moduledoc false

  alias TamaMCP.{Cache, Schema}

  @cache_version 1

  @type artifact :: {Cache.key(), binary()}

  @spec artifact(module(), atom(), Schema.compiled()) :: artifact()
  def artifact(namespace, kind, compiled) do
    encoded = :erlang.term_to_binary(compiled, [:deterministic])
    fingerprint = :crypto.hash(:sha256, encoded) |> Base.url_encode64(padding: false)

    key =
      Enum.join(
        ["tama_mcp", "validator", @cache_version, Atom.to_string(namespace), kind, fingerprint],
        ":"
      )

    {key, encoded}
  end

  @spec fetch(artifact(), module(), keyword()) :: Schema.compiled()
  def fetch({key, encoded}, cache, cache_options) do
    loader = fn -> :erlang.binary_to_term(encoded, [:safe]) end

    case cache.fetch(key, loader, cache_options) do
      {:ok, compiled} -> compiled
      {:error, _reason} -> raise Schema.Error, message: "validator cache failed"
      _invalid -> raise Schema.Error, message: "validator cache returned an invalid result"
    end
  end
end
