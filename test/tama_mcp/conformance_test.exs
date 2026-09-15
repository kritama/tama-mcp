defmodule TamaMCP.ConformanceTest do
  @moduledoc false

  use ExUnit.Case
  import ExUnit.CaptureLog

  alias TamaMCP.Conformance
  alias TamaMCP.TestSupport.Tasks.Store
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

    assert length(Conformance.all_fixtures()) ==
             length(Conformance.core_fixtures()) + length(Conformance.tasks_fixtures())
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

  defp task_request(
         %{"body" => %{"method" => "tasks/update"}} = task_request,
         runtime,
         store
       ) do
    {:ok, task} = Store.get("test-owner", "task-phase2-1", agent: store)

    {:ok, _task} =
      Store.transition(
        task.owner_key,
        task.id,
        task.revision,
        :input_required,
        %{
          input_requests: %{"approval" => elicitation_request()},
          last_updated_at: ~U[2026-09-14 12:00:01Z]
        },
        Runtime.effective_task_store_options(runtime)
      )

    request(task_request, runtime)
  end

  defp task_request(task_request, runtime, _store), do: request(task_request, runtime)

  defp elicitation_request do
    %{
      "method" => "elicitation/create",
      "params" => %{
        "message" => "Approve?",
        "mode" => "form",
        "requestedSchema" => %{
          "type" => "object",
          "properties" => %{"approved" => %{"type" => "boolean"}},
          "required" => ["approved"]
        }
      }
    }
  end
end
