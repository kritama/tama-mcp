defmodule TamaMCP.TestSupport.Authorization do
  @moduledoc false

  use TamaMCP.Authorization

  @impl true
  def authenticate(conn, _opts) do
    token = List.last(Plug.Conn.get_req_header(conn, "x-test-token"), nil)

    case token do
      "ok" ->
        {:ok,
         %TamaMCP.Authorization.Decision{
           principal: "test-principal",
           claims: %{"sub" => "test-principal"},
           scopes: [
             "test.context",
             "test.echo",
             "test.failing",
             "test.invalid",
             "test.protocol_failing",
             "test.slow"
           ],
           owner_key: "test-owner",
           expires_at: nil
         }}

      "no-scope" ->
        {:ok,
         %TamaMCP.Authorization.Decision{
           principal: "test-principal",
           claims: %{},
           scopes: [],
           owner_key: "test-owner",
           expires_at: nil
         }}

      _ ->
        {:error, TamaMCP.Error.invalid_request("invalid or missing credential")}
    end
  end
end
