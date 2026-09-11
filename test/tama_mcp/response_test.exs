defmodule TamaMCP.ResponseTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias TamaMCP.Response

  test "default success and tool-error values encode as complete results" do
    assert Response.success() |> Response.encode() == %{
             "resultType" => "complete",
             "content" => [],
             "isError" => false
           }

    assert Response.tool_error() |> Response.encode() == %{
             "resultType" => "complete",
             "content" => [],
             "isError" => true
           }
  end

  test "encoding includes only supplied structured content and metadata" do
    response =
      Response.success(
        content: [Response.text("done")],
        structured_content: %{"status" => "done"},
        meta: %{"example/key" => true}
      )

    assert Response.validate(response) == :ok

    assert Response.encode(response)["_meta"] == %{"example/key" => true}
    assert Response.encode(response)["structuredContent"] == %{"status" => "done"}
  end

  test "validation rejects malformed and non-JSON-safe values" do
    assert {:error, :invalid_content_block} =
             Response.validate(%Response{content: :not_a_list})

    assert {:error, :invalid_content_block} =
             Response.validate(%Response{content: [%{"type" => "text", "text" => 1}]})

    assert {:error, :invalid_content_block} = Response.validate(%Response{content: [%{}]})

    assert {:error, :non_json_safe} =
             Response.validate(%Response{structured_content: %{pid: self()}})

    assert {:error, :non_json_safe} = Response.validate(%Response{meta: %{pid: self()}})
  end
end
