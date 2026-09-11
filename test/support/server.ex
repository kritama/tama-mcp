defmodule TamaMCP.TestSupport.Server do
  @moduledoc false

  use TamaMCP.Server,
    name: "tama-mcp-test",
    version: "0.0.1-test",
    instructions: "A test MCP server."

  tool(TamaMCP.TestSupport.Tools.Echo, name: "echo")
  tool(TamaMCP.TestSupport.Tools.Failing, name: "failing")
  tool(TamaMCP.TestSupport.Tools.Context, name: "context")
  tool(TamaMCP.TestSupport.Tools.Invalid, name: "invalid")
  tool(TamaMCP.TestSupport.Tools.InvalidOutput, name: "invalid_output")
  tool(TamaMCP.TestSupport.Tools.ProtocolFailing, name: "protocol_failing")
  tool(TamaMCP.TestSupport.Tools.Slow, name: "slow")
end
