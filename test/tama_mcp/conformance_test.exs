defmodule TamaMCP.ConformanceTest do
  @moduledoc false

  use ExUnit.Case
  import ExUnit.CaptureLog

  alias TamaMCP.Conformance
  alias TamaMCP.Transport.StreamableHTTP.Plug, as: MCPPlug

  defmodule Cache do
    @moduledoc false

    @behaviour TamaMCP.Cache

    @impl true
    def fetch(key, loader, options) do
      send(Keyword.fetch!(options, :test), {:protocol_cache_fetch, key})
      {:ok, loader.()}
    end
  end

  test "protocol validators are restored through the host cache adapter" do
    fixture = hd(Conformance.fixtures())

    assert :ok =
             Conformance.validate(
               :discover_request,
               fixture["request"]["body"],
               Cache,
               test: self()
             )

    assert_receive {:protocol_cache_fetch,
                    "tama_mcp:validator:1:Elixir.TamaMCP.Schema.Protocol:discover_request:" <>
                      _fingerprint}
  end

  test "the bundled Phase 1 fixtures pass against the reference server" do
    runtime =
      MCPPlug.init(
        server: TamaMCP.TestSupport.Server,
        authorization: TamaMCP.TestSupport.Authorization,
        cache: TamaMCP.TestSupport.Cache
      )

    {result, log} =
      with_log(fn ->
        Conformance.run(&request(&1, runtime), TamaMCP.TestSupport.Cache)
      end)

    assert result == :ok
    assert log =~ "TamaMCP unexpected runtime failure: Elixir.RuntimeError"
  end

  test "fixture verification reports response drift without raising" do
    fixture = hd(Conformance.fixtures())

    assert {:error, errors} =
             Conformance.verify(
               fixture,
               %{status: 500, headers: [], body: %{}},
               TamaMCP.TestSupport.Cache
             )

    assert "unexpected status" in errors
    assert "unexpected body" in errors
    assert Enum.any?(errors, &String.starts_with?(&1, "unexpected header"))
    assert "discover_response does not match the pinned schema" in errors
  end

  test "bang validation and runner failures provide bounded diagnostics" do
    fixture = hd(Conformance.fixtures())

    assert :ok =
             Conformance.validate!(
               :discover_request,
               fixture["request"]["body"],
               TamaMCP.TestSupport.Cache
             )

    assert_raise TamaMCP.Schema.Error, fn ->
      Conformance.validate!(:discover_response, %{}, TamaMCP.TestSupport.Cache)
    end

    assert {:error, [message | _rest]} =
             Conformance.run(
               fn _request -> %{status: 500, headers: [], body: %{}} end,
               TamaMCP.TestSupport.Cache,
               [fixture]
             )

    assert String.starts_with?(message, "server/discover success:")
  end

  defp request(request, runtime) do
    conn =
      :post
      |> Plug.Test.conn("/", Jason.encode!(request["body"]))
      |> Map.put(:req_headers, Enum.map(request["headers"], &List.to_tuple/1))
      |> MCPPlug.call(runtime)

    %{
      status: conn.status,
      headers: conn.resp_headers,
      body: Jason.decode!(conn.resp_body)
    }
  end
end
