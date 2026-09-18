defmodule TamaMCP.Conformance.Failure do
  @moduledoc """
  Failure raised by the `TamaMCP.Conformance.Store` and
  `TamaMCP.Conformance.Notification` adapter harnesses.

  `callback` identifies the behaviour callback under test (for example
  `"update/4"`) and `rule` names the violated contract rule. `details` is a
  bounded, adapter-specific description; it must not be used to carry secrets
  or unbounded terms.
  """

  @type t :: %__MODULE__{
          callback: String.t(),
          rule: String.t(),
          details: String.t() | nil
        }

  defexception [:callback, :rule, details: nil]

  @impl true
  def exception(opts) when is_list(opts) do
    {value, opts} = Keyword.pop(opts, :details)
    struct!(__MODULE__, Keyword.put(opts, :details, bounded(value)))
  end

  @impl true
  def message(%__MODULE__{} = failure) do
    "TamaMCP adapter conformance failure: #{failure.callback} violates #{failure.rule}" <>
      detail(failure)
  end

  defp detail(%{details: details}) when is_binary(details) and details != "",
    do: " (#{details})"

  defp detail(_failure), do: ""

  defp bounded(nil), do: nil
  defp bounded(value) when is_binary(value), do: truncate(value)

  defp bounded(value) do
    value |> inspect(limit: 40) |> truncate()
  end

  defp truncate(value) do
    value = String.replace_invalid(value, "")

    if byte_size(value) <= 512 do
      value
    else
      truncate_to_bytes(value, 509) <> "..."
    end
  end

  defp truncate_to_bytes(value, budget) when byte_size(value) <= budget, do: value

  defp truncate_to_bytes(value, budget) do
    value
    |> String.codepoints()
    |> Enum.reduce_while("", fn codepoint, kept ->
      if byte_size(kept) + byte_size(codepoint) <= budget,
        do: {:cont, kept <> codepoint},
        else: {:halt, kept}
    end)
  end
end
