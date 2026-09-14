defmodule TamaMCP.TestSupport.Tools.TaskRequired do
  @moduledoc false

  use TamaMCP.Tool,
    task: :required,
    scopes: ["test.task_required"],
    description: "Declares a task policy of :required."

  input_schema do
    field(:value, :string, required: true, min_length: 1)
  end

  @impl true
  def call(%{"value" => value}, _context) do
    {:ok, TamaMCP.Response.success(content: [TamaMCP.Response.text(value)])}
  end
end

defmodule TamaMCP.TestSupport.TaskRequiredServer do
  @moduledoc false

  use TamaMCP.Server,
    name: "tama-mcp-task-required",
    version: "0.0.1-test",
    instructions: "A test MCP server with a task-required tool."

  tool(TamaMCP.TestSupport.Tools.TaskRequired, name: "task_required")
end
