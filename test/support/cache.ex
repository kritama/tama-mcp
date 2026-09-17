defmodule TamaMCP.TestSupport.Cache do
  @moduledoc false

  @behaviour TamaMCP.Cache

  @impl true
  def fetch(key, loader, _options) do
    persistent_key = {__MODULE__, key}

    case :persistent_term.get(persistent_key, :missing) do
      :missing ->
        value = loader.()
        :persistent_term.put(persistent_key, value)
        {:ok, value}

      value ->
        {:ok, value}
    end
  end
end
