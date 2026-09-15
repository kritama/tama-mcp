defmodule TamaMCP.TaskRunner do
  @moduledoc """
  Application-owned atomic handoff from a validated tool call to durable work.

  Returning `{:ok, task}` asserts that the task is durably visible through the
  configured `TamaMCP.TaskStore`, its execution handoff has been accepted, and
  the returned task is in `working`. Returning an error asserts that no task
  handle was exposed and no unreconciled externally visible task remains.
  """

  @callback start(
              tool :: module(),
              input :: map(),
              context :: TamaMCP.Context.t(),
              options :: keyword()
            ) :: {:ok, TamaMCP.Task.t()} | {:error, TamaMCP.Error.t()}
end
