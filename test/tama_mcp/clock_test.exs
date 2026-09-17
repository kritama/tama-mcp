defmodule TamaMCP.ClockTest do
  use ExUnit.Case, async: true

  alias TamaMCP.{Clock, Error}

  defmodule Valid do
    @behaviour Clock

    @impl true
    def now(options), do: {:ok, Keyword.fetch!(options, :now)}
  end

  defmodule Failing do
    @behaviour Clock

    @impl true
    def now(_options), do: {:error, Error.invalid_params("clock unavailable")}
  end

  defmodule Invalid do
    @behaviour Clock

    @impl true
    def now(_options), do: :not_a_clock_result
  end

  defmodule Raising do
    @behaviour Clock

    @impl true
    def now(_options), do: raise("clock secret")
  end

  defmodule Throwing do
    @behaviour Clock

    @impl true
    def now(_options), do: throw(:clock_secret)
  end

  test "returns adapter UTC timestamps and the system clock returns UTC" do
    now = ~U[2026-09-14 12:00:00Z]

    assert Clock.now(Valid, now: now) == {:ok, now}
    assert {:ok, %DateTime{time_zone: "Etc/UTC"}} = Clock.System.now([])
  end

  test "preserves safe adapter errors and contains invalid adapter behavior" do
    assert {:error, %Error{code: -32_602, message: "clock unavailable"}} =
             Clock.now(Failing, [])

    for adapter <- [Invalid, Raising, Throwing] do
      assert {:error, %Error{code: -32_603, message: "Internal error"}} =
               Clock.now(adapter, [])
    end
  end
end
