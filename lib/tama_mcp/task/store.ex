defmodule TamaMCP.Task.Store do
  @moduledoc """
  Durable, owner-bound storage contract for MCP tasks.

  The adapter owns persistence and transaction boundaries. Task identity is
  always bound to the validated `owner_key`; protocol sessions are not part of
  this contract. Adapter failures must be returned as bounded TamaMCP errors or
  the fixed atoms documented by each callback.

  `transition/6` is a compare-and-update operation. The adapter must update only
  when the stored revision equals `expected_revision`, apply
  `TamaMCP.Task.transition/4` with the runtime-provided validation options while
  holding its write lock, and persist the returned task atomically.

  Transport calls add a reserved `:tama_mcp` keyword to the configured options.
  Its `:task_validation_options` value contains the effective task and encoded
  result bounds, the configured protocol validator cache, and the originating
  tool for output-schema validation. The adapter must pass those options to
  task construction and transitions so state-specific payloads are schema-valid
  before commit. It must also persist the originating client capabilities and
  the task's issued input-request key history. Input requests unsupported by
  those capabilities, reused keys, and transitions exceeding the configured
  lifetime-key limit must be rejected before commit.

  `create/2` must atomically reject an existing `{owner_key, task_id}` and make
  a successful task immediately visible to owner-bound `get/3` calls.

  `update/4` must atomically accept only responses for keys that are currently
  outstanding on an `input_required` task. Unknown, already-answered, and
  superseded keys are ignored. Accepted responses must be recorded
  idempotently before the callback returns `:ok`; the adapter may notify its
  durable worker only after that commit. A request that accepts no new response
  must not signal the worker.

  `cancel/3` must atomically and idempotently record cooperative cancellation
  intent on a non-terminal task. It does not transition the task to
  `cancelled`, and it must not overwrite a terminal state that wins the race.
  The adapter may signal its durable worker only after cancellation intent is
  committed.

  After any visible task transition commits, an adapter may call
  `TamaMCP.Notification.publish_committed/2` with the committed task and
  these store options. Publication is deliberately outside the transaction;
  failure does not roll back the task and clients recover through `tasks/get`.
  """

  alias TamaMCP.{Error, Task}

  @type owner_key :: term()
  @type options :: keyword()
  @type lookup_error :: :not_found | Error.t()
  @type mutation_error ::
          :not_found | :conflict | :invalid_state | :invalid_task | Error.t()

  @callback create(Task.t(), options()) ::
              {:ok, Task.t()} | {:error, :conflict | Error.t()}

  @callback get(owner_key(), String.t(), options()) ::
              {:ok, Task.t()} | {:error, lookup_error()}

  @callback transition(
              owner_key(),
              String.t(),
              non_neg_integer(),
              Task.status(),
              map() | keyword(),
              options()
            ) :: {:ok, Task.t()} | {:error, mutation_error()}

  @callback update(owner_key(), String.t(), map(), options()) ::
              :ok | {:error, mutation_error()}

  @callback cancel(owner_key(), String.t(), options()) ::
              :ok | {:error, mutation_error()}
end
