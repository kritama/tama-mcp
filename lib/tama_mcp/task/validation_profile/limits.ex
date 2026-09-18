defmodule TamaMCP.Task.ValidationProfile.Limits do
  @moduledoc false

  # Internal validators for validation-profile limits and host resolutions.

  alias TamaMCP.JSON

  @doc "Validates a single positive-integer limit."
  @spec bound(term()) :: {:ok, pos_integer()} | {:error, :invalid_bound}
  def bound(value) when is_integer(value) and value > 0, do: {:ok, value}
  def bound(_value), do: {:error, :invalid_bound}

  @doc "Validates the JSON-safe result metadata, defaulting absence to an empty map."
  @spec metadata(term()) :: {:ok, map()} | {:error, :invalid_metadata}
  def metadata(nil), do: {:ok, %{}}

  def metadata(value) when is_map(value) do
    if JSON.value?(value), do: {:ok, value}, else: {:error, :invalid_metadata}
  end

  def metadata(_value), do: {:error, :invalid_metadata}

  @doc "Validates a required host-owned module reference."
  @spec module(term()) :: {:ok, atom()} | {:error, :invalid_module}
  def module(value) when is_atom(value) and not is_nil(value), do: {:ok, value}
  def module(_value), do: {:error, :invalid_module}

  @doc "Validates the optional host-owned originating tool reference."
  @spec optional_module(term()) :: {:ok, atom() | nil} | {:error, :invalid_module}
  def optional_module(nil), do: {:ok, nil}
  def optional_module(value) when is_atom(value), do: {:ok, value}
  def optional_module(_value), do: {:error, :invalid_module}

  @doc "Validates the host-owned cache options keyword."
  @spec keyword(term()) :: {:ok, keyword()} | {:error, :invalid_keyword}
  def keyword(value) when is_list(value) do
    if Keyword.keyword?(value), do: {:ok, value}, else: {:error, :invalid_keyword}
  end

  def keyword(_value), do: {:error, :invalid_keyword}
end
