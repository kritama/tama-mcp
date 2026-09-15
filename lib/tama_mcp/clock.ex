defmodule TamaMCP.Clock do
  @moduledoc """
  Application-replaceable clock used when creating and transitioning tasks.

  Adapters return UTC `DateTime` values. Keeping time behind this behaviour
  makes task transitions deterministic in conformance and race tests without
  coupling TamaMCP to an application database.
  """

  @callback now(keyword()) :: {:ok, DateTime.t()} | {:error, TamaMCP.Error.t()}

  @doc false
  @spec now(module(), keyword()) :: {:ok, DateTime.t()} | {:error, TamaMCP.Error.t()}
  def now(adapter, options) do
    case adapter.now(options) do
      {:ok, %DateTime{} = now} -> {:ok, now}
      {:error, %TamaMCP.Error{} = error} -> {:error, error}
      _invalid -> {:error, TamaMCP.Error.internal()}
    end
  rescue
    _exception -> {:error, TamaMCP.Error.internal()}
  catch
    _kind, _reason -> {:error, TamaMCP.Error.internal()}
  end
end

defmodule TamaMCP.Clock.System do
  @moduledoc "Default UTC system clock."

  @behaviour TamaMCP.Clock

  @impl true
  def now(_options), do: {:ok, DateTime.utc_now()}
end
