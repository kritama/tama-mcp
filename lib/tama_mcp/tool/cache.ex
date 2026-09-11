defmodule TamaMCP.Tool.Cache do
  @moduledoc false

  alias TamaMCP.Schema

  @spec fetch(module(), :input | :output, map()) :: Schema.compiled()
  def fetch(module, kind, schema) do
    key = {__MODULE__, module, kind}
    fingerprint = :crypto.hash(:sha256, :erlang.term_to_binary(schema, [:deterministic]))

    case :persistent_term.get(key, :undefined) do
      {^fingerprint, compiled} ->
        compiled

      _stale_or_missing ->
        compiled = compile!(schema)
        :persistent_term.put(key, {fingerprint, compiled})
        compiled
    end
  end

  defp compile!(schema) do
    case Schema.compile(schema) do
      {:ok, compiled} -> compiled
      {:error, reason} -> raise Schema.Error, message: "invalid schema: #{reason}"
    end
  end
end
