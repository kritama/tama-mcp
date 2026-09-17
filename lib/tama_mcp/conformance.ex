defmodule TamaMCP.Conformance do
  @moduledoc """
  Validation helpers for MCP `2026-07-28` contract tests.

  Host applications can use this module in their own test suites to validate
  requests and responses against the same immutable protocol schema vendored by
  TamaMCP. This keeps Tama's composed-server tests on the package's pinned
  protocol revision without exposing the transport's internal codec modules.

  Supported values are complete core requests and responses, subscription
  requests and ordered SSE events, plus the task requests, task results,
  notifications, and detailed task values defined by the pinned Tasks
  extension.

  `run/3` passes each fixture's `%{"headers" => [[name, value]], "body" => map}`
  request to the supplied callback. Task and subscription fixtures may also
  include a bounded `setup` description alongside those wire fields so a host
  contract adapter can arrange the required durable state and stream controls.
  JSON callbacks return `%{status: integer, headers: [{name, value}], body: map}`.
  Stream callbacks instead return ordered decoded `:events` and a `:close`
  classification. Applications may run the bundled reference fixtures or
  supply fixtures with their own authorization header and tool contract.

  `validate_schema_fixtures/3` checks the static positive and negative task
  values bundled beside the HTTP fixtures. These assertions cover invalid
  cross-state payloads that a conforming server must never emit.
  """

  alias TamaMCP.Schema.{Protocol, Tasks}

  @core_fixture_path Path.expand(
                       "../../test/fixtures/protocol/2026-07-28/core.json",
                       __DIR__
                     )
  @tasks_fixture_path Path.expand(
                        "../../test/fixtures/protocol/2026-07-28/tasks.json",
                        __DIR__
                      )
  @subscriptions_fixture_path Path.expand(
                                "../../test/fixtures/protocol/2026-07-28/subscriptions.json",
                                __DIR__
                              )
  @external_resource @core_fixture_path
  @external_resource @tasks_fixture_path
  @external_resource @subscriptions_fixture_path
  @core_fixtures @core_fixture_path |> File.read!() |> Jason.decode!() |> Map.fetch!("fixtures")
  @tasks_document @tasks_fixture_path |> File.read!() |> Jason.decode!()
  @tasks_fixtures Map.fetch!(@tasks_document, "fixtures")
  @task_schema_fixtures Map.get(@tasks_document, "schemaFixtures", [])
  @subscription_fixtures @subscriptions_fixture_path
                         |> File.read!()
                         |> Jason.decode!()
                         |> Map.fetch!("fixtures")

  @kinds %{
    "call_tool_request" => :call_tool_request,
    "call_tool_result" => :call_tool_result,
    "call_tool_response" => :call_tool_response,
    "discover_request" => :discover_request,
    "discover_result" => :discover_result,
    "discover_response" => :discover_response,
    "error_response" => :error_response,
    "list_tools_request" => :list_tools_request,
    "list_tools_result" => :list_tools_result,
    "list_tools_response" => :list_tools_response,
    "result_response" => :result_response,
    "subscriptions_acknowledged_notification" => :subscriptions_acknowledged_notification,
    "subscriptions_listen_request" => :subscriptions_listen_request,
    "subscriptions_listen_result" => :subscriptions_listen_result,
    "subscriptions_listen_response" => :subscriptions_listen_response,
    "task_profile" => :task_profile,
    "cancel_task_request" => :cancel_task_request,
    "cancel_task_result" => :cancel_task_result,
    "cancelled_task" => :cancelled_task,
    "completed_task" => :completed_task,
    "create_task_result" => :create_task_result,
    "detailed_task" => :detailed_task,
    "failed_task" => :failed_task,
    "get_task_request" => :get_task_request,
    "get_task_result" => :get_task_result,
    "input_required_task" => :input_required_task,
    "task_status_notification" => :task_status_notification,
    "task_status_notification_params" => :task_status_notification_params,
    "task_subscription_acknowledged_notifications" =>
      :task_subscription_acknowledged_notifications,
    "task_subscription_notifications" => :task_subscription_notifications,
    "update_task_request" => :update_task_request,
    "update_task_result" => :update_task_result,
    "working_task" => :working_task
  }

  @type kind ::
          :call_tool_request
          | :call_tool_result
          | :call_tool_response
          | :discover_request
          | :discover_result
          | :discover_response
          | :error_response
          | :list_tools_request
          | :list_tools_result
          | :list_tools_response
          | :result_response
          | :subscriptions_acknowledged_notification
          | :subscriptions_listen_request
          | :subscriptions_listen_result
          | :subscriptions_listen_response
          | :task_profile
          | :cancel_task_request
          | :cancel_task_result
          | :cancelled_task
          | :completed_task
          | :create_task_result
          | :detailed_task
          | :failed_task
          | :get_task_request
          | :get_task_result
          | :input_required_task
          | :task_status_notification
          | :task_status_notification_params
          | :task_subscription_acknowledged_notifications
          | :task_subscription_notifications
          | :update_task_request
          | :update_task_result
          | :working_task

  @doc "Validates a protocol value against the vendored MCP schema."
  @spec validate(kind(), term(), module(), keyword()) :: :ok | {:error, [String.t()]}
  def validate(kind, value, cache, cache_options \\ [])

  def validate(:task_profile, value, cache, cache_options) do
    with :ok <- Tasks.validate(:get_task_result, value, cache, cache_options) do
      validate_task_state(value, cache, cache_options)
    end
  end

  def validate(:task_status_notification_params, value, cache, cache_options) do
    with :ok <- Tasks.validate(:task_status_notification_params, value, cache, cache_options) do
      validate_task_state(value, cache, cache_options)
    end
  end

  def validate(
        :task_status_notification,
        %{"params" => params} = value,
        cache,
        cache_options
      ) do
    with :ok <- Tasks.validate(:task_status_notification, value, cache, cache_options) do
      validate_task_state(params, cache, cache_options)
    end
  end

  def validate(kind, value, cache, cache_options) do
    if kind in task_kinds(),
      do: Tasks.validate(kind, value, cache, cache_options),
      else: Protocol.validate(kind, value, cache, cache_options)
  end

  @doc "Validates a protocol value, raising a schema validation exception when it is invalid."
  @spec validate!(kind(), term(), module(), keyword()) :: :ok
  def validate!(kind, value, cache, cache_options \\ []) do
    case validate(kind, value, cache, cache_options) do
      :ok -> :ok
      {:error, details} -> raise TamaMCP.Schema.Error, message: Enum.join(details, "; ")
    end
  end

  @doc "Returns the immutable core wire fixtures bundled with TamaMCP."
  @spec fixtures() :: [map()]
  def fixtures, do: @core_fixtures

  @doc "Returns the immutable core wire fixtures bundled with TamaMCP."
  @spec core_fixtures() :: [map()]
  def core_fixtures, do: @core_fixtures

  @doc "Returns the immutable Tasks extension wire fixtures bundled with TamaMCP."
  @spec tasks_fixtures() :: [map()]
  def tasks_fixtures, do: @tasks_fixtures

  @doc "Returns static positive and negative Tasks schema fixtures bundled with TamaMCP."
  @spec task_schema_fixtures() :: [map()]
  def task_schema_fixtures, do: @task_schema_fixtures

  @doc "Returns the immutable subscription wire fixtures bundled with TamaMCP."
  @spec subscription_fixtures() :: [map()]
  def subscription_fixtures, do: @subscription_fixtures

  @doc "Returns the complete immutable core and Tasks fixture set."
  @spec all_fixtures() :: [map()]
  def all_fixtures, do: @core_fixtures ++ @tasks_fixtures ++ @subscription_fixtures

  @doc "Validates static Tasks values against their expected vendored schema outcomes."
  @spec validate_schema_fixtures(module(), [map()], keyword()) ::
          :ok | {:error, [String.t()]}
  def validate_schema_fixtures(
        cache,
        fixtures \\ @task_schema_fixtures,
        cache_options \\ []
      )
      when is_atom(cache) and is_list(fixtures) and is_list(cache_options) do
    errors =
      Enum.flat_map(fixtures, fn fixture ->
        []
        |> verify_schema(
          fixture["schema"],
          fixture["valid"],
          fixture["value"],
          cache,
          cache_options
        )
        |> Enum.map(&"#{fixture["name"]}: #{&1}")
      end)

    if errors == [], do: :ok, else: {:error, errors}
  end

  @doc "Runs every supplied fixture through an application request callback."
  @spec run((map() -> map()), module(), [map()], keyword()) :: :ok | {:error, [String.t()]}
  def run(request, cache, fixtures \\ @core_fixtures, cache_options \\ [])

  def run(request, cache, fixtures, cache_options)
      when is_function(request, 1) and is_atom(cache) and is_list(fixtures) and
             is_list(cache_options) do
    errors =
      Enum.flat_map(fixtures, fn fixture ->
        case verify(fixture, request.(fixture["request"]), cache, cache_options) do
          :ok -> []
          {:error, details} -> Enum.map(details, &"#{fixture["name"]}: #{&1}")
        end
      end)

    if errors == [], do: :ok, else: {:error, errors}
  end

  @doc "Verifies one normalized response and both protocol schema expectations."
  @spec verify(map(), map(), module(), keyword()) :: :ok | {:error, [String.t()]}
  def verify(fixture, response, cache, cache_options \\ [])

  def verify(fixture, response, cache, cache_options)
      when is_map(fixture) and is_map(response) and is_atom(cache) and is_list(cache_options) do
    expected = fixture["expected"]

    if Map.has_key?(expected, "events") do
      verify_stream(fixture, response, cache, cache_options)
    else
      verify_response(fixture, response, cache, cache_options)
    end
  end

  defp verify_response(fixture, response, cache, cache_options) do
    expected = fixture["expected"]

    []
    |> compare("status", expected["status"], response[:status])
    |> compare("body", expected["body"], response[:body])
    |> compare_headers(expected["headers"], response[:headers])
    |> verify_schema(
      fixture["requestSchema"],
      fixture["requestValid"],
      fixture["request"]["body"],
      cache,
      cache_options
    )
    |> verify_request_extension(fixture, cache, cache_options)
    |> verify_optional_schema(
      fixture["responseEnvelopeSchema"],
      Map.get(fixture, "responseEnvelopeValid", true),
      response[:body],
      cache,
      cache_options
    )
    |> verify_schema(
      fixture["responseSchema"],
      Map.get(fixture, "responseValid", true),
      at_path(response[:body], fixture["responsePath"]),
      cache,
      cache_options
    )
    |> case do
      [] -> :ok
      errors -> {:error, Enum.reverse(errors)}
    end
  end

  defp verify_stream(fixture, response, cache, cache_options) do
    expected = fixture["expected"]

    []
    |> compare("status", expected["status"], response[:status])
    |> compare("events", expected["events"], response[:events])
    |> compare("close", expected["close"], response[:close])
    |> compare_headers(expected["headers"], response[:headers])
    |> verify_schema(
      fixture["requestSchema"],
      fixture["requestValid"],
      fixture["request"]["body"],
      cache,
      cache_options
    )
    |> verify_request_extension(fixture, cache, cache_options)
    |> verify_event_schemas(fixture, response[:events], cache, cache_options)
    |> case do
      [] -> :ok
      errors -> {:error, Enum.reverse(errors)}
    end
  end

  defp verify_request_extension(errors, fixture, cache, cache_options) do
    case fixture["requestExtensionSchema"] do
      nil ->
        errors

      schema ->
        verify_schema(
          errors,
          schema,
          Map.get(fixture, "requestExtensionValid", true),
          at_path(fixture["request"]["body"], fixture["requestExtensionPath"]),
          cache,
          cache_options
        )
    end
  end

  defp verify_event_schemas(errors, fixture, events, cache, cache_options) do
    Enum.reduce(fixture["eventSchemas"] || [], errors, fn check, acc ->
      event = if is_list(events), do: Enum.at(events, check["index"]), else: nil
      value = at_path(event, check["path"])

      verify_schema(
        acc,
        check["schema"],
        Map.get(check, "valid", true),
        value,
        cache,
        cache_options
      )
    end)
  end

  defp compare(errors, _field, expected, actual) when expected == actual, do: errors
  defp compare(errors, field, _expected, _actual), do: ["unexpected #{field}" | errors]

  defp compare_headers(errors, expected, actual) do
    headers = Map.new(actual || [], fn {name, value} -> {String.downcase(name), value} end)

    Enum.reduce(expected || %{}, errors, fn {name, value}, acc ->
      compare(acc, "header #{name}", value, headers[String.downcase(name)])
    end)
  end

  defp verify_schema(errors, name, valid?, value, cache, cache_options) do
    result = validate(Map.fetch!(@kinds, name), value, cache, cache_options)

    case {valid?, result} do
      {true, :ok} -> errors
      {false, {:error, _details}} -> errors
      {true, {:error, _details}} -> ["#{name} does not match the pinned schema" | errors]
      {false, :ok} -> ["#{name} unexpectedly matches the pinned schema" | errors]
    end
  end

  defp verify_optional_schema(errors, nil, _valid?, _value, _cache, _cache_options),
    do: errors

  defp verify_optional_schema(errors, name, valid?, value, cache, cache_options),
    do: verify_schema(errors, name, valid?, value, cache, cache_options)

  defp task_kinds do
    [
      :cancel_task_request,
      :cancel_task_result,
      :cancelled_task,
      :completed_task,
      :create_task_result,
      :detailed_task,
      :failed_task,
      :get_task_request,
      :get_task_result,
      :input_required_task,
      :task_status_notification,
      :task_status_notification_params,
      :task_subscription_acknowledged_notifications,
      :task_subscription_notifications,
      :update_task_request,
      :update_task_result,
      :working_task
    ]
  end

  defp validate_task_payload_keys(%{"status" => status} = value) do
    expected =
      case status do
        "working" -> []
        "input_required" -> ["inputRequests"]
        "completed" -> ["result"]
        "failed" -> ["error"]
        "cancelled" -> []
        _unsupported -> :invalid
      end

    present = Enum.filter(["inputRequests", "result", "error"], &Map.has_key?(value, &1))

    if present == expected do
      :ok
    else
      {:error, ["#{status} task has invalid state-specific payload fields"]}
    end
  end

  defp validate_task_payload_keys(_value), do: {:error, ["task status is missing"]}

  defp validate_task_state(value, cache, options) do
    with :ok <- validate_task_payload_keys(value) do
      validate_task_payload(value, cache, options)
    end
  end

  defp validate_task_payload(
         %{"status" => "input_required", "inputRequests" => requests},
         cache,
         options
       ),
       do: Tasks.validate(:input_requests, requests, cache, options)

  defp validate_task_payload(%{"status" => "completed", "result" => result}, cache, options),
    do: Protocol.validate(:call_tool_result, result, cache, options)

  defp validate_task_payload(%{"status" => "failed", "error" => error}, cache, options),
    do: Tasks.validate(:error, error, cache, options)

  defp validate_task_payload(_value, _cache, _options), do: :ok

  defp at_path(value, nil), do: value
  defp at_path(value, path) when is_list(path), do: get_in(value, path)
end
