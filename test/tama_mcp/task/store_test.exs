defmodule TamaMCP.Task.StoreTest do
  use ExUnit.Case

  alias TamaMCP.{Error, Task}
  alias TamaMCP.TestSupport.Cache
  alias TamaMCP.TestSupport.Tasks.Store

  @created ~U[2026-09-14 12:00:00Z]

  setup do
    {:ok, store} = Store.start_link()

    options = [
      agent: store,
      tama_mcp: [task_validation_options: [cache: Cache]]
    ]

    {:ok, store: store, options: options}
  end

  test "creation is atomic and lookup is owner-bound", %{options: options} do
    task = task()

    assert {:ok, ^task} = Store.create(task, options)
    assert {:error, :conflict} = Store.create(task, options)
    assert {:ok, ^task} = Store.get(task.owner_key, task.id, options)
    assert {:error, :not_found} = Store.get("another-owner", task.id, options)
  end

  test "compare-and-update permits only one terminal race winner", %{options: options} do
    task = task()
    assert {:ok, ^task} = Store.create(task, options)

    candidates = [
      {:completed, %{result: completed_result(), last_updated_at: later(1)}},
      {:failed, %{error: Error.internal("Task TTL expired"), last_updated_at: later(1)}},
      {:cancelled, %{last_updated_at: later(1)}}
    ]

    contenders =
      Enum.map(candidates, fn {status, attributes} ->
        Elixir.Task.async(fn ->
          receive do
            :go ->
              Store.transition(
                task.owner_key,
                task.id,
                task.revision,
                status,
                attributes,
                options
              )
          end
        end)
      end)

    Enum.each(contenders, &send(&1.pid, :go))
    results = Enum.map(contenders, &Elixir.Task.await/1)

    assert [{:ok, winner}] = Enum.reject(results, &match?({:error, :conflict}, &1))
    assert Enum.count(results, &match?({:error, :conflict}, &1)) == 2
    assert winner.status in [:completed, :failed, :cancelled]
    assert :ok = Task.validate(winner, options[:tama_mcp][:task_validation_options])

    assert {:error, :invalid_state} = Store.cancel(task.owner_key, task.id, options)
    assert {:ok, ^winner} = Store.get(task.owner_key, task.id, options)
  end

  test "lifetime input-request key limit rejects without changing durable state", %{
    options: options
  } do
    task = %{task() | input_request_keys: ["approval", "followup"]}
    validation_options = [cache: Cache, max_input_request_keys_per_task: 2]
    options = Keyword.put(options, :tama_mcp, task_validation_options: validation_options)

    assert :ok = Task.validate(task, validation_options)
    assert {:ok, ^task} = Store.create(task, options)

    assert {:error, :invalid_task} =
             Store.transition(
               task.owner_key,
               task.id,
               task.revision,
               :input_required,
               %{
                 input_requests: %{"third" => elicitation_request()},
                 last_updated_at: later(1)
               },
               options
             )

    assert {:ok, ^task} = Store.get(task.owner_key, task.id, options)
  end

  test "input responses are accepted atomically once while unknown and superseded keys are ignored",
       %{
         options: options
       } do
    task = task()
    assert {:ok, ^task} = Store.create(task, options)

    requests = %{
      "approval" => elicitation_request(),
      "followup" => elicitation_request("Continue?")
    }

    assert {:ok, waiting} =
             Store.transition(
               task.owner_key,
               task.id,
               task.revision,
               :input_required,
               %{input_requests: requests, last_updated_at: later(1)},
               options
             )

    approval = %{"action" => "accept", "content" => %{"approved" => true}}
    unknown = %{"action" => "decline"}

    assert :ok =
             Store.update(
               task.owner_key,
               task.id,
               %{"approval" => approval, "unknown" => unknown},
               options
             )

    assert {:ok, partially_answered} = Store.get(task.owner_key, task.id, options)
    assert partially_answered.revision == waiting.revision + 1
    assert partially_answered.input_requests == %{"followup" => requests["followup"]}

    assert Store.input_responses(task.owner_key, task.id, options) == %{
             "approval" => approval
           }

    assert :ok = Store.update(task.owner_key, task.id, %{"approval" => approval}, options)
    assert {:ok, ^partially_answered} = Store.get(task.owner_key, task.id, options)

    replacement = elicitation_request("Replacement?")

    assert {:ok, superseded} =
             Store.transition(
               task.owner_key,
               task.id,
               partially_answered.revision,
               :input_required,
               %{input_requests: %{"replacement" => replacement}, last_updated_at: later(2)},
               options
             )

    assert :ok =
             Store.update(
               task.owner_key,
               task.id,
               %{"followup" => %{"action" => "decline"}},
               options
             )

    assert {:ok, ^superseded} = Store.get(task.owner_key, task.id, options)

    replacement_response = %{"action" => "decline"}

    assert :ok =
             Store.update(
               task.owner_key,
               task.id,
               %{"replacement" => replacement_response},
               options
             )

    assert {:ok, answered} = Store.get(task.owner_key, task.id, options)
    assert answered.input_requests == %{}

    assert Store.input_responses(task.owner_key, task.id, options) == %{
             "approval" => approval,
             "replacement" => replacement_response
           }
  end

  test "cooperative cancellation is durable, idempotent, and cannot overwrite a terminal winner",
       %{
         options: options
       } do
    task = task()
    assert {:ok, ^task} = Store.create(task, options)

    assert :ok = Store.cancel(task.owner_key, task.id, options)
    assert {:ok, cancelled_intent} = Store.get(task.owner_key, task.id, options)
    assert cancelled_intent.status == :working
    assert cancelled_intent.cancellation_requested
    assert cancelled_intent.revision == 1

    assert :ok = Store.cancel(task.owner_key, task.id, options)
    assert {:ok, ^cancelled_intent} = Store.get(task.owner_key, task.id, options)

    assert {:error, :conflict} =
             Store.transition(
               task.owner_key,
               task.id,
               task.revision,
               :completed,
               %{result: completed_result(), last_updated_at: later(2)},
               options
             )

    assert {:ok, completed} =
             Store.transition(
               task.owner_key,
               task.id,
               cancelled_intent.revision,
               :completed,
               %{result: completed_result(), last_updated_at: later(2)},
               options
             )

    assert completed.cancellation_requested
    assert {:error, :invalid_state} = Store.cancel(task.owner_key, task.id, options)
    assert {:ok, ^completed} = Store.get(task.owner_key, task.id, options)
  end

  test "input submission and terminal completion have one atomic race winner", %{
    options: options
  } do
    task = task()
    assert {:ok, ^task} = Store.create(task, options)

    requests = %{"approval" => elicitation_request()}

    assert {:ok, waiting} =
             Store.transition(
               task.owner_key,
               task.id,
               task.revision,
               :input_required,
               %{input_requests: requests, last_updated_at: later(1)},
               options
             )

    response = %{"action" => "accept", "content" => %{"approved" => true}}

    update =
      Elixir.Task.async(fn ->
        receive do
          :go -> Store.update(task.owner_key, task.id, %{"approval" => response}, options)
        end
      end)

    completion =
      Elixir.Task.async(fn ->
        receive do
          :go ->
            Store.transition(
              task.owner_key,
              task.id,
              waiting.revision,
              :completed,
              %{result: completed_result(), last_updated_at: later(2)},
              options
            )
        end
      end)

    send(update.pid, :go)
    send(completion.pid, :go)

    outcomes = {Elixir.Task.await(update), Elixir.Task.await(completion)}

    assert match?({:ok, {:error, :conflict}}, outcomes) or
             match?({{:error, :invalid_state}, {:ok, %Task{status: :completed}}}, outcomes)

    assert {:ok, persisted} = Store.get(task.owner_key, task.id, options)
    assert :ok = Task.validate(persisted, options[:tama_mcp][:task_validation_options])
    assert persisted.status in [:input_required, :completed]
  end

  defp task do
    assert {:ok, task} =
             Task.new(%{
               id: "task-store-1",
               owner_key: "owner-1",
               method: "tools/call",
               request_id: "request-1",
               created_at: @created,
               last_updated_at: @created,
               ttl_ms: 60_000,
               original_params: %{"name" => "message", "arguments" => %{}},
               client_capabilities: %{
                 "extensions" => %{TamaMCP.Protocol.tasks_extension() => %{}},
                 "elicitation" => %{"form" => %{}}
               }
             })

    task
  end

  defp later(seconds), do: DateTime.add(@created, seconds, :second)

  defp elicitation_request(message \\ "Approve?") do
    %{
      "method" => "elicitation/create",
      "params" => %{
        "message" => message,
        "mode" => "form",
        "requestedSchema" => %{
          "type" => "object",
          "properties" => %{"approved" => %{"type" => "boolean"}},
          "required" => ["approved"]
        }
      }
    }
  end

  defp completed_result do
    %{"resultType" => "complete", "content" => [], "isError" => false}
  end
end
