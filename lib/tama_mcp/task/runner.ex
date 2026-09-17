defmodule TamaMCP.Task.Runner do
  @moduledoc """
  Application-owned atomic handoff from a validated tool call to durable work.

  Returning `{:ok, task}` asserts that the task is durably visible through the
  configured `TamaMCP.Task.Store`, its execution handoff has been accepted, and
  the returned task is in `working`. Returning an error asserts that no task
  handle was exposed and no unreconciled externally visible task remains.

  ## Returned snapshot

  `start/4` must return the initial `working` snapshot it constructed from the
  generated identity, timestamps, and options in `:tama_mcp` — the value the
  transport generated the task identity for — not a later snapshot read back
  from the store.

  The transport validates the returned task against that generated initial
  snapshot exactly, including `status: :working` and the initial revision. A
  runner that returns a committed newer snapshot is rejected and the request
  fails with a protocol error.

  The persisted row may legitimately be newer than the returned snapshot, for
  example when the durable handoff reuses an already-terminal Submission and
  the committed row reaches a terminal state inside the same transaction that
  created it. The transport reconciles this by reading the durable row through
  `TamaMCP.Task.Store.get/3` and accepting revision and `last_updated_at`
  progression against the returned snapshot; it does not require the returned
  and persisted snapshots to match.

  The `:tama_mcp` entry in `options` contains the generated task identity,
  timestamps, effective clock and store options, and `:task_validation_options`
  that must be passed to `TamaMCP.Task.new/2` and every later task transition.
  The generated task fields include the originating request's client
  capabilities, which must be persisted unchanged for later input-request
  checks. The validation options retain the originating tool for output-schema
  checks. The namespace also carries the optional notification adapter and its
  options so the runner can publish each snapshot only after its durable state
  transition commits.
  """

  @callback start(
              tool :: module(),
              input :: map(),
              context :: TamaMCP.Context.t(),
              options :: keyword()
            ) :: {:ok, TamaMCP.Task.t()} | {:error, TamaMCP.Error.t()}
end
