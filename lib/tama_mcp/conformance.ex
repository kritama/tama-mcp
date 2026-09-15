defmodule TamaMCP.Conformance do
  @moduledoc """
  Validation helpers for MCP `2026-07-28` contract tests.

  Host applications can use this module in their own test suites to validate
  requests and responses against the same immutable protocol schema vendored by
  TamaMCP. This keeps Tama's composed-server tests on the package's pinned
  protocol revision without exposing the transport's internal codec modules.

  Supported values are complete core requests and responses plus the task
  requests, task results, and detailed task values defined by the pinned Tasks
  extension.

  `run/2` passes each fixture's `%{"headers" => [[name, value]], "body" => map}`
  request to the supplied callback. The callback returns
  `%{status: integer, headers: [{name, value}], body: map}`. Applications may
  run the bundled reference fixtures or supply fixtures with their own
  authorization header and synchronous tool contract.
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
  @external_resource @core_fixture_path
  @external_resource @tasks_fixture_path
  @core_fixtures @core_fixture_path |> File.read!() |> Jason.decode!() |> Map.fetch!("fixtures")
  @tasks_fixtures @tasks_fixture_path |> File.read!() |> Jason.decode!() |> Map.fetch!("fixtures")

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
          | :update_task_request
          | :update_task_result
          | :working_task

  @doc "Validates a protocol value against the vendored MCP schema."
  @spec validate(kind(), term(), module(), keyword()) :: :ok | {:error, [String.t()]}
  def validate(kind, value, cache, cache_options \\ []) do
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

  @doc "Returns the complete immutable core and Tasks fixture set."
  @spec all_fixtures() :: [map()]
  def all_fixtures, do: @core_fixtures ++ @tasks_fixtures

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
    |> verify_schema(
      fixture["responseSchema"],
      true,
      at_path(response[:body], fixture["responsePath"]),
      cache,
      cache_options
    )
    |> case do
      [] -> :ok
      errors -> {:error, Enum.reverse(errors)}
    end
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
      :update_task_request,
      :update_task_result,
      :working_task
    ]
  end

  defp at_path(value, nil), do: value
  defp at_path(value, path) when is_list(path), do: get_in(value, path)
end
