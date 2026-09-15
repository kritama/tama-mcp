defmodule TamaMCP.TestSupport.Tasks.Fixtures do
  @moduledoc false

  alias TamaMCP.Protocol

  @version Protocol.version()
  @created "2026-09-14T12:00:00Z"
  @server_meta %{
    "io.modelcontextprotocol/serverInfo" => %{
      "name" => "tama-mcp-task-required",
      "version" => "0.0.1-test"
    }
  }

  def document do
    %{
      "fixtures" => http_fixtures(),
      "schemaFixtures" => schema_fixtures()
    }
  end

  defp http_fixtures do
    [
      task_creation(),
      task_creation_missing_capability(),
      get_task(:working),
      get_task(:input_required),
      get_task(:completed),
      get_task(:failed),
      get_task(:cancelled),
      get_missing_task(),
      get_unauthorized_task(),
      get_task_header_mismatch(),
      get_task_missing_capability(),
      update_task(:partial),
      update_task(:complete),
      update_missing_task(),
      update_invalid_responses(),
      update_working_task(),
      cancel_task(:working),
      cancel_missing_task(),
      cancel_task(:completed),
      cancel_task(:failed),
      cancel_task(:cancelled),
      unsupported_task_method("tasks/result"),
      unsupported_task_method("tasks/list")
    ]
  end

  defp task_creation do
    fixture(
      "tools/call task creation",
      "call_tool_request",
      request(
        "tools/call",
        "task-create-1",
        %{"name" => "task_required", "arguments" => %{"value" => "hello"}},
        name: "task_required"
      ),
      success(
        "task-create-1",
        task_value("task-phase2-1", :working, result_type: "task")
      ),
      "create_task_result"
    )
  end

  defp task_creation_missing_capability do
    fixture(
      "tools/call task creation missing capability",
      "call_tool_request",
      request(
        "tools/call",
        "task-create-missing-capability",
        %{"name" => "task_required", "arguments" => %{"value" => "hello"}},
        name: "task_required",
        tasks: false
      ),
      error(
        "task-create-missing-capability",
        400,
        -32_021,
        "Server requires the extensions capability for this request",
        %{
          "requiredCapabilities" => %{
            "extensions" => %{Protocol.tasks_extension() => %{}}
          }
        }
      ),
      "error_response",
      envelope: false
    )
  end

  defp get_task(status) do
    task_id = "task-get-#{status}"
    task = task_value(task_id, status)

    fixture(
      "tasks/get #{Protocol.task_status(status)}",
      "get_task_request",
      request("tasks/get", "get-#{status}", %{"taskId" => task_id},
        name: task_id,
        setup: %{"task" => task}
      ),
      success("get-#{status}", task),
      "get_task_result"
    )
  end

  defp get_missing_task do
    task_id = "missing-task"

    fixture(
      "tasks/get unknown task",
      "get_task_request",
      request("tasks/get", "get-missing", %{"taskId" => task_id}, name: task_id),
      not_found("get-missing"),
      "error_response",
      envelope: false
    )
  end

  defp get_unauthorized_task do
    task_id = "task-get-unauthorized"

    fixture(
      "tasks/get unauthorized task",
      "get_task_request",
      request("tasks/get", "get-unauthorized", %{"taskId" => task_id},
        name: task_id,
        token: "other",
        setup: %{"task" => task_value(task_id, :working)}
      ),
      not_found("get-unauthorized"),
      "error_response",
      envelope: false
    )
  end

  defp get_task_header_mismatch do
    task_id = "task-get-header-mismatch"

    fixture(
      "tasks/get header and body task ID disagreement",
      "get_task_request",
      request("tasks/get", "get-header-mismatch", %{"taskId" => task_id}, name: "different-task"),
      error(
        "get-header-mismatch",
        400,
        -32_020,
        ~s(Header mismatch: Mcp-Name header "different-task" does not match "#{task_id}")
      ),
      "error_response",
      envelope: false
    )
  end

  defp get_task_missing_capability do
    task_id = "task-get-no-capability"

    fixture(
      "tasks/get missing capability",
      "get_task_request",
      request("tasks/get", "get-no-capability", %{"taskId" => task_id},
        name: task_id,
        tasks: false
      ),
      error(
        "get-no-capability",
        400,
        -32_021,
        "Server requires the extensions capability for this request",
        %{
          "requiredCapabilities" => %{
            "extensions" => %{Protocol.tasks_extension() => %{}}
          }
        }
      ),
      "error_response",
      envelope: false
    )
  end

  defp update_task(mode) do
    task_id = "task-update-#{mode}"
    requests = input_requests(mode)
    responses = input_responses(mode)

    fixture(
      "tasks/update #{mode} input responses",
      "update_task_request",
      request(
        "tasks/update",
        "update-#{mode}",
        %{"taskId" => task_id, "inputResponses" => responses},
        name: task_id,
        setup: %{
          "task" => task_value(task_id, :input_required, input_requests: requests)
        }
      ),
      success("update-#{mode}", %{"resultType" => "complete"}),
      "update_task_result"
    )
  end

  defp update_missing_task do
    task_id = "task-update-missing"

    fixture(
      "tasks/update invalid task",
      "update_task_request",
      request(
        "tasks/update",
        "update-missing",
        %{"taskId" => task_id, "inputResponses" => %{}},
        name: task_id
      ),
      not_found("update-missing"),
      "error_response",
      envelope: false
    )
  end

  defp update_invalid_responses do
    task_id = "task-update-invalid-responses"

    fixture(
      "tasks/update invalid response shape",
      "update_task_request",
      request(
        "tasks/update",
        "update-invalid-responses",
        %{"taskId" => task_id, "inputResponses" => []},
        name: task_id
      ),
      error(
        "update-invalid-responses",
        400,
        -32_602,
        "Request does not match the protocol schema: " <>
          "At /params/inputResponses: Expected type object, got array"
      ),
      "error_response",
      request_valid: false,
      envelope: false
    )
  end

  defp update_working_task do
    task_id = "task-update-working"

    fixture(
      "tasks/update outside input_required",
      "update_task_request",
      request(
        "tasks/update",
        "update-working",
        %{"taskId" => task_id, "inputResponses" => %{}},
        name: task_id,
        setup: %{"task" => task_value(task_id, :working)}
      ),
      invalid_state("update-working"),
      "error_response",
      envelope: false
    )
  end

  defp cancel_task(:working) do
    task_id = "task-cancel-working"

    fixture(
      "tasks/cancel cooperative acknowledgement",
      "cancel_task_request",
      request("tasks/cancel", "cancel-working", %{"taskId" => task_id},
        name: task_id,
        setup: %{"task" => task_value(task_id, :working)}
      ),
      success("cancel-working", %{"resultType" => "complete"}),
      "cancel_task_result"
    )
  end

  defp cancel_task(status) do
    task_id = "task-cancel-#{status}"

    fixture(
      "tasks/cancel race with #{Protocol.task_status(status)}",
      "cancel_task_request",
      request("tasks/cancel", "cancel-#{status}", %{"taskId" => task_id},
        name: task_id,
        setup: %{"task" => task_value(task_id, status)}
      ),
      invalid_state("cancel-#{status}"),
      "error_response",
      envelope: false
    )
  end

  defp cancel_missing_task do
    task_id = "task-cancel-missing"

    fixture(
      "tasks/cancel invalid task",
      "cancel_task_request",
      request("tasks/cancel", "cancel-missing", %{"taskId" => task_id}, name: task_id),
      not_found("cancel-missing"),
      "error_response",
      envelope: false
    )
  end

  defp unsupported_task_method(method) do
    fixture(
      "#{method} remains rejected",
      "get_task_request",
      request(method, "unsupported-#{String.replace(method, "/", "-")}", %{}),
      error(
        "unsupported-#{String.replace(method, "/", "-")}",
        404,
        -32_601,
        "Method not found: #{method}"
      ),
      "error_response",
      request_valid: false,
      envelope: false
    )
  end

  defp schema_fixtures do
    valid =
      for status <- [:working, :input_required, :completed, :failed, :cancelled] do
        %{
          "name" => "#{status} detailed task profile",
          "schema" => "task_profile",
          "valid" => true,
          "value" => task_value("schema-#{status}", status)
        }
      end

    invalid = [
      invalid_profile(:working, "result", completed_result()),
      invalid_profile(:input_required, "result", completed_result()),
      invalid_profile(:completed, "inputRequests", input_requests(:complete)),
      invalid_profile(:failed, "result", completed_result()),
      invalid_profile(:cancelled, "error", failed_error())
    ]

    unsafe_integer =
      task_value("schema-unsafe-integer", :working)
      |> Map.put("ttlMs", 9_007_199_254_740_992)

    valid ++
      invalid ++
      [
        %{
          "name" => "task profile rejects an unsafe integer TTL",
          "schema" => "task_profile",
          "valid" => false,
          "value" => unsafe_integer
        }
      ]
  end

  defp invalid_profile(status, key, value) do
    %{
      "name" => "#{status} task rejects cross-state #{key}",
      "schema" => "task_profile",
      "valid" => false,
      "value" => Map.put(task_value("schema-invalid-#{status}", status), key, value)
    }
  end

  defp fixture(name, request_schema, request, expected, response_schema, options \\ []) do
    %{
      "name" => name,
      "requestSchema" => request_schema,
      "requestValid" => Keyword.get(options, :request_valid, true),
      "responseSchema" => response_schema,
      "request" => request,
      "expected" => expected
    }
    |> put_if(Keyword.get(options, :envelope, true), "responseEnvelopeSchema", "result_response")
    |> put_if(Keyword.get(options, :envelope, true), "responsePath", ["result"])
  end

  defp request(method, id, params, options \\ []) do
    params = Map.put(params, "_meta", meta(Keyword.get(options, :tasks, true)))

    headers =
      [
        ["mcp-protocol-version", @version],
        ["mcp-method", method],
        ["content-type", "application/json"],
        ["accept", "application/json, text/event-stream"],
        ["x-test-token", Keyword.get(options, :token, "ok")]
      ]
      |> maybe_name(Keyword.get(options, :name))

    %{
      "headers" => headers,
      "body" => %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}
    }
    |> put_if(Keyword.has_key?(options, :setup), "setup", Keyword.get(options, :setup))
  end

  defp meta(tasks?) do
    extensions = if tasks?, do: %{Protocol.tasks_extension() => %{}}, else: %{}

    %{
      Protocol.meta_key(:protocol_version) => @version,
      Protocol.meta_key(:client_capabilities) => %{"extensions" => extensions},
      Protocol.meta_key(:client_info) => %{"name" => "test-client", "version" => "1.0.0"}
    }
  end

  defp task_value(task_id, status, options \\ []) do
    updated_at =
      case status do
        :working -> @created
        :input_required -> "2026-09-14T12:00:01Z"
        :completed -> "2026-09-14T12:00:02Z"
        :failed -> "2026-09-14T12:00:03Z"
        :cancelled -> "2026-09-14T12:00:04Z"
      end

    %{
      "resultType" => Keyword.get(options, :result_type, "complete"),
      "taskId" => task_id,
      "status" => Protocol.task_status(status),
      "statusMessage" => "Queued for durable execution.",
      "createdAt" => @created,
      "lastUpdatedAt" => updated_at,
      "ttlMs" => 86_400_000,
      "pollIntervalMs" => 1_000
    }
    |> state_payload(status, options)
  end

  defp state_payload(task, :working, _options), do: task

  defp state_payload(task, :input_required, options) do
    Map.put(
      task,
      "inputRequests",
      Keyword.get(options, :input_requests, input_requests(:complete))
    )
  end

  defp state_payload(task, :completed, _options),
    do: Map.put(task, "result", completed_result())

  defp state_payload(task, :failed, _options), do: Map.put(task, "error", failed_error())
  defp state_payload(task, :cancelled, _options), do: task

  defp input_requests(:partial) do
    %{
      "approval" => elicitation_request("Approve?"),
      "followup" => elicitation_request("Continue?")
    }
  end

  defp input_requests(_mode), do: %{"approval" => elicitation_request("Approve?")}

  defp input_responses(:partial) do
    %{"approval" => %{"action" => "accept", "content" => %{"approved" => true}}}
  end

  defp input_responses(:complete), do: %{"approval" => %{"action" => "decline"}}

  defp elicitation_request(message) do
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
    %{
      "resultType" => "complete",
      "content" => [%{"type" => "text", "text" => "done"}],
      "isError" => false
    }
  end

  defp failed_error, do: %{"code" => -32_603, "message" => "Durable execution failed"}

  defp success(id, result) do
    result = Map.put(result, "_meta", @server_meta)

    %{
      "status" => 200,
      "headers" => %{"content-type" => "application/json; charset=utf-8"},
      "body" => %{"jsonrpc" => "2.0", "id" => id, "result" => result}
    }
  end

  defp error(id, status, code, message, data \\ nil) do
    error = %{"code" => code, "message" => message} |> put_if(not is_nil(data), "data", data)

    %{
      "status" => status,
      "headers" => %{"content-type" => "application/json; charset=utf-8"},
      "body" => %{"jsonrpc" => "2.0", "id" => id, "error" => error}
    }
  end

  defp not_found(id), do: error(id, 400, -32_602, "Task was not found")

  defp invalid_state(id) do
    error(id, 400, -32_602, "Task is not in a state that accepts this operation")
  end

  defp maybe_name(headers, nil), do: headers
  defp maybe_name(headers, name), do: List.insert_at(headers, 2, ["mcp-name", name])

  defp put_if(map, true, key, value), do: Map.put(map, key, value)
  defp put_if(map, false, _key, _value), do: map
end
