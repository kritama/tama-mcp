defmodule TamaMCP.Task.Validation do
  @moduledoc false

  alias TamaMCP.{Error, JSON, Schema}

  @enforce_keys [:task]
  defstruct [:task, :cache, :tool, options: [], cache_options: [], max_error_data_bytes: 8_192]

  @type source :: atom() | {:encoded_error, atom()} | {:option, atom(), term()}
  @type operator ::
          {:absent, atom()}
          | {:binary_or_integer, atom()}
          | {:boolean, atom()}
          | {:bounded_positive_integer, atom(), source(), pos_integer()}
          | {:json_object, atom()}
          | {:non_empty_binary, atom()}
          | {:non_negative_integer, atom()}
          | {:not_before, atom(), atom()}
          | {:one_of, atom(), [term()]}
          | {:optional_bounded_positive_integer, atom(), pos_integer()}
          | {:optional_json_object, atom()}
          | {:optional_utf8_bytes, atom(), source()}
          | {:present, atom()}
          | {:unique_binary_list, atom()}
          | {:utc_datetime, atom()}
          | {:struct, atom(), module()}
          | {:schema, source(), module(), atom()}
          | {:recorded_keys, atom(), atom()}
          | {:tool_output, atom()}

  @type t :: %__MODULE__{
          task: TamaMCP.Task.t(),
          cache: module() | nil,
          options: keyword(),
          cache_options: keyword(),
          tool: module() | nil,
          max_error_data_bytes: term()
        }

  @spec new(TamaMCP.Task.t(), keyword()) :: t()
  def new(task, options) do
    %__MODULE__{
      task: task,
      cache: Keyword.get(options, :cache),
      options: options,
      cache_options: Keyword.get(options, :cache_options, []),
      tool: Keyword.get(options, :tool),
      max_error_data_bytes: Keyword.get(options, :max_error_data_bytes, 8_192)
    }
  end

  @spec valid?(t(), [operator()]) :: boolean()
  def valid?(%__MODULE__{} = validation, operators) when is_list(operators) do
    Enum.all?(operators, &check(validation, &1))
  rescue
    _exception -> false
  catch
    _kind, _reason -> false
  end

  @spec matches?(map(), map()) :: boolean()
  def matches?(candidate, expected) when is_map(candidate) and is_map(expected) do
    Enum.all?(expected, fn {field, expected_value} ->
      Map.fetch(candidate, field) == {:ok, expected_value}
    end)
  end

  def matches?(_candidate, _expected), do: false

  @spec same_fields?(map(), map(), [atom()]) :: boolean()
  def same_fields?(left, right, fields)
      when is_map(left) and is_map(right) and is_list(fields) do
    Enum.all?(fields, fn field ->
      with {:ok, left_value} <- Map.fetch(left, field),
           {:ok, right_value} <- Map.fetch(right, field) do
        left_value == right_value
      else
        _missing -> false
      end
    end)
  end

  def same_fields?(_left, _right, _fields), do: false

  defp check(validation, {:absent, field}),
    do: is_nil(value(validation, field))

  defp check(validation, {:binary_or_integer, field}) do
    candidate = value(validation, field)
    is_binary(candidate) or is_integer(candidate)
  end

  defp check(validation, {:boolean, field}),
    do: is_boolean(value(validation, field))

  defp check(validation, {:bounded_positive_integer, field, maximum_source, hard_maximum}) do
    bounded_positive_integer?(
      value(validation, field),
      value(validation, maximum_source),
      hard_maximum
    )
  end

  defp check(validation, {:json_object, field}) do
    candidate = value(validation, field)
    is_map(candidate) and JSON.value?(candidate)
  end

  defp check(validation, {:non_empty_binary, field}) do
    candidate = value(validation, field)
    is_binary(candidate) and candidate != ""
  end

  defp check(validation, {:non_negative_integer, field}) do
    candidate = value(validation, field)
    is_integer(candidate) and candidate >= 0
  end

  defp check(validation, {:not_before, later_field, earlier_field}) do
    DateTime.compare(value(validation, later_field), value(validation, earlier_field)) != :lt
  end

  defp check(validation, {:one_of, field, allowed}),
    do: value(validation, field) in allowed

  defp check(validation, {:optional_bounded_positive_integer, field, hard_maximum}) do
    case value(validation, field) do
      nil -> true
      candidate -> bounded_positive_integer?(candidate, hard_maximum, hard_maximum)
    end
  end

  defp check(validation, {:optional_json_object, field}) do
    case value(validation, field) do
      nil -> true
      candidate -> is_map(candidate) and JSON.value?(candidate)
    end
  end

  defp check(validation, {:optional_utf8_bytes, field, maximum_source}) do
    case value(validation, field) do
      nil -> true
      candidate -> valid_utf8_bytes?(candidate, value(validation, maximum_source))
    end
  end

  defp check(validation, {:present, field}),
    do: not is_nil(value(validation, field))

  defp check(validation, {:unique_binary_list, field}) do
    case value(validation, field) do
      values when is_list(values) ->
        Enum.all?(values, &is_binary/1) and length(values) == length(Enum.uniq(values))

      _invalid ->
        false
    end
  end

  defp check(validation, {:utc_datetime, field}) do
    case value(validation, field) do
      %DateTime{utc_offset: 0, std_offset: 0} -> true
      _invalid -> false
    end
  end

  defp check(validation, {:struct, field, module}),
    do: is_struct(value(validation, field), module)

  defp check(validation, {:schema, source, schema, kind}) do
    valid_cache?(validation) and
      schema.validate(
        kind,
        value(validation, source),
        validation.cache,
        validation.cache_options
      ) == :ok
  end

  defp check(validation, {:recorded_keys, requests_field, keys_field}) do
    requests = value(validation, requests_field)
    keys = value(validation, keys_field)

    is_map(requests) and is_list(keys) and
      MapSet.subset?(MapSet.new(Map.keys(requests)), MapSet.new(keys))
  end

  defp check(%__MODULE__{tool: nil}, {:tool_output, _field}), do: true

  defp check(%__MODULE__{tool: tool} = validation, {:tool_output, field})
       when is_atom(tool) do
    case tool.output_validator(validation.cache, validation.cache_options) do
      nil ->
        true

      compiled ->
        case Map.fetch(value(validation, field), "structuredContent") do
          {:ok, structured} -> Schema.validate(compiled, structured) == :ok
          :error -> false
        end
    end
  end

  defp check(_validation, {:tool_output, _field}), do: false

  defp value(%__MODULE__{} = validation, {:encoded_error, field}) do
    validation.task
    |> Map.fetch!(field)
    |> Error.encode(validation.max_error_data_bytes)
  end

  defp value(%__MODULE__{} = validation, {:option, name, default}) do
    Keyword.get(validation.options, name, default)
  end

  defp value(%__MODULE__{} = validation, field), do: Map.fetch!(validation.task, field)

  defp bounded_positive_integer?(candidate, maximum, hard_maximum) do
    positive_integer?(candidate) and positive_integer?(maximum) and
      candidate <= min(maximum, hard_maximum)
  end

  defp positive_integer?(value), do: is_integer(value) and value > 0

  defp valid_utf8_bytes?(candidate, maximum) do
    is_binary(candidate) and String.valid?(candidate) and positive_integer?(maximum) and
      byte_size(candidate) <= maximum
  end

  defp valid_cache?(validation) do
    is_atom(validation.cache) and not is_nil(validation.cache) and
      Keyword.keyword?(validation.cache_options)
  end
end
