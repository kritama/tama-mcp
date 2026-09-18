defmodule TamaMCP.RequestID do
  @moduledoc """
  Persistence codecs for JSON-RPC request IDs.

  A JSON-RPC request ID is either a string or an integer, and the two types
  are not interchangeable: a persisted `42` must come back as the integer `42`
  and a persisted `"42"` must come back as the string `"42"`. `encode/1`
  produces a tagged, JSON-safe map that preserves that identity through
  database drivers, and `decode/1` accepts only well-formed tagged maps.

  The codecs operate only on package values and JSON-safe maps. They do not
  depend on Ecto or prescribe database columns; hosts retain schema design,
  constraints, and row projection.

  String request IDs are bounded by `max_string_bytes/0`. `TamaMCP.Task`
  validation enforces the same bound, so every value the package can create
  is a value `decode/1` can persist and recover.

      iex> TamaMCP.RequestID.encode(42)
      %{"type" => "integer", "value" => 42}
      iex> TamaMCP.RequestID.decode(%{"type" => "integer", "value" => 42})
      {:ok, 42}
      iex> TamaMCP.RequestID.decode(%{"type" => "string", "value" => "42"})
      {:ok, "42"}
      iex> TamaMCP.RequestID.decode(42)
      {:error, :invalid_request_id}
  """

  @type id :: String.t() | integer()

  @max_string_bytes 512

  @doc """
  Encodes a JSON-RPC request ID as a tagged, JSON-safe map.

  The `type` tag preserves the exact protocol type so the decoded value is
  never coerced across string and integer identity.
  """
  @spec encode(id()) :: map()
  def encode(id) when is_binary(id), do: %{"type" => "string", "value" => id}
  def encode(id) when is_integer(id), do: %{"type" => "integer", "value" => id}

  @doc """
  The maximum byte size of a string request ID.

  Task validation, persistence encoding, and `decode/1` all apply this bound
  so values created by the package round-trip through any host schema that
  stores request IDs in a column of this size.
  """
  @spec max_string_bytes() :: pos_integer()
  def max_string_bytes, do: @max_string_bytes

  @doc """
  Decodes a tagged request ID map produced by `encode/1`.

  `nil` is rejected because persisted task payloads always carry a request
  ID. Untagged values, booleans, floats, objects, and arrays fail closed, as
  do tagged maps with an unknown tag, a value whose type does not match the
  tag, an invalid UTF-8 string, atom keys, or extra keys. Decoding never
  creates atoms from persisted input.
  """
  @spec decode(map() | nil) :: {:ok, id()} | {:error, :invalid_request_id}
  def decode(nil), do: {:error, :invalid_request_id}

  def decode(%{"type" => "string", "value" => value} = tagged)
      when is_binary(value) and byte_size(value) <= @max_string_bytes and map_size(tagged) == 2 do
    if String.valid?(value), do: {:ok, value}, else: {:error, :invalid_request_id}
  end

  def decode(%{"type" => "integer", "value" => value} = tagged)
      when is_integer(value) and map_size(tagged) == 2 do
    {:ok, value}
  end

  def decode(_value), do: {:error, :invalid_request_id}
end
