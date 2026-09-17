defmodule TamaMCP.IdentifierTest do
  use ExUnit.Case, async: true

  alias TamaMCP.{Error, Identifier}

  defmodule Valid do
    @behaviour Identifier

    @impl true
    def generate(options), do: {:ok, Keyword.fetch!(options, :identifier)}
  end

  defmodule Failing do
    @behaviour Identifier

    @impl true
    def generate(_options), do: {:error, Error.invalid_params("identifier unavailable")}
  end

  defmodule Invalid do
    @behaviour Identifier

    @impl true
    def generate(_options), do: {:ok, ""}
  end

  defmodule Raising do
    @behaviour Identifier

    @impl true
    def generate(_options), do: raise("identifier secret")
  end

  defmodule Throwing do
    @behaviour Identifier

    @impl true
    def generate(_options), do: throw(:identifier_secret)
  end

  test "returns opaque adapter identifiers" do
    assert Identifier.generate(Valid, identifier: "opaque-task") == {:ok, "opaque-task"}
  end

  test "the default generator returns unique RFC 4122 variant UUIDv4 identifiers" do
    assert {:ok, first} = Identifier.UUID.generate([])
    assert {:ok, second} = Identifier.UUID.generate([])

    assert first != second
    assert first =~ ~r/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/
    assert second =~ ~r/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/
  end

  test "preserves safe adapter errors and contains invalid adapter behavior" do
    assert {:error, %Error{code: -32_602, message: "identifier unavailable"}} =
             Identifier.generate(Failing, [])

    for adapter <- [Invalid, Raising, Throwing] do
      assert {:error, %Error{code: -32_603, message: "Internal error"}} =
               Identifier.generate(adapter, [])
    end
  end
end
