defmodule TamaMCP.Authorization do
  @moduledoc """
  The authorization boundary for every HTTP request.

  TamaMCP composes an authorization adapter (typically built on `tama_oauth`)
  rather than reimplementing OAuth. The adapter is invoked exactly once per
  request, before transport validation and dispatch. It returns a normalized
  decision or a bounded authorization error. TamaMCP derives identity only from
  the adapter result; it never accepts identity from an unvalidated request
  field.

  Adapters that return `{:error, error}` cause the transport to answer with
  HTTP `401 Unauthorized` and the adapter's error. Scope enforcement happens
  after the decision, per tool, and fails with HTTP `403 Forbidden`.
  """

  alias TamaMCP.Authorization.{Challenge, Decision}

  @type decision :: Decision.t()

  @callback authenticate(Plug.Conn.t(), keyword()) ::
              {:ok, decision()} | {:error, TamaMCP.Error.t()}

  @doc false
  defmacro __using__(_opts) do
    quote do
      @behaviour TamaMCP.Authorization
    end
  end

  defmodule Decision do
    @moduledoc """
    The normalized authorization result for one request.

    `principal` is the authenticated application principal in whatever form the
    host application owns (for example a Tama actor reference). `owner_key` is
    the application-defined key the task store uses to bind task access to the
    validated caller. `expires_at` is the credential expiry deadline, or `nil`
    when the credential has none; long-lived streams must close no later than
    this deadline. `assigns` contains only the application values the adapter
    explicitly chooses to expose to tools; Plug assigns are never copied.
    """

    @enforce_keys [:principal]
    defstruct [:principal, claims: %{}, scopes: [], owner_key: nil, expires_at: nil, assigns: %{}]

    @type t :: %__MODULE__{
            principal: term(),
            claims: map(),
            scopes: [String.t()],
            owner_key: term(),
            expires_at: DateTime.t() | nil,
            assigns: map()
          }

    @doc false
    @spec valid?(t()) :: boolean()
    def valid?(%__MODULE__{} = decision) do
      not is_nil(decision.principal) and is_map(decision.claims) and
        valid_scopes?(decision.scopes) and valid_expiry?(decision.expires_at) and
        is_map(decision.assigns)
    end

    defp valid_scopes?(scopes) do
      is_list(scopes) and Enum.all?(scopes, &Challenge.scope?/1) and
        length(scopes) == length(Enum.uniq(scopes))
    end

    defp valid_expiry?(nil), do: true
    defp valid_expiry?(%DateTime{}), do: true
    defp valid_expiry?(_expiry), do: false
  end
end
