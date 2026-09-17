defmodule TamaMCP.Authorization do
  @moduledoc """
  The authorization boundary for every HTTP request.

  TamaMCP composes an authorization adapter (typically built on `tama_oauth`)
  rather than reimplementing OAuth. The adapter is invoked for every request
  before transport validation and dispatch. It returns a normalized
  decision or a bounded authorization error. TamaMCP derives identity only from
  the adapter result; it never accepts identity from an unvalidated request
  field.

  Adapters that return `{:error, error}` cause the transport to answer with
  HTTP `401 Unauthorized` and the adapter's error. Scope enforcement happens
  after the decision, per tool, and fails with HTTP `403 Forbidden`.

  A long-lived subscription calls `reauthorize/3` before each task delivery and
  at the configured idle interval. The default implementation authenticates
  the retained request again. `register_invalidation/3` may additionally
  register the stream process for immediate policy or credential invalidation;
  the adapter sends `invalidation/1` using its returned reference. The default
  reports that immediate invalidation is unsupported, leaving expiry and
  periodic reauthorization active.
  """

  alias TamaMCP.Authorization.{Challenge, Decision}

  @type decision :: Decision.t()

  @callback authenticate(Plug.Conn.t(), keyword()) ::
              {:ok, decision()} | {:error, TamaMCP.Error.t()}

  @callback reauthorize(Plug.Conn.t(), decision(), keyword()) ::
              {:ok, decision()} | {:error, TamaMCP.Error.t()}

  @callback register_invalidation(decision(), pid(), keyword()) ::
              {:ok, term()} | :unsupported | {:error, TamaMCP.Error.t()}

  @callback unregister_invalidation(term(), keyword()) ::
              :ok | {:error, TamaMCP.Error.t()}

  @optional_callbacks reauthorize: 3, register_invalidation: 3, unregister_invalidation: 2

  @doc "Builds the standard message an adapter sends when stream policy may have changed."
  @spec invalidation(term()) :: {module(), term(), :invalidated}
  def invalidation(reference), do: {__MODULE__, reference, :invalidated}

  @doc false
  defmacro __using__(_opts) do
    quote do
      @behaviour TamaMCP.Authorization

      @impl true
      def reauthorize(conn, _decision, options), do: authenticate(conn, options)

      @impl true
      def register_invalidation(_decision, _subscriber, _options), do: :unsupported

      @impl true
      def unregister_invalidation(_reference, _options), do: :ok

      defoverridable reauthorize: 3, register_invalidation: 3, unregister_invalidation: 2
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
