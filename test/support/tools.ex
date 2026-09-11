defmodule TamaMCP.TestSupport.Tools.Echo do
  @moduledoc false

  use TamaMCP.Tool,
    task: :disabled,
    scopes: ["test.echo"],
    description: "Echoes the provided message back to the caller."

  input_schema do
    field(:message, :string, required: true, min_length: 1)
  end

  output_schema do
    field(:message, :string, required: true)
  end

  @impl true
  def call(%{"message" => message}, _context) do
    {:ok,
     TamaMCP.Response.success(
       content: [TamaMCP.Response.text("echo: " <> message)],
       structured_content: %{"message" => message}
     )}
  end
end

defmodule TamaMCP.TestSupport.Tools.Failing do
  @moduledoc false

  use TamaMCP.Tool,
    task: :disabled,
    scopes: ["test.failing"],
    description: "Always fails with a domain tool error."

  input_schema do
    field(:reason, :string, required: true)
  end

  @impl true
  def call(_input, _context) do
    {:ok,
     TamaMCP.Response.tool_error(content: [TamaMCP.Response.text("the domain operation failed")])}
  end
end

defmodule TamaMCP.TestSupport.Tools.Headers do
  @moduledoc false

  use TamaMCP.Tool,
    task: :disabled,
    scopes: ["test.headers"],
    description: "Validates parameters mirrored into HTTP headers."

  raw_input_schema(%{
    "type" => "object",
    "properties" => %{
      "enabled" => %{"type" => "boolean", "x-mcp-header" => "Enabled"},
      "note" => %{"type" => "string", "x-mcp-header" => "Note"},
      "region" => %{"type" => "string", "x-mcp-header" => "Region"},
      "routing" => %{
        "type" => "object",
        "properties" => %{
          "shard" => %{"type" => "integer", "x-mcp-header" => "Shard"}
        },
        "required" => ["shard"],
        "additionalProperties" => false
      }
    },
    "required" => ["enabled", "region", "routing"],
    "additionalProperties" => false
  })

  @impl true
  def call(_input, _context), do: {:ok, TamaMCP.Response.success()}
end

defmodule TamaMCP.TestSupport.Tools.ProtocolFailing do
  @moduledoc false

  use TamaMCP.Tool,
    task: :disabled,
    scopes: ["test.protocol_failing"],
    description: "Always fails with a JSON-RPC protocol error."

  input_schema do
    field(:boom, :boolean, required: true)
  end

  @impl true
  def call(_input, _context) do
    {:error, TamaMCP.Error.internal("the tool raised a protocol failure")}
  end
end

defmodule TamaMCP.TestSupport.Tools.Context do
  @moduledoc false

  use TamaMCP.Tool, task: :disabled, scopes: ["test.context"]

  output_schema do
    field(:owner, :string, required: true)
    field(:trace, :string, required: true)
    field(:workspace, :string, required: true)
  end

  @impl true
  def call(_input, context) do
    {:ok,
     TamaMCP.Response.success(
       structured_content: %{
         "owner" => context.owner_key,
         "trace" => context.headers["x-trace"] || "omitted",
         "workspace" => context.assigns.workspace
       },
       meta: %{
         TamaMCP.Protocol.meta_key(:server_info) => %{"name" => "spoofed", "version" => "0"}
       }
     )}
  end
end

defmodule TamaMCP.TestSupport.Tools.Invalid do
  @moduledoc false

  use TamaMCP.Tool, task: :disabled, scopes: ["test.invalid"]

  @impl true
  def call(_input, _context) do
    {:ok, TamaMCP.Response.success(content: [%{"type" => "made-up"}])}
  end
end

defmodule TamaMCP.TestSupport.Tools.InvalidOutput do
  @moduledoc false

  use TamaMCP.Tool, task: :disabled, scopes: ["test.invalid_output"]

  output_schema do
    field(:status, :string, required: true)
  end

  @impl true
  def call(_input, _context) do
    {:ok, TamaMCP.Response.success(structured_content: %{"status" => 123})}
  end
end

defmodule TamaMCP.TestSupport.Tools.Null do
  @moduledoc false

  use TamaMCP.Tool, task: :disabled, scopes: ["test.null"]

  raw_output_schema(%{"type" => "null"})

  @impl true
  def call(_input, _context) do
    {:ok, TamaMCP.Response.success(structured_content: nil)}
  end
end

defmodule TamaMCP.TestSupport.Tools.Slow do
  @moduledoc false

  use TamaMCP.Tool, task: :disabled, scopes: ["test.slow"]

  @impl true
  def call(_input, _context) do
    Process.sleep(1_000)
    {:ok, TamaMCP.Response.success()}
  end
end
