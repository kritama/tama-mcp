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
             "test.headers",
             "test.invalid",
             "test.invalid_output",
             "test.null",
             "test.protocol_failing",
             "test.result",
             "test.slow",
             "test.task_required"
           ],
           owner_key: "test-owner",
           expires_at: nil,
           assigns: %{workspace: "test-workspace"}
         }}

      "echo-only" ->
        {:ok,
         %TamaMCP.Authorization.Decision{
           principal: "test-principal",
           claims: %{},
           scopes: ["test.echo"],
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

      "other" ->
        {:ok,
         %TamaMCP.Authorization.Decision{
           principal: "other-principal",
           claims: %{"sub" => "other-principal"},
           scopes: ["test.task_required"],
           owner_key: "other-owner",
           expires_at: nil
         }}

      "ownerless" ->
        {:ok,
         %TamaMCP.Authorization.Decision{
           principal: "ownerless-principal",
           claims: %{"sub" => "ownerless-principal"},
           scopes: ["test.task_required"],
           owner_key: nil,
           expires_at: nil
         }}

      _ ->
        {:error, TamaMCP.Error.invalid_request("invalid or missing credential")}
    end
  end
end
