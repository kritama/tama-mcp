defmodule TamaMCP.Task.ValidationProfile do
  @moduledoc """
  Versioned, persistable snapshot of the package-owned task-validation limits.

  Durable task adapters must apply the same effective limits when a task
  transitions later or on another node. A profile captures the package-owned
  portion of the effective task-validation options — the status-message,
  lifetime, input-request-key, result, and error-data bounds plus the result
  metadata — in a versioned, JSON-safe form that hosts can persist next to
  the task:

      case TamaMCP.Task.ValidationProfile.from_options(validation_options) do
        {:ok, profile} ->
          # Persist TamaMCP.Task.ValidationProfile.encode(profile) with the
          # task.

        {:error, :invalid_profile} ->
          # The runtime options were malformed; fail the request.
      end

  On another node the host resolves its own cache and tool, then
  reconstructs the package validation options:

      {:ok, options} =
        TamaMCP.Task.ValidationProfile.options(profile,
          cache: MyCache,
          cache_options: my_cache_options,
          tool: MyTool
        )

  Module identities, cache processes, functions, and arbitrary terms are
  never serialized. Tool and cache resolution remain explicit host decisions;
  this module only carries the package-owned numeric limits and JSON-safe
  result metadata. `defaults/0` is the single source of the package default
  limits, and the Streamable HTTP transport derives its task-validation
  defaults from it.
  """

  alias TamaMCP.Task.ValidationProfile.Limits

  @version 1

  @defaults %{
    max_status_message_bytes: 2_048,
    max_task_ttl_ms: 604_800_000,
    max_input_request_keys_per_task: 256,
    max_result_bytes: 1_048_576,
    max_error_data_bytes: 8_192,
    result_metadata: %{}
  }

  @enforce_keys [
    :version,
    :max_status_message_bytes,
    :max_task_ttl_ms,
    :max_input_request_keys_per_task,
    :max_result_bytes,
    :max_error_data_bytes,
    :result_metadata
  ]
  defstruct [
    :version,
    :max_status_message_bytes,
    :max_task_ttl_ms,
    :max_input_request_keys_per_task,
    :max_result_bytes,
    :max_error_data_bytes,
    :result_metadata
  ]

  @type t :: %__MODULE__{}

  @doc "Returns the package default task-validation limits."
  @spec defaults() :: map()
  def defaults, do: @defaults

  @doc """
  Builds a profile from effective runtime task-validation options.

  The options are the `:task_validation_options` keyword the transport adds
  to store options. Only the package-owned limits are captured; host-owned
  entries such as `:cache`, `:cache_options`, and `:tool` are ignored.
  Missing or invalid limits fail closed with `:invalid_profile`.
  """
  @spec from_options(keyword()) :: {:ok, t()} | {:error, :invalid_profile}
  def from_options(options) when is_list(options) do
    with {:ok, max_status_message_bytes} <- Limits.bound(options[:max_status_message_bytes]),
         {:ok, max_task_ttl_ms} <- Limits.bound(options[:max_task_ttl_ms]),
         {:ok, max_input_request_keys_per_task} <-
           Limits.bound(options[:max_input_request_keys_per_task]),
         {:ok, max_result_bytes} <- Limits.bound(options[:max_result_bytes]),
         {:ok, max_error_data_bytes} <- Limits.bound(options[:max_error_data_bytes]),
         {:ok, result_metadata} <- Limits.metadata(options[:result_metadata]) do
      {
        :ok,
        %__MODULE__{
          version: @version,
          max_status_message_bytes: max_status_message_bytes,
          max_task_ttl_ms: max_task_ttl_ms,
          max_input_request_keys_per_task: max_input_request_keys_per_task,
          max_result_bytes: max_result_bytes,
          max_error_data_bytes: max_error_data_bytes,
          result_metadata: result_metadata
        }
      }
    else
      {:error, _invalid} -> {:error, :invalid_profile}
    end
  end

  def from_options(_options), do: {:error, :invalid_profile}

  @doc "Encodes the profile as a versioned, JSON-safe map."
  @spec encode(t()) :: map()
  def encode(%__MODULE__{} = profile) do
    %{
      "version" => profile.version,
      "maxStatusMessageBytes" => profile.max_status_message_bytes,
      "maxTaskTtlMs" => profile.max_task_ttl_ms,
      "maxInputRequestKeysPerTask" => profile.max_input_request_keys_per_task,
      "maxResultBytes" => profile.max_result_bytes,
      "maxErrorDataBytes" => profile.max_error_data_bytes,
      "resultMetadata" => profile.result_metadata
    }
  end

  @doc """
  Decodes and strictly validates a persisted profile map.

  Only the exact versioned field set produced by `encode/1` is accepted.
  Unknown versions, missing or extra fields, non-positive bounds, unsafe
  result metadata, and atom keys fail closed with `:invalid_profile` without
  creating atoms from persisted input.
  """
  @spec decode(map() | nil) :: {:ok, t()} | {:error, :invalid_profile}
  def decode(nil), do: {:error, :invalid_profile}

  def decode(
        %{
          "version" => version,
          "maxStatusMessageBytes" => max_status_message_bytes,
          "maxTaskTtlMs" => max_task_ttl_ms,
          "maxInputRequestKeysPerTask" => max_input_request_keys_per_task,
          "maxResultBytes" => max_result_bytes,
          "maxErrorDataBytes" => max_error_data_bytes,
          "resultMetadata" => result_metadata
        } = map
      )
      when map_size(map) == 7 do
    with true <- version == @version,
         {:ok, max_status_message_bytes} <- Limits.bound(max_status_message_bytes),
         {:ok, max_task_ttl_ms} <- Limits.bound(max_task_ttl_ms),
         {:ok, max_input_request_keys_per_task} <- Limits.bound(max_input_request_keys_per_task),
         {:ok, max_result_bytes} <- Limits.bound(max_result_bytes),
         {:ok, max_error_data_bytes} <- Limits.bound(max_error_data_bytes),
         {:ok, result_metadata} <- Limits.metadata(result_metadata) do
      {
        :ok,
        %__MODULE__{
          version: version,
          max_status_message_bytes: max_status_message_bytes,
          max_task_ttl_ms: max_task_ttl_ms,
          max_input_request_keys_per_task: max_input_request_keys_per_task,
          max_result_bytes: max_result_bytes,
          max_error_data_bytes: max_error_data_bytes,
          result_metadata: result_metadata
        }
      }
    else
      _invalid -> {:error, :invalid_profile}
    end
  end

  def decode(_value), do: {:error, :invalid_profile}

  @doc """
  Reconstructs the package task-validation options from the profile.

  The host supplies the current cache module and, when the originating task
  has a tool, the allowlisted tool module:

      [cache: MyCache, cache_options: [...], tool: MyTool | nil]

  `cache` is required. Invalid host resolutions fail closed with
  `:invalid_resolution` rather than raising.
  """
  @spec options(t(), keyword()) ::
          {:ok, keyword()} | {:error, :invalid_resolution}
  def options(%__MODULE__{} = profile, resolution) when is_list(resolution) do
    base = [
      max_status_message_bytes: profile.max_status_message_bytes,
      max_task_ttl_ms: profile.max_task_ttl_ms,
      max_input_request_keys_per_task: profile.max_input_request_keys_per_task,
      max_result_bytes: profile.max_result_bytes,
      max_error_data_bytes: profile.max_error_data_bytes,
      result_metadata: profile.result_metadata
    ]

    with true <- Keyword.has_key?(resolution, :cache),
         {:ok, cache} <- Limits.module(resolution[:cache]),
         {:ok, cache_options} <- Limits.keyword(Keyword.get(resolution, :cache_options, [])),
         {:ok, tool} <- Limits.optional_module(Keyword.get(resolution, :tool)) do
      options =
        base
        |> Keyword.put(:cache, cache)
        |> Keyword.put(:cache_options, cache_options)

      {:ok, if(is_nil(tool), do: options, else: Keyword.put(options, :tool, tool))}
    else
      _invalid -> {:error, :invalid_resolution}
    end
  end

  def options(_profile, _resolution), do: {:error, :invalid_resolution}
end
