defmodule TamaMCP.Transport.StreamableHTTP.Runtime do
  @moduledoc """
  Validated immutable configuration for the Streamable HTTP transport.

  Build it through `build/1`. Unknown, duplicate, future-phase, unbounded, and
  malformed options fail during plug initialization.
  """

  alias __MODULE__.Validation

  @default_limits %{
    max_body_bytes: 1_048_576,
    body_read_timeout_ms: 5_000,
    request_timeout_ms: 30_000,
    max_result_bytes: 1_048_576,
    max_schema_bytes: 262_144,
    max_tools_per_server: 256,
    max_error_data_bytes: 8_192,
    max_safe_metadata_bytes: 16_384
  }

  @options [
    :server,
    :authorization,
    :authorization_options,
    :cache,
    :cache_options,
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
      telemetry_prefix: Validation.telemetry!(Keyword.get(opts, :telemetry_prefix, [:tama_mcp])),
      safe_metadata: Validation.metadata!(Keyword.get(opts, :safe_metadata)),
      context_headers: Validation.headers!(Keyword.get(opts, :context_headers, [])),
      limits: Validation.limits!(Keyword.get(opts, :limits, %{}), @default_limits)
    }

    Validation.catalog!(server, runtime.limits)
    runtime
  end

  @doc false
  def default_limits, do: @default_limits
end
