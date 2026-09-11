defmodule TamaMCP.Transport.StreamableHTTP.Result do
  @moduledoc false

  alias TamaMCP.Protocol

  def discover(server) do
    result = %{
      "resultType" => Protocol.result_type(:complete),
      "supportedVersions" => Protocol.supported_versions(),
      "capabilities" => %{"tools" => %{}},
      "ttlMs" => 0,
      "cacheScope" => "private",
      "_meta" => metadata(server)
    }

    case server.instructions() do
      nil -> result
      instructions -> Map.put(result, "instructions", instructions)
    end
  end

  def tools(server, granted \\ :all) do
    tools =
      server.tools()
      |> Enum.filter(&visible?(&1, granted))
      |> Enum.map(&Map.put(&1.module.definition(), "name", &1.name))

    %{
      "resultType" => Protocol.result_type(:complete),
      "tools" => tools,
      "ttlMs" => 0,
      "cacheScope" => "private",
      "_meta" => metadata(server)
    }
  end

  def metadata(server) do
    %{
      Protocol.meta_key(:server_info) => %{
        "name" => server.name(),
        "version" => server.version()
      }
    }
  end

  defp visible?(_entry, :all), do: true
  defp visible?(entry, granted), do: Enum.all?(entry.module.scopes(), &(&1 in granted))
end
