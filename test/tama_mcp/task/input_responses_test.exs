defmodule TamaMCP.Task.InputResponsesTest.UnsafeValue do
  @moduledoc false

  defstruct []
end

defmodule TamaMCP.Task.InputResponsesTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias TamaMCP.Task
  alias TamaMCP.Task.InputResponses
  alias TamaMCP.Task.InputResponses.Plan
  alias TamaMCP.Task.InputResponsesTest.UnsafeValue
  alias TamaMCP.TestSupport.Cache

  @created ~U[2026-09-14 12:00:00Z]
  @later ~U[2026-09-14 12:00:01Z]

  describe "plan/3" do
    test "accepts only currently outstanding keys for a partial response" do
      task = input_task(["approval", "detail"])

      assert {:ok, %Plan{} = plan} =
               InputResponses.plan(task, %{}, %{"approval" => response(true)})

      assert plan.accepted == %{"approval" => response(true)}
      assert plan.recorded == %{"approval" => response(true)}
      assert plan.remaining == task.input_requests |> Map.drop(["approval"])
      refute plan.no_op
    end

    test "accepts every outstanding key for a complete response batch" do
      task = input_task(["approval", "detail"])

      assert {:ok, %Plan{} = plan} =
               InputResponses.plan(task, %{}, %{
                 "approval" => response(true),
                 "detail" => response(false)
               })

      assert map_size(plan.accepted) == 2
      assert plan.remaining == %{}
      refute plan.no_op
    end

    test "replaying an identical or conflicting response for an answered key is a no-op" do
      task = input_task(["approval"])
      answered = %{"approval" => response(true)}

      for replay <- [response(true), response(false)] do
        assert {:ok, %Plan{} = plan} =
                 InputResponses.plan(task, answered, %{"approval" => replay})

        assert plan.accepted == %{}
        assert plan.recorded == answered
        assert plan.remaining == task.input_requests
        assert plan.no_op
      end
    end

    test "ignores unknown keys" do
      task = input_task(["approval"])

      assert {:ok, %Plan{} = plan} =
               InputResponses.plan(task, %{}, %{"unknown" => response(true)})

      assert plan.accepted == %{}
      assert plan.recorded == %{}
      assert plan.remaining == task.input_requests
      assert plan.no_op
    end

    test "ignores superseded keys from the lifetime input_request_keys history" do
      # "approval" was issued, then superseded by a new batch that drops it;
      # it remains in the lifetime history but is no longer outstanding.
      first = input_task(["approval"])

      {:ok, task} =
        Task.transition(
          first,
          :input_required,
          %{
            input_requests: %{"detail" => elicitation("Detail?")},
            last_updated_at: DateTime.add(first.last_updated_at, 1, :second)
          },
          validation_options()
        )

      assert "approval" in task.input_request_keys
      refute Map.has_key?(task.input_requests, "approval")

      assert {:ok, %Plan{} = plan} =
               InputResponses.plan(task, %{}, %{"approval" => response(true)})

      assert plan.accepted == %{}
      assert plan.recorded == %{}
      assert plan.no_op
    end

    test "records mixed batches: outstanding accepted, answered and unknown ignored" do
      # "detail" was answered and committed earlier, so it is outstanding here
      # only via the host's stale recorded history; "approval" and "extra" are
      # the outstanding keys.
      task = input_task(["approval", "detail", "extra"])
      answered = %{"detail" => response(true)}

      assert {:ok, %Plan{} = plan} =
               InputResponses.plan(task, answered, %{
                 "approval" => response(true),
                 "detail" => response(false),
                 "unknown" => response(true)
               })

      assert plan.accepted == %{"approval" => response(true)}
      assert plan.recorded == %{"approval" => response(true), "detail" => response(true)}
      assert plan.remaining == task.input_requests |> Map.drop(["approval"])
      refute plan.no_op
    end

    test "the plan is deterministic and JSON-safe" do
      task =
        input_task(["zeta", "alpha", "beta"])

      recorded = %{"zeta" => response(false)}

      incoming = %{"alpha" => response(true), "beta" => response(true), "zeta" => response(true)}

      first = InputResponses.plan(task, recorded, incoming)
      second = InputResponses.plan(task, recorded, incoming)

      assert first == second
      {:ok, %Plan{} = plan} = first

      for value <- [plan.accepted, plan.recorded, plan.remaining] do
        assert is_map(value)
        assert Enum.all?(Map.keys(value), &is_binary/1)
        assert {:ok, _} = Jason.encode(value)
      end

      assert Map.keys(plan.accepted) == ["alpha", "beta"]
      assert Map.keys(plan.recorded) == ["alpha", "beta", "zeta"]
    end

    test "remaining never contains response objects and keys stay non-reusable" do
      task = input_task(["approval", "detail"])

      {:ok, %Plan{} = plan} =
        InputResponses.plan(task, %{}, %{"approval" => response(true)})

      assert plan.remaining["detail"] == elicitation("Approve? detail")

      # Committing the plan through the package transition must succeed and
      # must not extend the lifetime key history.
      {:ok, updated} =
        Task.transition(
          task,
          :input_required,
          %{
            input_requests: plan.remaining,
            last_updated_at: DateTime.add(task.last_updated_at, 1, :second)
          },
          validation_options()
        )

      assert updated.input_request_keys == task.input_request_keys
      assert updated.input_requests == plan.remaining
    end

    test "rejects tasks that are not input_required" do
      assert {:error, :invalid_state} =
               InputResponses.plan(task(), %{}, %{"approval" => response(true)})

      for terminal <- [:completed, :failed, :cancelled] do
        {:ok, finished} =
          Task.transition(
            input_task(["approval"]),
            terminal,
            terminal_attributes(terminal),
            validation_options()
          )

        assert {:error, :invalid_state} =
                 InputResponses.plan(finished, %{}, %{"approval" => response(true)})
      end
    end

    test "rejects non-JSON-safe task requests and supplied maps" do
      task = input_task(["approval"])

      poisoned = %{task | input_requests: %{approval: elicitation("Approve?")}}
      assert {:error, :invalid_input} = InputResponses.plan(poisoned, %{}, %{})

      for incoming <- [
            ["approval"],
            :approval,
            %{approval: response(true)},
            %{"approval" => response(true), "broken" => :atom},
            %{"approval" => Map.put(response(true), "nested", %UnsafeValue{})}
          ] do
        assert {:error, :invalid_input} = InputResponses.plan(task, %{}, incoming)
      end

      for recorded <- [%{approval: response(true)}, Map.put(response(true), "approval", :atom)] do
        assert {:error, :invalid_input} = InputResponses.plan(task, recorded, %{})
      end
    end
  end

  defp task do
    {:ok, task} =
      Task.new(%{
        id: "task-plan-1",
        owner_key: "owner",
        method: "tools/call",
        request_id: 1,
        created_at: @created,
        last_updated_at: @created,
        ttl_ms: 600_000,
        client_capabilities: %{"elicitation" => %{}}
      })

    task
  end

  defp input_task(keys) do
    requests =
      Enum.map(keys, fn key -> {key, elicitation("Approve? #{key}")} end) |> Map.new()

    {:ok, task} =
      Task.transition(
        task(),
        :input_required,
        %{input_requests: requests, last_updated_at: @later},
        validation_options()
      )

    task
  end

  defp elicitation(message) do
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

  defp response(value) do
    %{"content" => %{"approved" => value}, "action" => "submit"}
  end

  defp terminal_attributes(:completed) do
    [
      result: %{
        "resultType" => "complete",
        "content" => [%{"type" => "text", "text" => "done"}],
        "isError" => false
      },
      last_updated_at: DateTime.add(@created, 5, :second)
    ]
  end

  defp terminal_attributes(:failed) do
    [
      error: TamaMCP.Error.internal("Execution failed"),
      last_updated_at: DateTime.add(@created, 5, :second)
    ]
  end

  defp terminal_attributes(:cancelled) do
    [last_updated_at: DateTime.add(@created, 5, :second)]
  end

  defp validation_options, do: [cache: Cache]
end
