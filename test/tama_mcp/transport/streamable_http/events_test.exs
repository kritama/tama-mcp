defmodule TamaMCP.Transport.StreamableHTTP.EventsTest do
  @moduledoc false

  use ExUnit.Case
  import ExUnit.CaptureLog

  alias TamaMCP.Authorization.Decision
  alias TamaMCP.Transport.StreamableHTTP.{Events, Runtime}
  alias TamaMCP.Transport.StreamableHTTP.Plug, as: MCPPlug

  defmodule Authorization do
    @moduledoc false

    use TamaMCP.Authorization

    @impl true
    def authenticate(conn, opts) do
      send(Keyword.fetch!(opts, :test), :authenticated)
      TamaMCP.TestSupport.Authorization.authenticate(conn, [])
    end
  end

  defmodule Invalid do
    @moduledoc false

    use TamaMCP.Authorization

    @impl true
    def authenticate(_conn, _opts), do: {:ok, %Decision{principal: "invalid", scopes: nil}}
  end

  defmodule Crashing do
    @moduledoc false

    use TamaMCP.Authorization

    @impl true
    def authenticate(_conn, _opts), do: raise("adapter detail must not escape")
  end

  defmodule Exiting do
    @moduledoc false

    use TamaMCP.Authorization

    @impl true
    def authenticate(_conn, _opts), do: exit({:adapter_secret, "must not escape"})
  end

  test "authentication runs before malformed transport input is rejected" do
    runtime = runtime(Authorization, authorization_options: [test: self()])
    conn = request(runtime, "not-json")

    assert_received :authenticated
    assert conn.status == 400
  end

  test "invalid normalized authorization decisions fail closed" do
    {conn, log} = with_log(fn -> request(runtime(Invalid), discover_body()) end)

    assert conn.status == 500
    assert Jason.decode!(conn.resp_body)["error"]["message"] == "Internal error"
    assert log =~ "TamaMCP unexpected runtime failure: Elixir.RuntimeError"
  end

  test "unexpected request failures emit a bounded exception event" do
    event = [:tama_mcp, :test, :request, :exception]
    handler = "events-test-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler,
        event,
        &__MODULE__.handle/4,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    {conn, log} = with_log(fn -> request(runtime(Crashing), discover_body()) end)

    assert conn.status == 500
    assert_receive {:event, ^event, %{}, metadata}
    assert metadata.status == :exception
    assert metadata.reason == "Elixir.RuntimeError"
    refute inspect(metadata) =~ "adapter detail"
    assert log =~ "TamaMCP unexpected runtime failure: Elixir.RuntimeError"
    refute log =~ "adapter detail"
  end

  test "authorization exits become redacted internal errors" do
    event = [:tama_mcp, :test, :request, :exception]
    handler = "events-exit-test-#{System.unique_integer([:positive])}"

    :ok = :telemetry.attach(handler, event, &__MODULE__.handle/4, self())
    on_exit(fn -> :telemetry.detach(handler) end)

    {conn, log} = with_log(fn -> request(runtime(Exiting), discover_body()) end)

    assert conn.status == 500
    assert Jason.decode!(conn.resp_body)["error"]["message"] == "Internal error"
    assert_receive {:event, ^event, %{}, metadata}
    assert metadata.reason == "exit"
    refute inspect(metadata) =~ "adapter_secret"
    assert log =~ "TamaMCP unexpected runtime failure: exit"
    refute log =~ "adapter_secret"
  end

  test "safe metadata exits are ignored" do
    callback = fn _kind, _meta -> exit({:metadata_secret, "must not escape"}) end

    conn =
      request(
        runtime(TamaMCP.TestSupport.Authorization, safe_metadata: callback),
        discover_body()
      )

    assert conn.status == 200
  end

  test "metadata is bounded even without an application callback" do
    runtime = runtime(TamaMCP.TestSupport.Authorization)
    metadata = Events.bound(%{server: "test", method: String.duplicate("x", 2_000)}, runtime)

    assert byte_size(metadata.method) == 512
    assert {:ok, encoded} = Jason.encode(metadata)
    assert byte_size(encoded) <= runtime.limits.max_safe_metadata_bytes
  end

  test "oversized or unsafe callback metadata falls back to the bounded base" do
    safe_metadata = fn _kind, _meta -> %{secret: String.duplicate("x", 20_000)} end
    runtime = runtime(TamaMCP.TestSupport.Authorization, safe_metadata: safe_metadata)

    assert %{server: "test"} = Events.bound(%{server: "test"}, runtime)
    refute Map.has_key?(Events.bound(%{server: "test"}, runtime), :secret)
  end

  test "encodable structs from callback metadata are rejected" do
    safe_metadata = fn _kind, _meta ->
      %{adapter: %TamaMCP.TestSupport.Encodable{secret: "must-not-escape"}}
    end

    runtime = runtime(TamaMCP.TestSupport.Authorization, safe_metadata: safe_metadata)

    assert %{server: "test"} == Events.bound(%{server: "test"}, runtime)
  end

  @doc false
  def handle(name, measurements, metadata, test) do
    send(test, {:event, name, measurements, metadata})
  end

  defp runtime(authorization, opts \\ []) do
    Runtime.build(
      [
        server: TamaMCP.TestSupport.Server,
        authorization: authorization,
        cache: TamaMCP.TestSupport.Cache,
        telemetry_prefix: [:tama_mcp, :test]
      ] ++ opts
    )
  end

  defp request(runtime, body) do
    :post
    |> Plug.Test.conn("/", body)
    |> Map.put(:req_headers, [
      {"mcp-protocol-version", TamaMCP.Protocol.version()},
      {"mcp-method", TamaMCP.Protocol.method(:server_discover)},
      {"content-type", "application/json"},
      {"accept", "application/json, text/event-stream"},
      {"x-test-token", "ok"}
    ])
    |> MCPPlug.call(runtime)
  end

  defp discover_body do
    Jason.encode!(%{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => TamaMCP.Protocol.method(:server_discover),
      "params" => %{
        "_meta" => %{
          TamaMCP.Protocol.meta_key(:protocol_version) => TamaMCP.Protocol.version(),
          TamaMCP.Protocol.meta_key(:client_capabilities) => %{}
        }
      }
    })
  end
end
