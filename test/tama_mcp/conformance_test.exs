defmodule TamaMCP.ConformanceTest do
  @moduledoc false

  use ExUnit.Case
  import ExUnit.CaptureLog

  alias TamaMCP.{Conformance, Error, Protocol, Task}
  alias TamaMCP.TestSupport.Tasks.{Fixtures, Store}
  alias TamaMCP.Transport.StreamableHTTP.Plug, as: MCPPlug
  alias TamaMCP.Transport.StreamableHTTP.Runtime

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

  test "the bundled core fixtures pass against the reference server" do
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

  test "the bundled task fixtures pass against the durable task reference adapters" do
    {:ok, store} = Store.start_link()

    runtime =
      MCPPlug.init(
        server: TamaMCP.TestSupport.TaskRequiredServer,
        authorization: TamaMCP.TestSupport.Authorization,
        cache: TamaMCP.TestSupport.Cache,
        task_store: Store,
        task_store_options: [agent: store, test: self()],
        task_runner: TamaMCP.TestSupport.Tasks.Runner,
        task_runner_options: [test: self()],
        clock: TamaMCP.TestSupport.Tasks.Clock,
        identifier: TamaMCP.TestSupport.Tasks.Identifier
      )

    assert :ok =
             Conformance.run(
               &task_request(&1, runtime, store),
               TamaMCP.TestSupport.Cache,
               Conformance.tasks_fixtures()
             )

    assert :ok = Conformance.validate_schema_fixtures(TamaMCP.TestSupport.Cache)

    assert length(Conformance.all_fixtures()) ==
             length(Conformance.core_fixtures()) + length(Conformance.tasks_fixtures())
  end

  test "the checked task fixtures match the deterministic fixture builder" do
    path = Path.expand("../fixtures/protocol/2026-07-28/tasks.json", __DIR__)
    checked = path |> File.read!() |> Jason.decode!()

    assert checked == Fixtures.document()
  end

  test "task validators are restored through the host cache adapter" do
    fixture = hd(Conformance.tasks_fixtures())

    assert :ok =
             Conformance.validate(
               :create_task_result,
               fixture["expected"]["body"]["result"],
               Cache,
               test: self()
             )

    assert_receive {:protocol_cache_fetch,
                    "tama_mcp:validator:1:Elixir.TamaMCP.Schema.Tasks:create_task_result:" <>
                      _fingerprint}
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

  test "task fixtures validate the JSON-RPC envelope independently of the nested result" do
    fixture = hd(Conformance.tasks_fixtures())
    expected = fixture["expected"]

    response = %{
      status: expected["status"],
      headers: Enum.map(expected["headers"], fn {name, value} -> {name, value} end),
      body: Map.delete(expected["body"], "jsonrpc")
    }

    assert {:error, errors} =
             Conformance.verify(fixture, response, TamaMCP.TestSupport.Cache)

    assert "unexpected body" in errors
    assert "result_response does not match the pinned schema" in errors
    refute Enum.any?(errors, &String.starts_with?(&1, "create_task_result "))
  end

  test "schema fixtures report an inverted expectation without raising" do
    fixture = hd(Conformance.task_schema_fixtures())
    inverted = Map.put(fixture, "valid", false)

    assert {:error, [message]} =
             Conformance.validate_schema_fixtures(
               TamaMCP.TestSupport.Cache,
               [inverted]
             )

    assert message =~ fixture["name"]
    assert message =~ "unexpectedly matches the pinned schema"
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

  defp task_request(%{"setup" => setup} = task_request, runtime, store) do
    prepare(setup, runtime, store)
    request(task_request, runtime)
  end

  defp task_request(task_request, runtime, _store), do: request(task_request, runtime)

  defp prepare(%{"task" => wire}, runtime, _store) do
    validation_options =
      Runtime.task_validation_options(runtime, TamaMCP.TestSupport.Tools.TaskRequired)

    store_options = Runtime.effective_task_store_options(runtime, validation_options)
    {:ok, created_at, 0} = DateTime.from_iso8601(wire["createdAt"])

    {:ok, task} =
      Task.new(
        %{
          id: wire["taskId"],
          owner_key: "test-owner",
          method: Protocol.method(:tools_call),
          request_id: "fixture-setup-#{wire["taskId"]}",
          status_message: wire["statusMessage"],
          created_at: created_at,
          last_updated_at: created_at,
          ttl_ms: wire["ttlMs"],
          poll_interval_ms: wire["pollIntervalMs"],
          original_params: %{"name" => "task_required", "arguments" => %{}},
          client_capabilities: task_capabilities()
        },
        validation_options
      )

    assert {:ok, ^task} = Store.create(task, store_options)
    transition_setup(task, wire, store_options, validation_options)
  end

  defp transition_setup(task, %{"status" => "working"}, _store_options, _validation_options),
    do: task

  defp transition_setup(task, wire, store_options, validation_options) do
    {:ok, last_updated_at, 0} = DateTime.from_iso8601(wire["lastUpdatedAt"])
    status = status(wire["status"])

    attributes =
      %{last_updated_at: last_updated_at}
      |> put_payload(:input_requests, wire["inputRequests"])
      |> put_payload(:result, wire["result"])
      |> put_error(wire["error"])

    assert {:ok, transitioned} =
             Store.transition(
               task.owner_key,
               task.id,
               task.revision,
               status,
               attributes,
               Keyword.put(
                 store_options,
                 :tama_mcp,
                 task_validation_options: validation_options
               )
             )

    transitioned
  end

  defp put_payload(attributes, _key, nil), do: attributes
  defp put_payload(attributes, key, value), do: Map.put(attributes, key, value)

  defp put_error(attributes, nil), do: attributes

  defp put_error(attributes, error) do
    Map.put(
      attributes,
      :error,
      %Error{code: error["code"], message: error["message"], data: error["data"]}
    )
  end

  defp status("input_required"), do: :input_required
  defp status("completed"), do: :completed
  defp status("failed"), do: :failed
  defp status("cancelled"), do: :cancelled

  defp task_capabilities do
    %{
      "extensions" => %{Protocol.tasks_extension() => %{}},
      "elicitation" => %{"form" => %{}}
    }
  end
end
