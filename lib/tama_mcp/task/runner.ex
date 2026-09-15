defmodule TamaMCP.Task.Runner do
  @moduledoc """
  Application-owned atomic handoff from a validated tool call to durable work.

  Returning `{:ok, task}` asserts that the task is durably visible through the
  configured `TamaMCP.Task.Store`, its execution handoff has been accepted, and
  the returned task is in `working`. Returning an error asserts that no task
  handle was exposed and no unreconciled externally visible task remains.

  The `:tama_mcp` entry in `options` contains the generated task identity,
  timestamps, effective clock and store options, and `:task_validation_options`
  that must be passed to `TamaMCP.Task.new/2` and every later task transition.
  The generated task fields include the originating request's client
  capabilities, which must be persisted unchanged for later input-request
  checks. The validation options retain the originating tool for output-schema
  checks.
  """

  @callback start(
              tool :: module(),
              input :: map(),
              context :: TamaMCP.Context.t(),
              options :: keyword()
            ) :: {:ok, TamaMCP.Task.t()} | {:error, TamaMCP.Error.t()}
end
