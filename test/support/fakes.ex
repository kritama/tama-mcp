defmodule TamaMCP.TestSupport.Fakes.PlainModule do
  @moduledoc false

  # A compiled module that implements neither the TamaMCP.Server contract nor
  # TamaMCP.Authorization. Used to exercise the "module is loaded but missing
  # required exports" validation path.

  def unrelated, do: :not_a_contract_module

  # A 2-arity function so it can also serve as a `:safe_metadata`
  # `{module, function}` callback.
  def metadata(_method, _meta), do: %{origin: :fake}
end
