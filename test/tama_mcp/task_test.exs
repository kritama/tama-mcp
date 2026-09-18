defmodule TamaMCP.TaskTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias TamaMCP.{Conformance, Error, RequestID, Response, Task}
  alias TamaMCP.TestSupport.Cache

  @created ~U[2026-09-14 12:00:00Z]
  @later ~U[2026-09-14 12:00:01Z]

  test "creates a bounded working task and schema-valid task handle" do
    task = task()

    assert task.status == :working
    assert task.revision == 0
    assert :ok = Task.validate(task)
    assert :ok = Conformance.validate(:create_task_result, Task.create_result(task), Cache)
    refute Map.has_key?(Task.create_result(task), "ownerKey")
  end

  test "implements every permitted state transition" do
    for next <- [:input_required, :completed, :failed, :cancelled] do
      assert {:ok, %Task{status: ^next, revision: 1}} = transition(task(), next)
    end

    input = task() |> transitioned!(:input_required)

    for next <- [:working, :completed, :failed, :cancelled] do
      assert {:ok, %Task{status: ^next, revision: 2}} = transition(input, next)
    end
  end

  test "rejects regressions and terminal payload mutation but permits exact replay" do
    terminal = [
      task() |> transitioned!(:completed),
      task() |> transitioned!(:failed),
      task() |> transitioned!(:cancelled)
    ]

    for finished <- terminal do
      assert {:ok, ^finished} =
               Task.transition(
                 finished,
                 finished.status,
                 replay_attributes(finished)
               )

      for next <- [:working, :input_required, :completed, :failed, :cancelled],
          next != finished.status do
        assert {:error, :invalid_state} =
                 Task.transition(finished, next, last_updated_at: later(60))
      end
    end

    completed = hd(terminal)

    assert {:error, :invalid_state} =
             Task.transition(completed, :completed,
               result: %{"changed" => true},
               last_updated_at: later(60)
             )

    assert {:error, :invalid_state} = Task.transition(task(), :unknown, last_updated_at: @later)
  end

  test "preserves input requests on same-state metadata updates" do
    input = task() |> transitioned!(:input_required)

    assert {:ok, updated} =
             Task.transition(
               input,
               :input_required,
               [
                 status_message: "Still waiting.",
                 last_updated_at: ~U[2026-09-14 12:00:02Z]
               ],
               validation_options()
             )

    assert updated.input_requests == input.input_requests
    assert updated.status_message == "Still waiting."
  end

  test "records input-request keys for the lifetime of the task" do
    requests = %{"approval" => elicitation_request()}
    options = validation_options(max_input_request_keys_per_task: 2)

    assert {:ok, waiting} =
             Task.transition(
               task(),
               :input_required,
               %{input_requests: requests, last_updated_at: @later},
               options
             )

    assert waiting.input_request_keys == ["approval"]

    assert {:ok, waiting} =
             Task.transition(
               waiting,
               :input_required,
               %{status_message: "Still waiting.", last_updated_at: later(2)},
               options
             )

    assert waiting.input_request_keys == ["approval"]

    assert {:ok, working} =
             Task.transition(
               waiting,
               :working,
               %{last_updated_at: later(3)},
               options
             )

    assert {:error, :invalid_task} =
             Task.transition(
               working,
               :input_required,
               %{input_requests: requests, last_updated_at: later(4)},
               options
             )

    assert {:ok, next_request} =
             Task.transition(
               working,
               :input_required,
               %{
                 input_requests: %{"followup" => elicitation_request()},
                 last_updated_at: later(4)
               },
               options
             )

    assert next_request.input_request_keys == ["approval", "followup"]
    refute Map.has_key?(Task.get_result(next_request), "inputRequestKeys")

    assert {:ok, working} =
             Task.transition(
               next_request,
               :working,
               %{last_updated_at: later(5)},
               options
             )

    assert {:error, :invalid_task} =
             Task.transition(
               working,
               :input_required,
               %{
                 input_requests: %{"third" => elicitation_request()},
                 last_updated_at: later(6)
               },
               options
             )
  end

  test "encodes every detailed task variant against the pinned schema" do
    tasks = [
      task(),
      transitioned!(task(), :input_required),
      transitioned!(task(), :completed),
      transitioned!(task(), :failed),
      transitioned!(task(), :cancelled)
    ]

    for task <- tasks do
      result = Task.get_result(task)
      assert :ok = Conformance.validate(:get_task_result, result, Cache)

      assert :ok =
               Conformance.validate(
                 status_kind(task.status),
                 Map.delete(result, "resultType"),
                 Cache
               )
    end
  end

  test "distinguishes completed tool errors from failed JSON-RPC execution" do
    tool_error =
      Response.tool_error(content: [Response.text("domain failure")])
      |> Response.encode()
      |> Map.put("resultType", "complete")

    completed = task() |> transitioned!(:completed, result: tool_error)
    failed = task() |> transitioned!(:failed)

    assert completed.status == :completed
    assert completed.result["isError"]
    assert failed.status == :failed
    assert %Error{} = failed.error
  end

  test "honors explicitly configured task bounds during creation and transitions" do
    validation_options = [
      cache: Cache,
      max_task_ttl_ms: 777_600_000,
      max_status_message_bytes: 4_096
    ]

    attributes =
      attributes()
      |> Map.put(:ttl_ms, 691_200_000)
      |> Map.put(:status_message, String.duplicate("x", 3_000))

    assert {:error, :invalid_task} = Task.new(attributes)
    assert {:ok, task} = Task.new(attributes, validation_options)

    assert {:ok, updated} =
             Task.transition(
               task,
               :working,
               %{
                 last_updated_at: @later,
                 status_message: String.duplicate("y", 3_000)
               },
               validation_options
             )

    assert updated.ttl_ms == 691_200_000
    assert byte_size(updated.status_message) == 3_000
  end

  test "bounds string request IDs at the shared persistence limit" do
    assert {:ok, %Task{}} =
             Task.new(
               Map.put(
                 attributes(),
                 :request_id,
                 String.duplicate("a", RequestID.max_string_bytes())
               )
             )

    assert {:error, :invalid_task} =
             Task.new(
               Map.put(
                 attributes(),
                 :request_id,
                 String.duplicate("a", RequestID.max_string_bytes() + 1)
               )
             )

    assert {:ok, %Task{}} = Task.new(Map.put(attributes(), :request_id, 42))
  end

  test "rejects invalid timestamps, TTLs, messages, and state payloads" do
    assert {:error, :invalid_task} = Task.new(Map.put(attributes(), :ttl_ms, 0))

    assert {:error, :invalid_task} =
             Task.new(Map.put(attributes(), :status_message, String.duplicate("x", 2_049)))

    assert {:error, :invalid_task} =
             Task.transition(task(), :completed,
               result: nil,
               last_updated_at: @later
             )

    assert {:error, :invalid_task} =
             Task.transition(task(), :working, last_updated_at: ~U[2026-09-14 11:59:59Z])

    assert {:error, :invalid_task} =
             Task.transition(task(), :working, last_updated_at: @created)

    unsafe_integer = 9_007_199_254_740_992

    assert {:error, :invalid_task} =
             Task.new(Map.put(attributes(), :ttl_ms, unsafe_integer),
               max_task_ttl_ms: unsafe_integer
             )

    assert {:error, :invalid_task} =
             Task.new(Map.put(attributes(), :poll_interval_ms, unsafe_integer))
  end

  test "rejects a transition whose detailed wire result exceeds its bound" do
    oversized = %{
      "resultType" => "complete",
      "content" => [%{"type" => "text", "text" => String.duplicate("x", 1_024)}],
      "isError" => false
    }

    assert {:error, :invalid_task} =
             Task.transition(
               task(),
               :completed,
               %{result: oversized, last_updated_at: @later},
               validation_options(
                 max_result_bytes: 512,
                 result_metadata: %{
                   "io.modelcontextprotocol/serverInfo" => %{"name" => "test"}
                 }
               )
             )
  end

  test "rejects JSON-safe state payloads that violate their protocol schemas" do
    assert {:error, :invalid_task} =
             Task.transition(
               task(),
               :input_required,
               %{input_requests: %{"approval" => %{}}, last_updated_at: @later},
               validation_options()
             )

    invalid_output = %{
      "resultType" => "complete",
      "content" => [],
      "structuredContent" => %{"status" => 123},
      "isError" => false
    }

    assert {:error, :invalid_task} =
             Task.transition(
               task(),
               :completed,
               %{result: invalid_output, last_updated_at: @later},
               validation_options(tool: TamaMCP.TestSupport.Tools.InvalidOutput)
             )

    assert {:error, :invalid_task} =
             Task.transition(
               task(),
               :completed,
               %{result: %{}, last_updated_at: @later},
               validation_options()
             )

    assert {:error, :invalid_task} =
             Task.transition(
               task(),
               :failed,
               %{
                 error: %Error{code: "invalid", message: "Execution failed"},
                 last_updated_at: @later
               },
               validation_options()
             )
  end

  test "rejects input requests unsupported by the originating client capabilities" do
    tasks_only = %{task() | client_capabilities: tasks_capability()}

    unsupported = [
      elicitation_request(),
      roots_request(),
      sampling_request(),
      sampling_request(%{"tools" => [sampling_tool()]})
    ]

    for {request, offset} <- Enum.with_index(unsupported, 1) do
      assert {:error, :invalid_task} =
               Task.transition(
                 tasks_only,
                 :input_required,
                 %{
                   input_requests: %{"request-#{offset}" => request},
                   last_updated_at: later(offset)
                 },
                 validation_options()
               )
    end

    form_only = %{task() | client_capabilities: Map.put(tasks_capability(), "elicitation", %{})}

    assert {:error, :invalid_task} =
             Task.transition(
               form_only,
               :input_required,
               %{input_requests: %{"url" => url_elicitation_request()}, last_updated_at: @later},
               validation_options()
             )

    sampling_without_tools = %{
      task()
      | client_capabilities: Map.put(tasks_capability(), "sampling", %{})
    }

    assert {:error, :invalid_task} =
             Task.transition(
               sampling_without_tools,
               :input_required,
               %{
                 input_requests: %{
                   "sampling" => sampling_request(%{"toolChoice" => %{"mode" => "auto"}})
                 },
                 last_updated_at: @later
               },
               validation_options()
             )

    assert {:error, :invalid_task} =
             Task.transition(
               sampling_without_tools,
               :input_required,
               %{
                 input_requests: %{
                   "sampling" => sampling_request(%{"includeContext" => "allServers"})
                 },
                 last_updated_at: @later
               },
               validation_options()
             )
  end

  test "accepts every input request declared by the originating client" do
    capabilities =
      tasks_capability()
      |> Map.put("elicitation", %{"url" => %{}})
      |> Map.put("roots", %{})
      |> Map.put("sampling", %{"context" => %{}, "tools" => %{}})

    capable = %{task() | client_capabilities: capabilities}

    requests = %{
      "url" => url_elicitation_request(),
      "roots" => roots_request(),
      "sampling" =>
        sampling_request(%{
          "includeContext" => "thisServer",
          "tools" => [sampling_tool()]
        })
    }

    assert {:ok, %Task{status: :input_required, input_requests: ^requests}} =
             Task.transition(
               capable,
               :input_required,
               %{input_requests: requests, last_updated_at: @later},
               validation_options()
             )

    basic_sampling = %{
      task()
      | client_capabilities: Map.put(tasks_capability(), "sampling", %{})
    }

    assert {:ok, %Task{status: :input_required}} =
             Task.transition(
               basic_sampling,
               :input_required,
               %{
                 input_requests: %{
                   "sampling" => sampling_request(%{"includeContext" => "none"})
                 },
                 last_updated_at: @later
               },
               validation_options()
             )

    implicit_form = %{
      task()
      | client_capabilities: Map.put(tasks_capability(), "elicitation", %{})
    }

    request = update_in(elicitation_request(), ["params"], &Map.delete(&1, "mode"))

    assert {:ok, %Task{status: :input_required}} =
             Task.transition(
               implicit_form,
               :input_required,
               %{input_requests: %{"form" => request}, last_updated_at: @later},
               validation_options()
             )
  end

  defp task do
    assert {:ok, task} = Task.new(attributes())
    task
  end

  defp attributes do
    %{
      id: "task-phase2-1",
      owner_key: "owner-1",
      method: "tools/call",
      request_id: "call-1",
      created_at: @created,
      last_updated_at: @created,
      ttl_ms: 86_400_000,
      poll_interval_ms: 1_000,
      original_params: %{"name" => "message", "arguments" => %{}},
      client_capabilities: tasks_capability() |> Map.put("elicitation", %{"form" => %{}})
    }
  end

  defp transitioned!(task, status, overrides \\ []) do
    assert {:ok, transitioned} = transition(task, status, overrides)
    transitioned
  end

  defp transition(task, status, overrides \\ [])

  defp transition(task, :working, overrides),
    do:
      Task.transition(
        task,
        :working,
        Keyword.put(overrides, :last_updated_at, next_updated_at(task)),
        validation_options()
      )

  defp transition(task, :input_required, overrides) do
    attributes =
      [input_requests: %{}, last_updated_at: next_updated_at(task)]
      |> Keyword.merge(overrides)

    Task.transition(task, :input_required, attributes, validation_options())
  end

  defp transition(task, :completed, overrides) do
    result = %{"resultType" => "complete", "content" => [], "isError" => false}

    attributes =
      [result: result, last_updated_at: next_updated_at(task)]
      |> Keyword.merge(overrides)

    Task.transition(task, :completed, attributes, validation_options())
  end

  defp transition(task, :failed, overrides) do
    attributes =
      [error: Error.internal("Execution failed"), last_updated_at: next_updated_at(task)]
      |> Keyword.merge(overrides)

    Task.transition(task, :failed, attributes, validation_options())
  end

  defp transition(task, :cancelled, overrides),
    do:
      Task.transition(
        task,
        :cancelled,
        Keyword.put(overrides, :last_updated_at, next_updated_at(task)),
        validation_options()
      )

  defp status_kind(:working), do: :working_task
  defp status_kind(:input_required), do: :input_required_task
  defp status_kind(:completed), do: :completed_task
  defp status_kind(:failed), do: :failed_task
  defp status_kind(:cancelled), do: :cancelled_task

  defp replay_attributes(task) do
    %{
      status_message: task.status_message,
      result: task.result,
      error: task.error,
      last_updated_at: later(60)
    }
  end

  defp later(seconds), do: DateTime.add(@created, seconds, :second)
  defp next_updated_at(task), do: DateTime.add(task.last_updated_at, 1, :second)
  defp validation_options(overrides \\ []), do: Keyword.merge([cache: Cache], overrides)

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

  defp url_elicitation_request do
    %{
      "method" => "elicitation/create",
      "params" => %{
        "message" => "Continue in the browser.",
        "mode" => "url",
        "url" => "https://example.com/continue"
      }
    }
  end

  defp roots_request, do: %{"method" => "roots/list", "params" => %{}}

  defp sampling_request(extra_params \\ %{}) do
    %{
      "method" => "sampling/createMessage",
      "params" =>
        Map.merge(
          %{
            "messages" => [
              %{"role" => "user", "content" => %{"type" => "text", "text" => "Hello"}}
            ],
            "maxTokens" => 100
          },
          extra_params
        )
    }
  end

  defp sampling_tool do
    %{
      "name" => "lookup",
      "description" => "Look something up",
      "inputSchema" => %{"type" => "object"}
    }
  end

  defp tasks_capability do
    %{"extensions" => %{TamaMCP.Protocol.tasks_extension() => %{}}}
  end
end
