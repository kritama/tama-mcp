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
  result bounds the adapter must pass to task construction and transitions.

  `create/2` must atomically reject an existing `{owner_key, task_id}` and make
  a successful task immediately visible to owner-bound `get/3` calls.
  """

  alias TamaMCP.{Error, Task}

  @type owner_key :: term()
  @type options :: keyword()
  @type lookup_error :: :not_found | Error.t()
  @type mutation_error :: :not_found | :conflict | :invalid_state | Error.t()

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
