defmodule TamaMCP.AuthorizationTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias TamaMCP.Authorization.Decision

  test "accepts a fully normalized decision" do
    assert Decision.valid?(%Decision{
             principal: "principal",
             claims: %{"sub" => "principal"},
             scopes: ["read"],
             expires_at: DateTime.utc_now(),
             assigns: %{workspace: "one"}
           })
  end

  test "rejects malformed decision fields" do
    refute Decision.valid?(%Decision{principal: nil})
    refute Decision.valid?(%Decision{principal: "p", claims: nil})
    refute Decision.valid?(%Decision{principal: "p", scopes: nil})
    refute Decision.valid?(%Decision{principal: "p", scopes: [""]})
    refute Decision.valid?(%Decision{principal: "p", scopes: ["read", "read"]})
    refute Decision.valid?(%Decision{principal: "p", expires_at: :never})
    refute Decision.valid?(%Decision{principal: "p", assigns: nil})
  end
end
