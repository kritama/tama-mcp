defmodule TamaMCP.AuthorizationTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias TamaMCP.Authorization.{Challenge, Decision}

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
    refute Decision.valid?(%Decision{principal: "p", scopes: ["bad scope"]})
    refute Decision.valid?(%Decision{principal: "p", scopes: ["bad\"scope"]})
    refute Decision.valid?(%Decision{principal: "p", scopes: ["read", "read"]})
    refute Decision.valid?(%Decision{principal: "p", expires_at: :never})
    refute Decision.valid?(%Decision{principal: "p", assigns: nil})
  end

  test "builds a complete bounded insufficient-scope challenge" do
    assert Challenge.scope?("files:read")
    refute Challenge.scope?("bad scope")
    refute Challenge.scope?("bad\\scope")
    refute Challenge.scope?("método")

    assert {:ok, challenge} = Challenge.insufficient_scope(["files:read"], 1_024)
    assert challenge == ~s(Bearer error="insufficient_scope", scope="files:read")

    assert {:error, :too_large} =
             Challenge.insufficient_scope(["files:read"], byte_size(challenge) - 1)
  end
end
