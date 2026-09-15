defmodule TamaMCP.Identifier do
  @moduledoc """
  Application-replaceable opaque task identifier generator.

  Identifiers must be globally unique, non-enumerable, and must not encode an
  owner, database key, protocol session, or reversible timestamp.
  """

  @callback generate(keyword()) :: {:ok, String.t()} | {:error, TamaMCP.Error.t()}

  @doc false
  @spec generate(module(), keyword()) :: {:ok, String.t()} | {:error, TamaMCP.Error.t()}
  def generate(adapter, options) do
    case adapter.generate(options) do
      {:ok, identifier} when is_binary(identifier) and identifier != "" -> {:ok, identifier}
      {:error, %TamaMCP.Error{} = error} -> {:error, error}
      _invalid -> {:error, TamaMCP.Error.internal()}
    end
  rescue
    _exception -> {:error, TamaMCP.Error.internal()}
  catch
    _kind, _reason -> {:error, TamaMCP.Error.internal()}
  end
end

defmodule TamaMCP.Identifier.UUID do
  @moduledoc "Default random UUIDv4-compatible task identifier generator."

  @behaviour TamaMCP.Identifier

  @impl true
  def generate(_options) do
    <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)
    c = Bitwise.band(c, 0x0FFF) |> Bitwise.bor(0x4000)
    d = Bitwise.band(d, 0x3FFF) |> Bitwise.bor(0x8000)

    {:ok,
     Enum.join(
       [hex(a, 8), hex(b, 4), hex(c, 4), hex(d, 4), hex(e, 12)],
       "-"
     )}
  end

  defp hex(value, width) do
    value
    |> Integer.to_string(16)
    |> String.downcase()
    |> String.pad_leading(width, "0")
  end
end
