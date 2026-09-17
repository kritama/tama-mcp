defmodule TamaMCP.Transport.StreamableHTTP.RunnerTest do
  @moduledoc false

  use ExUnit.Case, async: true
  import ExUnit.CaptureLog

  alias TamaMCP.Transport.StreamableHTTP.Runner

  defmodule Returning do
    @moduledoc false

    def call(_arguments, _context), do: {:ok, :complete}
  end

  defmodule Crashing do
    @moduledoc false

    def call(_arguments, _context), do: raise("callback detail must not escape")
  end

  defmodule Blocking do
    @moduledoc false

    def call(%{"test" => test}, _context) do
      send(test, {:callback_started, self()})
      receive do: (:finish -> {:ok, :complete})
    end
  end

  test "returns callback results and normalizes callback failures" do
    assert Runner.run(Returning, %{}, %TamaMCP.Context{}, 100) == {:ok, {:ok, :complete}}

    {result, log} =
      with_log(fn -> Runner.run(Crashing, %{}, %TamaMCP.Context{}, 100) end)

    assert result == {:error, :tool_exception}
    refute log =~ "callback detail"
  end

  test "stops the callback at the execution deadline" do
    assert Runner.run(Blocking, %{"test" => self()}, %TamaMCP.Context{}, 10) ==
             {:error, :timeout}

    assert_received {:callback_started, callback}
    refute Process.alive?(callback)
  end

  test "stops the callback when its request owner terminates" do
    test = self()

    owner =
      spawn(fn ->
        Runner.run(Blocking, %{"test" => test}, %TamaMCP.Context{}, 5_000)
      end)

    assert_receive {:callback_started, callback}
    callback_monitor = Process.monitor(callback)
    Process.exit(owner, :kill)

    assert_receive {:DOWN, ^callback_monitor, :process, ^callback, _reason}, 1_000
  end
end
