defmodule TamaMCP.Transport.StreamableHTTP.Runtime do
  @moduledoc """
  Validated immutable configuration for the Streamable HTTP transport.

  Build it through `build/1`. Unknown, duplicate, future-phase, unbounded, and
  malformed options fail during plug initialization.
  """

  alias __MODULE__.Validation
  alias TamaMCP.Transport.StreamableHTTP.Result

  @default_limits %{
    max_body_bytes: 1_048_576,
    body_read_timeout_ms: 5_000,
    request_timeout_ms: 30_000,
    max_result_bytes: 1_048_576,
    max_schema_bytes: 262_144,
    max_tools_per_server: 256,
    default_task_ttl_ms: 86_400_000,
    max_task_ttl_ms: 604_800_000,
    default_poll_interval_ms: 1_000,
    max_status_message_bytes: 2_048,
    max_error_data_bytes: 8_192,
    max_www_authenticate_bytes: 4_096,
    max_safe_metadata_bytes: 16_384
  }

  @options [
    :server,
    :authorization,
    :authorization_options,
    :cache,
    :cache_options,
    :task_store,
    :task_store_options,
    :task_runner,
    :task_runner_options,
    :clock,
    :clock_options,
    :identifier,
    :identifier_options,
    :task_selector,
    :telemetry_prefix,
    :safe_metadata,
    :context_headers,
    :limits
  ]

  defstruct [
    :server,
    :authorization,
    :authorization_options,
    :cache,
    :cache_options,
    :task_store,
    :task_store_options,
    :task_runner,
    :task_runner_options,
    :clock,
    :clock_options,
    :identifier,
    :identifier_options,
    :task_selector,
    :telemetry_prefix,
    :safe_metadata,
    :context_headers,
    :limits
  ]

  @type t :: %__MODULE__{
          server: module(),
          authorization: module(),
          authorization_options: keyword(),
          cache: module(),
          cache_options: keyword(),
          task_store: module() | nil,
          task_store_options: keyword(),
          task_runner: module() | nil,
          task_runner_options: keyword(),
          clock: module(),
          clock_options: keyword(),
          identifier: module(),
          identifier_options: keyword(),
          task_selector: (module(), map(), TamaMCP.Context.t() -> term()),
          telemetry_prefix: [atom()],
          safe_metadata: (term(), term() -> term()) | nil,
          context_headers: [String.t()],
          limits: map()
        }

  @spec build(keyword()) :: t()
  def build(opts) do
    Validation.options!(opts, @options)
    server = Validation.module!(opts, :server)
    authorization = Validation.module!(opts, :authorization)
    Validation.server!(server)
    Validation.authorization!(authorization)
    cache = Validation.module!(opts, :cache)
    Validation.cache!(cache)

    runtime = %__MODULE__{
      server: server,
      authorization: authorization,
      authorization_options:
        Validation.keyword!(
          Keyword.get(opts, :authorization_options, []),
          "authorization_options"
        ),
      cache: cache,
      cache_options: Validation.keyword!(Keyword.get(opts, :cache_options, []), "cache_options"),
      task_store: Validation.optional_module!(opts, :task_store),
      task_store_options:
        Validation.keyword!(Keyword.get(opts, :task_store_options, []), "task_store_options"),
      task_runner: Validation.optional_module!(opts, :task_runner),
      task_runner_options:
        Validation.keyword!(Keyword.get(opts, :task_runner_options, []), "task_runner_options"),
      clock: Validation.optional_module!(opts, :clock, TamaMCP.Clock.System),
      clock_options: Validation.keyword!(Keyword.get(opts, :clock_options, []), "clock_options"),
      identifier: Validation.optional_module!(opts, :identifier, TamaMCP.Identifier.UUID),
      identifier_options:
        Validation.keyword!(Keyword.get(opts, :identifier_options, []), "identifier_options"),
      task_selector: Validation.task_selector!(Keyword.get(opts, :task_selector)),
      telemetry_prefix: Validation.telemetry!(Keyword.get(opts, :telemetry_prefix, [:tama_mcp])),
      safe_metadata: Validation.metadata!(Keyword.get(opts, :safe_metadata)),
      context_headers: Validation.headers!(Keyword.get(opts, :context_headers, [])),
      limits: Validation.limits!(Keyword.get(opts, :limits, %{}), @default_limits)
    }

    Validation.tasks!(runtime, Keyword.has_key?(opts, :task_selector))
    Validation.catalog!(server, runtime)
    runtime
  end

  @doc false
  @spec task_capable?(t()) :: boolean()
  def task_capable?(%__MODULE__{task_store: store, task_runner: runner}),
    do: not is_nil(store) and not is_nil(runner)

  @doc false
  @spec task_validation_options(t()) :: keyword()
  def task_validation_options(%__MODULE__{limits: limits} = runtime) do
    [
      max_status_message_bytes: limits.max_status_message_bytes,
      max_task_ttl_ms: limits.max_task_ttl_ms,
      max_result_bytes: limits.max_result_bytes,
      max_error_data_bytes: limits.max_error_data_bytes,
      result_metadata: Result.metadata(runtime.server),
      cache: runtime.cache,
      cache_options: runtime.cache_options
    ]
  end

  @doc false
  @spec effective_task_store_options(t()) :: keyword()
  def effective_task_store_options(%__MODULE__{} = runtime) do
    namespace = [task_validation_options: task_validation_options(runtime)]
    Keyword.put(runtime.task_store_options, :tama_mcp, namespace)
  end

  @doc false
  def default_limits, do: @default_limits
end
