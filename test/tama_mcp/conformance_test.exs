defmodule TamaMCP.ConformanceTest do
  @moduledoc false

  use ExUnit.Case
  import ExUnit.CaptureLog

  alias TamaMCP.Conformance
  alias TamaMCP.Transport.StreamableHTTP.Plug, as: MCPPlug

  test "the bundled Phase 1 fixtures pass against the reference server" do
    runtime =
      MCPPlug.init(
        server: TamaMCP.TestSupport.Server,
        authorization: TamaMCP.TestSupport.Authorization
      )

    {result, log} = with_log(fn -> Conformance.run(&request(&1, runtime)) end)

    assert result == :ok
    assert log =~ "TamaMCP unexpected runtime failure: Elixir.RuntimeError"
  end

  test "fixture verification reports response drift without raising" do
    fixture = hd(Conformance.fixtures())

    assert {:error, errors} =
             Conformance.verify(fixture, %{status: 500, headers: [], body: %{}})

    assert "unexpected status" in errors
    assert "unexpected body" in errors
    assert Enum.any?(errors, &String.starts_with?(&1, "unexpected header"))
    assert "discover_response does not match the pinned schema" in errors
  end

  test "bang validation and runner failures provide bounded diagnostics" do
    fixture = hd(Conformance.fixtures())
    assert :ok = Conformance.validate!(:discover_request, fixture["request"]["body"])

    assert_raise TamaMCP.Schema.Error, fn ->
      Conformance.validate!(:discover_response, %{})
    end

    assert {:error, [message | _rest]} =
             Conformance.run(fn _request -> %{status: 500, headers: [], body: %{}} end, [fixture])

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
