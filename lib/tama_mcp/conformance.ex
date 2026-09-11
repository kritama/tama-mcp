defmodule TamaMCP.Conformance do
  @moduledoc """
  Validation helpers for MCP `2026-07-28` contract tests.

  Host applications can use this module in their own test suites to validate
  requests and responses against the same immutable protocol schema vendored by
  TamaMCP. This keeps Tama's composed-server tests on the package's pinned
  protocol revision without exposing the transport's internal codec modules.

  Supported values are complete requests, complete responses, and the result
  objects emitted by the Phase 1 methods.

  `run/2` passes each fixture's `%{"headers" => [[name, value]], "body" => map}`
  request to the supplied callback. The callback returns
  `%{status: integer, headers: [{name, value}], body: map}`. Applications may
  run the bundled reference fixtures or supply fixtures with their own
  authorization header and synchronous tool contract.
  """

  alias TamaMCP.Schema.Protocol

  @fixture_path Path.expand("../../test/fixtures/protocol/2026-07-28/phase1.json", __DIR__)
  @external_resource @fixture_path
  @fixtures @fixture_path |> File.read!() |> Jason.decode!() |> Map.fetch!("fixtures")

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
    "list_tools_response" => :list_tools_response
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

  @doc "Validates a protocol value against the vendored MCP schema."
  @spec validate(kind(), term()) :: :ok | {:error, [String.t()]}
  def validate(kind, value), do: Protocol.validate(kind, value)

  @doc "Validates a protocol value, raising a schema validation exception when it is invalid."
  @spec validate!(kind(), term()) :: :ok
  def validate!(kind, value) do
    case validate(kind, value) do
      :ok -> :ok
      {:error, details} -> raise TamaMCP.Schema.Error, message: Enum.join(details, "; ")
    end
  end

  @doc "Returns the immutable Phase 1 wire fixtures bundled with TamaMCP."
  @spec fixtures() :: [map()]
  def fixtures, do: @fixtures

  @doc "Runs every supplied fixture through an application request callback."
  @spec run((map() -> map()), [map()]) :: :ok | {:error, [String.t()]}
  def run(request, fixtures \\ @fixtures) when is_function(request, 1) and is_list(fixtures) do
    errors =
      Enum.flat_map(fixtures, fn fixture ->
        case verify(fixture, request.(fixture["request"])) do
          :ok -> []
          {:error, details} -> Enum.map(details, &"#{fixture["name"]}: #{&1}")
        end
      end)

    if errors == [], do: :ok, else: {:error, errors}
  end

  @doc "Verifies one normalized response and both protocol schema expectations."
  @spec verify(map(), map()) :: :ok | {:error, [String.t()]}
  def verify(fixture, response) when is_map(fixture) and is_map(response) do
    expected = fixture["expected"]

    []
    |> compare("status", expected["status"], response[:status])
    |> compare("body", expected["body"], response[:body])
    |> compare_headers(expected["headers"], response[:headers])
    |> verify_schema(
      fixture["requestSchema"],
      fixture["requestValid"],
      fixture["request"]["body"]
    )
    |> verify_schema(fixture["responseSchema"], true, response[:body])
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

  defp verify_schema(errors, name, valid?, value) do
    result = validate(Map.fetch!(@kinds, name), value)

    case {valid?, result} do
      {true, :ok} -> errors
      {false, {:error, _details}} -> errors
      {true, {:error, _details}} -> ["#{name} does not match the pinned schema" | errors]
      {false, :ok} -> ["#{name} unexpectedly matches the pinned schema" | errors]
    end
  end
end
