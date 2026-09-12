defmodule TamaMCP.Cache do
  @moduledoc """
  Application-owned cache adapter used for compiled tool validators.

  TamaMCP owns cache keys and validator compilation. The host application owns
  storage, concurrency, expiry, and any serialization required by its cache
  engine. Cached values are opaque Erlang terms and may contain functions.
  """

  @type key :: String.t()
  @type loader :: (-> term())
  @type options :: keyword()

  @doc """
  Returns the value stored for `key`, invoking `loader` when it is absent.

  The adapter must return the opaque loaded value unchanged. It may invoke the
  loader more than once during a concurrent miss, but must never return a value
  stored under a different key.
  """
  @callback fetch(key(), loader(), options()) :: {:ok, term()} | {:error, term()}
end
