defmodule TamaMCP.Task.ValidationProfileTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias TamaMCP.Task.ValidationProfile
  alias TamaMCP.TestSupport
  alias TamaMCP.Transport.StreamableHTTP.Runtime

  @options [
    max_status_message_bytes: 4_096,
    max_task_ttl_ms: 1_209_600_000,
    max_input_request_keys_per_task: 64,
    max_result_bytes: 2_097_152,
    max_error_data_bytes: 16_384,
    result_metadata: %{
      "io.modelcontextprotocol.serverInfo" => %{"name" => "tama", "version" => "1.0.0"}
    },
    cache: TestSupport.Cache,
    cache_options: [],
    tool: TestSupport.Tools.Echo
  ]

  test "defaults are defined in one place and shared with the transport" do
    defaults = ValidationProfile.defaults()

    assert %{
             max_status_message_bytes: 2_048,
             max_task_ttl_ms: 604_800_000,
             max_input_request_keys_per_task: 256,
             max_result_bytes: 1_048_576,
             max_error_data_bytes: 8_192,
             result_metadata: %{}
           } = defaults

    limits = Runtime.default_limits()

    assert limits.max_status_message_bytes == defaults.max_status_message_bytes
    assert limits.max_task_ttl_ms == defaults.max_task_ttl_ms
    assert limits.max_input_request_keys_per_task == defaults.max_input_request_keys_per_task
    assert limits.max_result_bytes == defaults.max_result_bytes
    assert limits.max_error_data_bytes == defaults.max_error_data_bytes
  end

  describe "from_options/1" do
    test "captures the package-owned limits and ignores host-owned entries" do
      assert {:ok, profile} = ValidationProfile.from_options(@options)

      assert %ValidationProfile{
               version: 1,
               max_status_message_bytes: 4_096,
               max_task_ttl_ms: 1_209_600_000,
               max_input_request_keys_per_task: 64,
               max_result_bytes: 2_097_152,
               max_error_data_bytes: 16_384,
               result_metadata: %{
                 "io.modelcontextprotocol.serverInfo" => %{"name" => "tama", "version" => "1.0.0"}
               }
             } = profile

      refute Map.has_key?(profile, :cache)
      refute Map.has_key?(profile, :tool)
    end

    test "defaults result metadata when it is absent" do
      assert {:ok, profile} =
               ValidationProfile.from_options(Keyword.delete(@options, :result_metadata))

      assert profile.result_metadata == %{}
    end

    test "fails closed on malformed package-owned limits" do
      for key <- [
            :max_status_message_bytes,
            :max_task_ttl_ms,
            :max_input_request_keys_per_task,
            :max_result_bytes,
            :max_error_data_bytes
          ] do
        assert {:error, :invalid_profile} =
                 ValidationProfile.from_options(Keyword.delete(@options, key))

        for invalid <- [0, -1, 1.5, "1", nil, :atom] do
          assert {:error, :invalid_profile} =
                   ValidationProfile.from_options(Keyword.put(@options, key, invalid))
        end
      end

      for unsafe_metadata <- [
            %{server: "tama"},
            %{"nested" => [self()]},
            %TamaMCP.TestSupport.Encodable{secret: "no"},
            "a string"
          ] do
        assert {:error, :invalid_profile} =
                 ValidationProfile.from_options(
                   Keyword.put(@options, :result_metadata, unsafe_metadata)
                 )
      end

      assert {:error, :invalid_profile} = ValidationProfile.from_options(:not_a_keyword)
    end
  end

  describe "encode/1 and decode/1" do
    test "round-trips the profile losslessly through a JSON-safe map" do
      assert {:ok, profile} = ValidationProfile.from_options(@options)
      encoded = ValidationProfile.encode(profile)

      assert %{
               "version" => 1,
               "maxStatusMessageBytes" => 4_096,
               "maxTaskTtlMs" => 1_209_600_000,
               "maxInputRequestKeysPerTask" => 64,
               "maxResultBytes" => 2_097_152,
               "maxErrorDataBytes" => 16_384,
               "resultMetadata" => %{
                 "io.modelcontextprotocol.serverInfo" => %{"name" => "tama", "version" => "1.0.0"}
               }
             } = encoded

      assert {:ok, json} = Jason.encode(encoded)
      assert {:ok, ^encoded} = Jason.decode(json)
      assert {:ok, ^profile} = ValidationProfile.decode(encoded)
    end

    test "round-trips default-valued profiles" do
      defaults = ValidationProfile.defaults()

      assert {:ok, profile} =
               ValidationProfile.from_options(
                 max_status_message_bytes: defaults.max_status_message_bytes,
                 max_task_ttl_ms: defaults.max_task_ttl_ms,
                 max_input_request_keys_per_task: defaults.max_input_request_keys_per_task,
                 max_result_bytes: defaults.max_result_bytes,
                 max_error_data_bytes: defaults.max_error_data_bytes,
                 result_metadata: defaults.result_metadata
               )

      assert {:ok, ^profile} = ValidationProfile.decode(ValidationProfile.encode(profile))
    end

    test "rejects unknown versions" do
      assert {:ok, profile} = ValidationProfile.from_options(@options)
      encoded = ValidationProfile.encode(profile)

      assert {:error, :invalid_profile} =
               ValidationProfile.decode(Map.put(encoded, "version", 2))

      assert {:error, :invalid_profile} =
               ValidationProfile.decode(Map.put(encoded, "version", "1"))
    end

    test "rejects missing, extra, and malformed fields" do
      assert {:ok, profile} = ValidationProfile.from_options(@options)
      encoded = ValidationProfile.encode(profile)

      for key <- map_keys(encoded) do
        assert {:error, :invalid_profile} =
                 ValidationProfile.decode(Map.delete(encoded, key))
      end

      for extra <- [
            "tool",
            "cache",
            "unknown",
            "maxTaskTtlMsLegacy"
          ] do
        assert {:error, :invalid_profile} =
                 ValidationProfile.decode(Map.put(encoded, extra, true))
      end

      assert {:error, :invalid_profile} =
               ValidationProfile.decode(Map.put(encoded, "maxTaskTtlMs", -604_800_000))

      assert {:error, :invalid_profile} =
               ValidationProfile.decode(Map.put(encoded, "maxResultBytes", 2_097_152.5))

      for unsafe_metadata <- [
            %{server: "tama"},
            %{"nested" => [make_ref()]},
            "a string"
          ] do
        assert {:error, :invalid_profile} =
                 ValidationProfile.decode(Map.put(encoded, "resultMetadata", unsafe_metadata))
      end

      assert {:error, :invalid_profile} = ValidationProfile.decode(nil)
      assert {:error, :invalid_profile} = ValidationProfile.decode("a string")
      assert {:error, :invalid_profile} = ValidationProfile.decode(%{:version => 1})
    end
  end

  describe "options/2" do
    test "reconstructs package validation options with the host cache and tool" do
      assert {:ok, profile} = ValidationProfile.from_options(@options)

      assert {:ok, reconstructed} =
               ValidationProfile.options(profile,
                 cache: TestSupport.Cache,
                 cache_options: [],
                 tool: TestSupport.Tools.Echo
               )

      assert Enum.sort(reconstructed) == Enum.sort(@options)

      assert {:ok, without_tool} =
               ValidationProfile.options(profile, cache: TestSupport.Cache)

      refute Keyword.has_key?(without_tool, :tool)
    end

    test "a reconstructed profile validates and transitions the same task" do
      assert {:ok, profile} = ValidationProfile.from_options(@options)

      assert {:ok, reconstructed} =
               ValidationProfile.options(profile,
                 cache: TestSupport.Cache,
                 tool: TestSupport.Tools.Echo
               )

      base = task_attributes("conformance-profile-1")

      assert {:ok, task} = TamaMCP.Task.new(base, @options)
      assert :ok = TamaMCP.Task.validate(task, reconstructed)

      completed = %{
        "resultType" => "complete",
        "content" => [%{"type" => "text", "text" => "done"}],
        "structuredContent" => %{"message" => "done"},
        "isError" => false
      }

      assert {:ok, next} =
               TamaMCP.Task.transition(
                 task,
                 :completed,
                 %{result: completed, last_updated_at: ~U[2026-09-18 12:00:01Z]},
                 reconstructed
               )

      assert :ok = TamaMCP.Task.validate(next, reconstructed)
    end

    test "fails closed on invalid host resolutions" do
      assert {:ok, profile} = ValidationProfile.from_options(@options)

      assert {:error, :invalid_resolution} = ValidationProfile.options(profile, [])

      assert {:error, :invalid_resolution} =
               ValidationProfile.options(profile, cache: "not-a-module")

      assert {:error, :invalid_resolution} =
               ValidationProfile.options(profile, cache: TestSupport.Cache, cache_options: "no")

      assert {:error, :invalid_resolution} =
               ValidationProfile.options(profile, cache: TestSupport.Cache, tool: 42)

      assert {:error, :invalid_resolution} =
               ValidationProfile.options(profile, :not_a_keyword)
    end
  end

  defp task_attributes(id) do
    %{
      id: id,
      owner_key: "owner",
      method: "tools/call",
      request_id: "request-1",
      client_capabilities: %{},
      created_at: ~U[2026-09-18 12:00:00Z],
      last_updated_at: ~U[2026-09-18 12:00:00Z],
      ttl_ms: 60_000
    }
  end

  defp map_keys(map), do: Map.keys(map)
end
