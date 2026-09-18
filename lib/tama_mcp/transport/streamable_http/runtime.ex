defmodule TamaMCP.Transport.StreamableHTTP.Runtime do
  @moduledoc """
  Validated immutable configuration for the Streamable HTTP transport.

  Build it through `build/1`. Unknown, duplicate, unbounded, and
  malformed options fail during plug initialization.
  """

  alias __MODULE__.Validation
  alias TamaMCP.Transport.StreamableHTTP.Result

  @profile_defaults TamaMCP.Task.Validation.Profile.defaults()

  @default_limits %{
    max_body_bytes: 1_048_576,
    body_read_timeout_ms: 5_000,
    request_timeout_ms: 30_000,
    max_result_bytes: @profile_defaults.max_result_bytes,
    max_schema_bytes: 262_144,
    max_tools_per_server: 256,
    default_task_ttl_ms: 86_400_000,
    max_task_ttl_ms: @profile_defaults.max_task_ttl_ms,
    default_poll_interval_ms: 1_000,
    max_input_request_keys_per_task: @profile_defaults.max_input_request_keys_per_task,
    max_task_ids_per_subscription: 100,
    notification_buffer_capacity: 100,
    stream_keepalive_interval_ms: 15_000,
    stream_authorization_recheck_ms: 60_000,
    stream_max_lifetime_ms: 3_600_000,
    max_status_message_bytes: @profile_defaults.max_status_message_bytes,
    max_error_data_bytes: @profile_defaults.max_error_data_bytes,
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
    :notification,
    :notification_options,
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
    :notification,
    :notification_options,
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
          notification: module() | nil,
          notification_options: keyword(),
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
      notification: Validation.optional_module!(opts, :notification),
      notification_options:
        Validation.keyword!(
          Keyword.get(opts, :notification_options, []),
          "notification_options"
        ),
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
    Validation.notifications!(runtime)
    Validation.catalog!(server, runtime)
    runtime
  end

  @doc false
  @spec task_capable?(t()) :: boolean()
  def task_capable?(%__MODULE__{task_store: store, task_runner: runner}),
    do: not is_nil(store) and not is_nil(runner)

  @doc false
  @spec notification_capable?(t()) :: boolean()
  def notification_capable?(%__MODULE__{notification: notification}),
    do: not is_nil(notification)

  @doc false
  @spec task_validation_options(t(), module() | nil) :: keyword()
  def task_validation_options(%__MODULE__{limits: limits} = runtime, tool \\ nil) do
    options = [
      max_status_message_bytes: limits.max_status_message_bytes,
      max_task_ttl_ms: limits.max_task_ttl_ms,
      max_input_request_keys_per_task: limits.max_input_request_keys_per_task,
      max_result_bytes: limits.max_result_bytes,
      max_error_data_bytes: limits.max_error_data_bytes,
      result_metadata: Result.metadata(runtime.server),
      cache: runtime.cache,
      cache_options: runtime.cache_options
    ]

    if is_nil(tool), do: options, else: Keyword.put(options, :tool, tool)
  end

  @doc false
  @spec effective_task_store_options(t()) :: keyword()
  def effective_task_store_options(%__MODULE__{} = runtime) do
    effective_task_store_options(runtime, task_validation_options(runtime))
  end

  @doc false
  @spec effective_task_store_options(t(), keyword()) :: keyword()
  def effective_task_store_options(%__MODULE__{} = runtime, validation_options) do
    namespace = [
      task_validation_options: validation_options,
      notification: runtime.notification,
      notification_options: runtime.notification_options,
      telemetry_prefix: runtime.telemetry_prefix,
      server: runtime.server.name()
    ]

    Keyword.put(runtime.task_store_options, :tama_mcp, namespace)
  end

  @doc false
  def default_limits, do: @default_limits
end
