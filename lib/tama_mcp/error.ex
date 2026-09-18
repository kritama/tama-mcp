defmodule TamaMCP.Error do
  @moduledoc """
  JSON-RPC and package errors with a numeric code, a safe message, and JSON-safe
  data.

  Expected client, authorization, task-state, and domain failures are returned
  as values of this struct; they never raise. Every constructor produces data
  that is JSON-safe by construction. Adapters, applications, and transports must
  not attach arbitrary terms (structs, exceptions, PIDs, references) to `data`.
  """

  alias TamaMCP.JSON

  @enforce_keys [:code, :message]
  defstruct [:code, :message, data: nil]

  @reasons %{
    -32_700 => :parse_error,
    -32_600 => :invalid_request,
    -32_601 => :method_not_found,
    -32_602 => :invalid_params,
    -32_603 => :internal_error,
    -32_020 => :header_mismatch,
    -32_021 => :missing_capability,
    -32_022 => :unsupported_protocol_version
  }

  @type t :: %__MODULE__{
          code: integer(),
          message: String.t(),
          data: map() | nil
        }

  @doc "Builds a JSON-RPC parse error (-32700)."
  @spec parse(String.t()) :: t()
  def parse(message \\ "Parse error: Invalid JSON")

  def parse(message) when is_binary(message) and byte_size(message) > 0 do
    %__MODULE__{code: TamaMCP.Protocol.error_code(:parse), message: message}
  end

  @doc "Builds a JSON-RPC invalid request error (-32600)."
  @spec invalid_request(String.t()) :: t()
  def invalid_request(message) when is_binary(message) and byte_size(message) > 0 do
    %__MODULE__{code: TamaMCP.Protocol.error_code(:invalid_request), message: message}
  end

  @doc "Builds a JSON-RPC method not found error (-32601)."
  @spec method_not_found(String.t()) :: t()
  def method_not_found(method) when is_binary(method) do
    %__MODULE__{
      code: TamaMCP.Protocol.error_code(:method_not_found),
      message: "Method not found: #{method}"
    }
  end

  @doc "Builds a JSON-RPC invalid params error (-32602)."
  @spec invalid_params(String.t()) :: t()
  def invalid_params(message) when is_binary(message) and byte_size(message) > 0 do
    %__MODULE__{code: TamaMCP.Protocol.error_code(:invalid_params), message: message}
  end

  @doc "Builds a JSON-RPC internal error (-32603)."
  @spec internal(String.t()) :: t()
  def internal(message \\ "Internal error")

  def internal(message) when is_binary(message) and byte_size(message) > 0 do
    %__MODULE__{code: TamaMCP.Protocol.error_code(:internal), message: message}
  end

  @doc "Builds a header mismatch error (-32020)."
  @spec header_mismatch(String.t()) :: t()
  def header_mismatch(message) when is_binary(message) and byte_size(message) > 0 do
    %__MODULE__{code: TamaMCP.Protocol.error_code(:header_mismatch), message: message}
  end

  @doc """
  Builds a missing required client capability error (-32021).

  `capabilities` is the client capability map the server requires, encoded in
  wire form (for example `%{"extensions" => %{"io.modelcontextprotocol/tasks" => %{}}}`).
  """
  @spec missing_required_client_capability(map(), String.t() | nil) :: t()
  def missing_required_client_capability(capabilities, message \\ nil)
      when is_map(capabilities) and map_size(capabilities) > 0 do
    message =
      message ||
        "Server requires the #{required_capability_names(capabilities)} capability for this request"

    %__MODULE__{
      code: TamaMCP.Protocol.error_code(:missing_required_client_capability),
      message: message,
      data: %{"requiredCapabilities" => capabilities}
    }
  end

  @doc """
  Builds an unsupported protocol version error (-32022).

  The data always lists the requested version and every version this package
  supports.
  """
  @spec unsupported_protocol_version(String.t()) :: t()
  def unsupported_protocol_version(requested) when is_binary(requested) do
    %__MODULE__{
      code: TamaMCP.Protocol.error_code(:unsupported_protocol_version),
      message: "Unsupported protocol version",
      data: %{
        "requested" => requested,
        "supported" => TamaMCP.Protocol.supported_versions()
      }
    }
  end

  @doc """
  Encodes the error as the `error` member of a JSON-RPC error response.

  The result is always JSON-safe. If `data` cannot be encoded (which should be
  impossible for errors built through this module), it is dropped rather than
  leaking adapter-specific terms.
  """
  @spec encode(t()) :: map()
  def encode(%__MODULE__{} = error), do: encode(error, 8_192)

  @spec encode(t(), pos_integer()) :: map()
  def encode(%__MODULE__{code: code, message: message, data: data}, max_data_bytes) do
    base = %{"code" => code, "message" => safe_message(message)}

    case safe_data(data, max_data_bytes) do
      nil -> base
      safe -> Map.put(base, "data", safe)
    end
  end

  @doc """
  Decodes an error map produced by `encode/2` back into an error struct.

  Unlike `encode/2`, which drops unsafe data rather than failing, decoding is
  strict and fails closed with `{:error, :invalid_error}` for maps that are
  not exactly `{code, message}` plus an optional `data` member: missing or
  non-integer codes, missing, empty, invalid UTF-8, or overlong messages
  (over 512 bytes), non-object or unsafe `data` values, atom or non-string
  keys, extra keys, and `data` that exceeds the byte bound.

  `nil` decodes to `{:ok, nil}`: durable task payloads may store an absent
  error as a null column. Decoding never creates atoms from persisted input.
  """
  @spec decode(map() | nil) :: {:ok, t() | nil} | {:error, :invalid_error}
  def decode(value), do: decode(value, 8_192)

  @spec decode(map() | nil, pos_integer()) :: {:ok, t() | nil} | {:error, :invalid_error}
  def decode(nil, _max_data_bytes), do: {:ok, nil}

  def decode(%{"code" => code, "message" => message} = error, max_data_bytes)
      when map_size(error) == 2 do
    decode_fields(code, message, nil, max_data_bytes)
  end

  def decode(%{"code" => code, "message" => message, "data" => data} = error, max_data_bytes)
      when map_size(error) == 3 do
    decode_fields(code, message, data, max_data_bytes)
  end

  def decode(_value, _max_data_bytes), do: {:error, :invalid_error}

  defp decode_fields(code, message, data, max_data_bytes) do
    with true <- is_integer(code),
         true <- valid_message?(message),
         {:ok, data} <- safe_data?(data, max_data_bytes) do
      {:ok, %__MODULE__{code: code, message: message, data: data}}
    else
      _invalid -> {:error, :invalid_error}
    end
  end

  defp valid_message?(message) when is_binary(message) do
    String.valid?(message) and byte_size(message) > 0 and byte_size(message) <= 512
  end

  defp valid_message?(_message), do: false

  defp safe_data?(nil, _max_data_bytes), do: {:ok, nil}

  defp safe_data?(data, max_data_bytes) do
    with true <- is_map(data) and not is_struct(data),
         true <- TamaMCP.JSON.value?(data),
         {:ok, encoded} <- Jason.encode(data),
         true <- byte_size(encoded) <= max_data_bytes do
      {:ok, data}
    else
      _invalid -> {:error, :invalid_error}
    end
  end

  @doc false
  @spec reason(t()) :: atom()
  def reason(%__MODULE__{code: code}), do: Map.get(@reasons, code, :unknown)

  @doc false
  @spec status(t()) :: 400 | 404 | 500
  def status(%__MODULE__{code: code}) do
    case code do
      code when code in [-32_700, -32_600, -32_602, -32_020, -32_021, -32_022] -> 400
      -32_601 -> 404
      _ -> 500
    end
  end

  defp required_capability_names(capabilities) do
    capabilities
    |> Map.keys()
    |> Enum.sort()
    |> Enum.join(", ")
  end

  defp safe_data(nil, _max_data_bytes), do: nil

  defp safe_data(data, max_data_bytes) do
    with true <- is_map(data) and JSON.value?(data),
         {:ok, encoded} <- Jason.encode(data),
         true <- byte_size(encoded) <= max_data_bytes do
      data
    else
      _unsafe_or_too_large -> nil
    end
  end

  defp safe_message(message) when is_binary(message) and byte_size(message) > 0 do
    truncate(message, 512)
  end

  defp safe_message(_message), do: "Internal error"

  defp truncate(value, limit) when byte_size(value) <= limit, do: value

  defp truncate(value, limit) do
    value
    |> String.graphemes()
    |> Enum.reduce_while("", fn grapheme, result ->
      if byte_size(result) + byte_size(grapheme) > limit,
        do: {:halt, result},
        else: {:cont, result <> grapheme}
    end)
  end
end
