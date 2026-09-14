defmodule TamaMCP.Authorization.Challenge do
  @moduledoc false

  @insufficient_scope ~s(Bearer error="insufficient_scope")
  @scope_prefix @insufficient_scope <> ~s(, scope=")
  @scope_suffix ~s(")

  @spec insufficient_scope([String.t()], pos_integer()) ::
          {:ok, String.t()} | {:error, :too_large}
  def insufficient_scope(scopes, maximum) do
    size =
      byte_size(@scope_prefix) +
        Enum.reduce(scopes, 0, fn scope, total -> total + byte_size(scope) end) +
        max(length(scopes) - 1, 0) + byte_size(@scope_suffix)

    if size <= maximum do
      {:ok, @scope_prefix <> Enum.join(scopes, " ") <> @scope_suffix}
    else
      {:error, :too_large}
    end
  end

  @spec minimum_size() :: pos_integer()
  def minimum_size, do: byte_size(@insufficient_scope)

  @spec insufficient_scope() :: String.t()
  def insufficient_scope, do: @insufficient_scope

  @spec scope?(term()) :: boolean()
  def scope?(scope) when is_binary(scope) and byte_size(scope) > 0 do
    scope
    |> :binary.bin_to_list()
    |> Enum.all?(fn byte -> byte == 0x21 or byte in 0x23..0x5B or byte in 0x5D..0x7E end)
  end

  def scope?(_scope), do: false
end
