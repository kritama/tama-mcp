defmodule TamaMCP.TestSupport.Subscriptions.Fixtures do
  @moduledoc false

  alias TamaMCP.Protocol

  @version Protocol.version()
  @subscription_key Protocol.meta_key(:subscription_id)
  @server_meta %{
    "io.modelcontextprotocol/serverInfo" => %{
      "name" => "tama-mcp-task-required",
      "version" => "0.0.1-test"
    }
  }

  def document do
    %{
      "fixtures" => [
        delivery(),
        authorized_subset(),
        reconnect(),
        missing_capability(),
        expired_credential(),
        stale_policy(),
        overflow()
      ]
    }
  end

  defp delivery do
    id = "listen-delivery"
    task = task("subscription-working", :working)

    stream_fixture(
      "subscriptions/listen acknowledgement and task delivery",
      request(id, [task["taskId"]], setup: %{"tasks" => [task], "publish" => task["taskId"]}),
      [acknowledgement(id, [task["taskId"]]), notification(id, task), closing(id)]
    )
  end

  defp authorized_subset do
    id = "listen-authorized-subset"
    own = task("subscription-own", :working)
    other = Map.put(task("subscription-other", :working), "ownerKey", "other-owner")

    stream_fixture(
      "subscriptions/listen authorized task subset",
      request(id, ["missing", own["taskId"], other["taskId"], own["taskId"]],
        setup: %{"tasks" => [own, other]}
      ),
      [acknowledgement(id, [own["taskId"]]), closing(id)]
    )
  end

  defp reconnect do
    id = "listen-reconnect"
    task = task("subscription-completed", :completed)

    stream_fixture(
      "subscriptions/listen reconnect after tasks/get reconciliation",
      request(id, [task["taskId"]],
        setup: %{"tasks" => [task], "reconcile" => task["taskId"], "publish" => task["taskId"]}
      ),
      [acknowledgement(id, [task["taskId"]]), notification(id, task), closing(id)]
    )
  end

  defp missing_capability do
    id = "listen-missing-capability"

    json_fixture(
      "subscriptions/listen missing Tasks capability",
      request(id, ["subscription-working"], tasks: false),
      error(
        id,
        400,
        -32_021,
        "Server requires the extensions capability for this request",
        %{
          "requiredCapabilities" => %{
            "extensions" => %{Protocol.tasks_extension() => %{}}
          }
        }
      )
    )
  end

  defp expired_credential do
    id = "listen-expired"

    json_fixture(
      "subscriptions/listen expired credential",
      request(id, [], token: "expired", setup: %{"authorization" => "expired"}),
      error(id, 401, -32_600, "Credential has expired")
    )
  end

  defp stale_policy do
    id = "listen-stale-policy"
    task = task("subscription-stale", :working)

    subscription_request =
      request(id, [task["taskId"]], setup: %{"tasks" => [task], "close" => "policy_invalidation"})

    stream_fixture(
      "subscriptions/listen stale policy closes stream",
      subscription_request,
      [acknowledgement(id, [task["taskId"]]), closing(id)]
    )
  end

  defp overflow do
    id = "listen-overflow"
    task = task("subscription-overflow", :working)

    stream_fixture(
      "subscriptions/listen overflow closes stream",
      request(id, [task["taskId"]], setup: %{"tasks" => [task], "close" => "overflow"}),
      [acknowledgement(id, [task["taskId"]]), closing(id)]
    )
  end

  defp stream_fixture(name, request, events) do
    %{
      "name" => name,
      "requestSchema" => "subscriptions_listen_request",
      "requestValid" => true,
      "requestExtensionSchema" => "task_subscription_notifications",
      "requestExtensionPath" => ["params", "notifications"],
      "eventSchemas" => event_schemas(events),
      "request" => request,
      "expected" => %{
        "status" => 200,
        "headers" => %{
          "content-type" => "text/event-stream; charset=utf-8",
          "cache-control" => "no-cache"
        },
        "events" => events,
        "close" => "graceful"
      }
    }
  end

  defp json_fixture(name, request, expected) do
    %{
      "name" => name,
      "requestSchema" => "subscriptions_listen_request",
      "requestValid" => true,
      "requestExtensionSchema" => "task_subscription_notifications",
      "requestExtensionPath" => ["params", "notifications"],
      "responseSchema" => "error_response",
      "request" => request,
      "expected" => expected
    }
  end

  defp event_schemas(events) do
    events
    |> Enum.with_index()
    |> Enum.flat_map(fn {event, index} ->
      case event do
        %{"method" => method, "params" => %{"notifications" => _notifications}}
        when method == "notifications/subscriptions/acknowledged" ->
          [
            %{"index" => index, "schema" => "subscriptions_acknowledged_notification"},
            %{
              "index" => index,
              "path" => ["params", "notifications"],
              "schema" => "task_subscription_acknowledged_notifications"
            }
          ]

        %{"method" => "notifications/tasks"} ->
          [%{"index" => index, "schema" => "task_status_notification"}]

        %{"result" => _result} ->
          [%{"index" => index, "schema" => "subscriptions_listen_response"}]
      end
    end)
  end

  defp request(id, task_ids, options) do
    extensions =
      if Keyword.get(options, :tasks, true),
        do: %{Protocol.tasks_extension() => %{}},
        else: %{}

    value = %{
      "headers" => [
        ["mcp-protocol-version", @version],
        ["mcp-method", Protocol.method(:subscriptions_listen)],
        ["content-type", "application/json"],
        ["accept", "application/json, text/event-stream"],
        ["x-test-token", Keyword.get(options, :token, "ok")]
      ],
      "body" => %{
        "jsonrpc" => "2.0",
        "id" => id,
        "method" => Protocol.method(:subscriptions_listen),
        "params" => %{
          "_meta" => %{
            Protocol.meta_key(:protocol_version) => @version,
            Protocol.meta_key(:client_capabilities) => %{"extensions" => extensions},
            Protocol.meta_key(:client_info) => %{"name" => "test-client", "version" => "1.0.0"}
          },
          "notifications" => %{"taskIds" => task_ids}
        }
      }
    }

    case Keyword.fetch(options, :setup) do
      {:ok, setup} -> Map.put(value, "setup", setup)
      :error -> value
    end
  end

  defp acknowledgement(id, task_ids) do
    %{
      "jsonrpc" => "2.0",
      "method" => "notifications/subscriptions/acknowledged",
      "params" => %{
        "_meta" => %{@subscription_key => id},
        "notifications" => %{"taskIds" => task_ids}
      }
    }
  end

  defp notification(id, task) do
    %{
      "jsonrpc" => "2.0",
      "method" => "notifications/tasks",
      "params" =>
        task
        |> Map.drop(["ownerKey", "resultType"])
        |> Map.put("_meta", %{@subscription_key => id})
    }
  end

  defp closing(id) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "result" => %{
        "resultType" => "complete",
        "_meta" => Map.put(@server_meta, @subscription_key, id)
      }
    }
  end

  defp task(id, status) do
    %{
      "resultType" => "complete",
      "taskId" => id,
      "status" => Atom.to_string(status),
      "statusMessage" => "Task status is available.",
      "createdAt" => "2026-09-15T12:00:00Z",
      "lastUpdatedAt" =>
        if(status == :working, do: "2026-09-15T12:00:00Z", else: "2026-09-15T12:00:01Z"),
      "ttlMs" => 86_400_000,
      "pollIntervalMs" => 1_000
    }
    |> put_result(status)
  end

  defp put_result(task, :completed) do
    Map.put(task, "result", %{
      "resultType" => "complete",
      "content" => [%{"type" => "text", "text" => "done"}],
      "isError" => false
    })
  end

  defp put_result(task, _status), do: task

  defp error(id, status, code, message, data \\ nil) do
    error = %{"code" => code, "message" => message}
    error = if is_nil(data), do: error, else: Map.put(error, "data", data)

    %{
      "status" => status,
      "headers" => %{"content-type" => "application/json; charset=utf-8"},
      "body" => %{"jsonrpc" => "2.0", "id" => id, "error" => error}
    }
  end
end
