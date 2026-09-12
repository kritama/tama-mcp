defmodule TamaMCP.Response do
  @moduledoc """
  A tool response represented independently of JSON encoding.

  Supports content blocks, structured content, `isError`, and optional
  validated metadata. Use `success/1` for a completed tool result and
  `tool_error/1` for a completed tool call whose `CallToolResult.isError` is
  `true`. A tool error is still a successful JSON-RPC response; it is not a
  `TamaMCP.Error`.
  """

  alias TamaMCP.JSON

  defstruct content: [],
            structured_content: nil,
            structured_content?: false,
            is_error: false,
            meta: nil

  @type t :: %__MODULE__{
          content: [map()],
          structured_content: term(),
          structured_content?: boolean(),
          is_error: boolean(),
          meta: map() | nil
        }

  @doc """
  Builds a successful tool response.

  Options:

    * `:content` - list of content block maps (default `[]`).
    * `:structured_content` - JSON-safe structured result. When explicitly set
      to `nil`, it is encoded as JSON `null`; when omitted, the field is absent.
    * `:meta` - validated result metadata map (default `nil`).
  """
  @spec success(keyword()) :: t()
  def success(opts \\ []) do
    %__MODULE__{
      content: Keyword.get(opts, :content, []),
      structured_content: Keyword.get(opts, :structured_content),
      structured_content?: Keyword.has_key?(opts, :structured_content),
      is_error: false,
      meta: Keyword.get(opts, :meta)
    }
  end

  @doc """
  Builds a completed tool response with `isError` set to `true`.

  Accepts the same options as `success/1`.
  """
  @spec tool_error(keyword()) :: t()
  def tool_error(opts \\ []) do
    success(opts)
    |> Map.put(:is_error, true)
  end

  @doc "Builds a text content block."
  @spec text(String.t()) :: map()
  def text(body) when is_binary(body) do
    %{"type" => "text", "text" => body}
  end

  @doc """
  Encodes the response as the `result` member of a `tools/call` response.

  The result always carries `resultType: "complete"` and a `content` array, as
  required by the pinned `CallToolResult` schema.
  """
  @spec encode(t()) :: map()
  def encode(%__MODULE__{} = response) do
    result = %{
      "resultType" => TamaMCP.Protocol.result_type(:complete),
      "content" => response.content,
      "isError" => response.is_error
    }

    result =
      if structured_content?(response) do
        Map.put(result, "structuredContent", response.structured_content)
      else
        result
      end

    if response.meta != nil do
      Map.put(result, "_meta", response.meta)
    else
      result
    end
  end

  @doc """
  Validates that the response is encodable: content blocks are JSON-safe maps
  with a `type` string, and structured content and metadata are JSON-safe.

  Returns `:ok` or `{:error, reason}` with a classified reason.
  """
  @spec validate(t()) :: :ok | {:error, atom()}
  def validate(%__MODULE__{} = response) do
    with :ok <- validate_presence(response.structured_content?),
         :ok <- validate_content(response.content),
         :ok <- validate_json_safe(:structured_content, response.structured_content) do
      validate_json_safe(:meta, response.meta)
    end
  end

  @doc false
  @spec structured_content?(t()) :: boolean()
  def structured_content?(%__MODULE__{} = response) do
    response.structured_content? == true or not is_nil(response.structured_content)
  end

  defp validate_presence(value) when is_boolean(value), do: :ok
  defp validate_presence(_value), do: {:error, :invalid_structured_content_presence}

  defp validate_content(content) when is_list(content) do
    Enum.reduce_while(content, :ok, fn block, _acc ->
      if valid_block?(block) do
        {:cont, :ok}
      else
        {:halt, {:error, :invalid_content_block}}
      end
    end)
  end

  defp validate_content(_), do: {:error, :invalid_content_block}

  defp valid_block?(%{"type" => type} = block) when is_binary(type) do
    case type do
      "text" ->
        Map.has_key?(block, "text") and is_binary(Map.fetch!(block, "text")) and
          JSON.value?(block)

      _other ->
        JSON.value?(block)
    end
  end

  defp valid_block?(_), do: false

  defp validate_json_safe(_name, nil), do: :ok

  defp validate_json_safe(:meta, value) do
    cond do
      not JSON.value?(value) -> {:error, :non_json_safe}
      JSON.meta_object?(value) -> :ok
      true -> {:error, :invalid_metadata}
    end
  end

  defp validate_json_safe(_name, value),
    do: if(JSON.value?(value), do: :ok, else: {:error, :non_json_safe})
end
