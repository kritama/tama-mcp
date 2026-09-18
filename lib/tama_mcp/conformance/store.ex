defmodule TamaMCP.Conformance.Store do
  @moduledoc """
  Acceptance harness for the `TamaMCP.Task.Store` behaviour.

  `check/2` exercises every documented store contract rule through the public
  callbacks only. The host supplies:

    * `:adapter_options` — the keyword list passed to every adapter callback.
      Include the reserved `:tama_mcp` namespace with `:task_validation_options`
      when the adapter applies package task validation, as the transport does.
    * `:task_factory` — a 0-arity function returning a fresh, valid
      `working` task with a unique ID on every call.
    * `:task_validation_options` — the keyword list the harness uses to build
      fixture transitions; it must include the host's schema `:cache`.
    * `:setup` / `:cleanup` — optional 0-arity functions around the checks.
    * `:fresh_instance` — optional 0-arity function returning fresh adapter
      options for a newly started store instance. Hosts that guarantee durable
      state across processes supply it to exercise retrieval through the
      fresh instance.

  A violated contract rule raises `TamaMCP.Conformance.Failure` naming the
  callback and rule. Host configuration problems raise `ArgumentError`.

  Minimal host example:

      setup do
        {:ok, store} = TamaMCP.MyTaskStore.start_link()

        %{store: store, validation: [cache: TamaMCP.MySchemaCache]}
      end

      test "my store conforms", %{store: store, validation: validation} do
        :ok =
          TamaMCP.Conformance.Store.check(TamaMCP.MyTaskStore,
            adapter_options: [
              store: store,
              tama_mcp: [task_validation_options: validation]
            ],
            task_factory: fn -> fresh_task() end,
            task_validation_options: validation
          )
      end

  where `fresh_task/0` returns a unique `working` task, for example through
  `TamaMCP.Task.new/2`.
  """

  alias TamaMCP.Conformance.Failure
  alias TamaMCP.{Error, Task}

  @doc """
  Runs the `TamaMCP.Task.Store` contract suite against `adapter`.

  Returns `:ok` when every check passes and raises
  `TamaMCP.Conformance.Failure` on the first violated rule. See the
  moduledoc for the required and optional options.
  """
  @spec check(module(), keyword()) :: :ok
  def check(adapter, options) when is_atom(adapter) and is_list(options) do
    ctx = context!(adapter, options)

    try do
      ctx.setup.()

      create_visibility(ctx)
      owner_binding(ctx)
      revision_conflicts(ctx)
      strict_progression(ctx)
      state_transitions(ctx)
      terminal_replay(ctx)
      input_responses(ctx)
      cancellation(ctx)

      if ctx.fresh_instance, do: durability(ctx)
      :ok
    after
      ctx.cleanup.()
    end
  end

  defp context!(adapter, options) do
    validation = required_keyword!(options, :task_validation_options)
    factory = required_function!(options, :task_factory)
    sample = factory.()

    case sample do
      %Task{status: :working} ->
        :ok

      _invalid ->
        raise(
          ArgumentError,
          ":task_factory must return a %TamaMCP.Task{} in :working status"
        )
    end

    case Task.validate(sample, validation) do
      :ok ->
        :ok

      {:error, :invalid_task} ->
        raise(
          ArgumentError,
          ":task_factory returned a task that fails TamaMCP.Task.validate/2"
        )
    end

    %{
      adapter: adapter,
      adapter_options: required_keyword!(options, :adapter_options),
      factory: factory,
      validation: validation,
      setup: optional_function(options, :setup, fn -> :ok end),
      cleanup: optional_function(options, :cleanup, fn -> :ok end),
      fresh_instance: fresh_instance!(options)
    }
  end

  defp fresh_instance!(options) do
    case Keyword.get(options, :fresh_instance) do
      nil ->
        nil

      fun when is_function(fun, 0) ->
        fun

      _invalid ->
        raise(
          ArgumentError,
          ":fresh_instance must be a 0-arity function returning fresh adapter options"
        )
    end
  end

  defp required_keyword!(options, key) do
    case Keyword.get(options, key) do
      keyword when is_list(keyword) ->
        keyword

      _invalid ->
        raise(ArgumentError, ":#{key} must be a keyword list")
    end
  end

  defp required_function!(options, key) do
    case Keyword.get(options, key) do
      fun when is_function(fun, 0) ->
        fun

      _invalid ->
        raise(ArgumentError, ":#{key} must be a 0-arity function")
    end
  end

  defp optional_function(options, key, default) do
    case Keyword.get(options, key, default) do
      fun when is_function(fun, 0) ->
        fun

      _invalid ->
        raise(ArgumentError, ":#{key} must be a 0-arity function")
    end
  end

  # Invocations -------------------------------------------------------------

  defp call!(callback, fun) do
    fun.()
  rescue
    exception ->
      fail!(callback, "must not raise on contract-valid calls", Exception.message(exception))
  catch
    kind, reason ->
      fail!(callback, "must not raise on contract-valid calls", "#{kind}: #{bounded(reason)}")
  end

  defp create!(ctx, task) do
    case call!("create/2", fn -> ctx.adapter.create(task, ctx.adapter_options) end) do
      {:ok, %Task{} = created} when created.id == task.id ->
        created

      {:error, :conflict} ->
        fail!("create/2", "a first create for a fresh {owner_key, task_id} must succeed")

      {:error, %Error{}} ->
        fail!("create/2", "a first create for a fresh {owner_key, task_id} must succeed")

      other ->
        fail!("create/2", "must return {:ok, task} on success", bounded(other))
    end
  end

  defp raw_get(ctx, owner_key, task_id) do
    call!("get/3", fn -> ctx.adapter.get(owner_key, task_id, ctx.adapter_options) end)
  end

  defp get!(ctx, owner_key, task_id, rule) do
    case raw_get(ctx, owner_key, task_id) do
      {:ok, %Task{} = stored} ->
        stored

      other ->
        fail!("get/3", rule, bounded(other))
    end
  end

  defp raw_transition(ctx, task, status, attributes, revision \\ :current) do
    revision = if revision == :current, do: task.revision, else: revision

    call!("transition/5", fn ->
      ctx.adapter.transition(
        task.owner_key,
        task.id,
        revision,
        status,
        attributes,
        ctx.adapter_options
      )
    end)
  end

  defp transition!(ctx, task, status, attributes) do
    case raw_transition(ctx, task, status, attributes) do
      {:ok, %Task{} = next} when next.id == task.id ->
        next

      other ->
        fail!("transition/5", "a valid transition must succeed", bounded(other))
    end
  end

  defp raw_update(ctx, task, responses) do
    call!("update/4", fn ->
      ctx.adapter.update(task.owner_key, task.id, responses, ctx.adapter_options)
    end)
  end

  defp raw_cancel(ctx, task) do
    call!("cancel/3", fn -> ctx.adapter.cancel(task.owner_key, task.id, ctx.adapter_options) end)
  end

  # Checks ------------------------------------------------------------------

  defp create_visibility(ctx) do
    task = ctx.factory.()
    created = create!(ctx, task)

    stored =
      get!(
        ctx,
        task.owner_key,
        task.id,
        "a successfully created task must be immediately visible"
      )

    unless stored.id == created.id,
      do: fail!("get/3", "must return the created task", "returned task ID #{stored.id}")

    duplicate =
      call!("create/2", fn ->
        ctx.adapter.create(
          %{task | created_at: DateTime.add(task.created_at, 1, :second)},
          ctx.adapter_options
        )
      end)

    case duplicate do
      {:error, :conflict} ->
        :ok

      {:error, %Error{}} ->
        :ok

      other ->
        fail!(
          "create/2",
          "an existing {owner_key, task_id} must be atomically rejected with a conflict",
          bounded(other)
        )
    end
  end

  defp owner_binding(ctx) do
    task = ctx.factory.()
    create!(ctx, task)
    other_owner = {:conformance_other_owner, task.id}
    missing_id = "conformance-missing-#{task.id}"

    unless indistinguishable?(
             raw_get(ctx, other_owner, task.id),
             raw_get(ctx, task.owner_key, missing_id)
           ),
           do:
             fail!(
               "get/3",
               "missing and unauthorized results must be indistinguishable errors",
               "unauthorized: #{bounded(raw_get(ctx, other_owner, task.id))}; " <>
                 "missing: #{bounded(raw_get(ctx, task.owner_key, missing_id))}"
             )

    unless indistinguishable?(
             raw_update(ctx, %{task | owner_key: other_owner}, %{}),
             raw_update(ctx, %{task | id: missing_id}, %{})
           ),
           do:
             fail!(
               "update/4",
               "missing and unauthorized results must be indistinguishable errors"
             )

    unless indistinguishable?(
             raw_cancel(ctx, %{task | owner_key: other_owner}),
             raw_cancel(ctx, %{task | id: missing_id})
           ),
           do:
             fail!(
               "cancel/3",
               "missing and unauthorized results must be indistinguishable errors"
             )

    :ok
  end

  defp indistinguishable?(left, right) do
    lookup_error?(left) and lookup_error?(right) and left == right
  end

  defp lookup_error?({:error, :not_found}), do: true
  defp lookup_error?({:error, %Error{}}), do: true
  defp lookup_error?(_other), do: false

  defp revision_conflicts(ctx) do
    task = ctx.factory.()
    create!(ctx, task)
    current = transition!(ctx, task, :working, working_attributes(task, "step one"))

    stale =
      raw_transition(
        ctx,
        task,
        :working,
        working_attributes(current, "stale step"),
        task.revision
      )

    unless match?({:error, :conflict}, stale),
      do: fail!("transition/5", "a stale revision must fail with :conflict", bounded(stale))

    missing =
      raw_transition(
        ctx,
        %{task | id: "conformance-missing-#{task.id}"},
        :working,
        working_attributes(current, "missing task")
      )

    unless lookup_error?(missing),
      do:
        fail!("transition/5", "a missing task must fail with a not_found error", bounded(missing))

    :ok
  end

  defp strict_progression(ctx) do
    task = ctx.factory.()
    create!(ctx, task)

    equal =
      raw_transition(ctx, task, :working, %{
        status_message: "equal instant",
        last_updated_at: task.last_updated_at
      })

    unless match?({:error, _}, equal),
      do:
        fail!(
          "transition/5",
          "an equal last_updated_at must not advance the task",
          bounded(equal)
        )

    older =
      raw_transition(ctx, task, :working, %{
        status_message: "older instant",
        last_updated_at: DateTime.add(task.last_updated_at, -1, :second)
      })

    unless match?({:error, _}, older),
      do:
        fail!(
          "transition/5",
          "an older last_updated_at must not advance the task",
          bounded(older)
        )

    supplied = DateTime.add(task.last_updated_at, 1, :millisecond)

    next =
      transition!(ctx, task, :working, %{status_message: "advanced", last_updated_at: supplied})

    stored = get!(ctx, task.owner_key, task.id, "a transitioned task must remain visible")

    unless stored.revision == task.revision + 1,
      do:
        fail!(
          "transition/5",
          "a committed transition must advance the revision by exactly one",
          "expected #{task.revision + 1}, got #{stored.revision}"
        )

    unless stored.last_updated_at == supplied,
      do:
        fail!(
          "transition/5",
          "a committed transition must store the supplied last_updated_at",
          bounded(stored.last_updated_at)
        )

    unless next.revision == stored.revision,
      do:
        fail!(
          "transition/5",
          "the returned snapshot must match the stored revision"
        )

    :ok
  end

  defp state_transitions(ctx) do
    task = ctx.factory.()
    create!(ctx, task)

    requests = %{"approval" => elicitation_request()}

    input =
      transition!(ctx, task, :input_required, %{
        input_requests: requests,
        last_updated_at: later(task.last_updated_at)
      })

    unless input.status == :input_required and input.input_requests == requests,
      do:
        fail!(
          "transition/5",
          "an input_required transition must retain its input requests",
          bounded(input.input_requests)
        )

    completed =
      transition!(ctx, input, :completed, %{
        result: complete_result(),
        last_updated_at: later(input.last_updated_at)
      })

    unless completed.status == :completed,
      do:
        fail!(
          "transition/5",
          "a completed transition must reach :completed",
          bounded(completed.status)
        )

    revived = raw_transition(ctx, completed, :working, working_attributes(completed, "revive"))

    unless match?({:error, :invalid_state}, revived),
      do:
        fail!(
          "transition/5",
          "a non-replay transition out of a terminal state must fail with :invalid_state",
          bounded(revived)
        )

    :ok
  end

  defp terminal_replay(ctx) do
    task = ctx.factory.()
    create!(ctx, task)
    result = complete_result()
    timestamp = later(task.last_updated_at)
    completed = transition!(ctx, task, :completed, %{result: result, last_updated_at: timestamp})

    replay =
      raw_transition(ctx, completed, :completed, %{result: result, last_updated_at: timestamp})

    case replay do
      {:ok, %Task{} = same}
      when same.id == completed.id and same.revision == completed.revision ->
        :ok

      other ->
        fail!(
          "transition/5",
          "an exact terminal replay must return the committed task without advancing the revision",
          bounded(other)
        )
    end

    mutated =
      raw_transition(ctx, completed, :completed, %{
        result: Map.put(result, "isError", true),
        last_updated_at: timestamp
      })

    unless match?({:error, :invalid_state}, mutated),
      do:
        fail!(
          "transition/5",
          "a terminal replay with changed attributes must fail with :invalid_state",
          bounded(mutated)
        )

    :ok
  end

  defp input_responses(ctx) do
    {task, input, approval_response, followup_response} = input_response_fixture(ctx)
    partial = partial_update!(ctx, task, input, approval_response)
    replay_no_op!(ctx, task, partial, approval_response)
    unknown_no_op!(ctx, task, partial, approval_response)
    unsafe_rejection!(ctx, partial)
    complete_update!(ctx, task, partial, followup_response)
    off_status_update!(ctx, approval_response)
    :ok
  end

  defp input_response_fixture(ctx) do
    task = ctx.factory.()
    create!(ctx, task)
    approval = elicitation_request()
    followup = followup_request()

    input =
      transition!(ctx, task, :input_required, %{
        input_requests: %{"approval" => approval, "followup" => followup},
        last_updated_at: later(task.last_updated_at)
      })

    {task, input, response(%{"approved" => true}), response(%{"notes" => "done"})}
  end

  defp partial_update!(ctx, task, input, approval_response) do
    partial_result = raw_update(ctx, input, %{"approval" => approval_response})

    unless partial_result == :ok,
      do:
        fail!(
          "update/4",
          "a partial input response must be accepted",
          bounded(partial_result)
        )

    partial = get!(ctx, task.owner_key, task.id, "a partially updated task must remain readable")

    unless partial.status == :input_required and
             partial.input_requests == %{"followup" => followup_request()} and
             partial.revision == input.revision + 1,
           do:
             fail!(
               "update/4",
               "a partial update must record the response, retain only the remaining requests, and advance the revision",
               bounded(partial)
             )

    partial
  end

  defp replay_no_op!(ctx, task, partial, approval_response) do
    unless raw_update(ctx, partial, %{"approval" => approval_response}) == :ok,
      do: fail!("update/4", "replaying an already recorded response must be a no-op")

    replayed = get!(ctx, task.owner_key, task.id, "a no-op update must leave the task readable")

    unless replayed.revision == partial.revision,
      do:
        fail!(
          "update/4",
          "a no-op update must not advance the revision",
          bounded(replayed.revision)
        )
  end

  defp unknown_no_op!(ctx, task, partial, approval_response) do
    unless raw_update(ctx, partial, %{"unexpected" => approval_response}) == :ok,
      do: fail!("update/4", "an unknown input key must be ignored as a no-op")

    unknown =
      get!(ctx, task.owner_key, task.id, "an unknown-key update must leave the task readable")

    unless unknown.revision == partial.revision,
      do:
        fail!(
          "update/4",
          "an unknown-key update must not advance the revision",
          bounded(unknown.revision)
        )
  end

  defp unsafe_rejection!(ctx, partial) do
    unsafe =
      raw_update(ctx, partial, %{
        "followup" => %{"values" => %{"mode" => "form", "value" => %{notes: "not JSON safe"}}}
      })

    unless match?({:error, :invalid_input}, unsafe),
      do:
        fail!(
          "update/4",
          "a non-JSON-safe input response must fail with :invalid_input",
          bounded(unsafe)
        )
  end

  defp complete_update!(ctx, task, partial, followup_response) do
    unless raw_update(ctx, partial, %{"followup" => followup_response}) == :ok,
      do: fail!("update/4", "the final outstanding input response must be accepted")

    complete = get!(ctx, task.owner_key, task.id, "a fully answered task must remain readable")

    unless complete.input_requests == %{},
      do:
        fail!(
          "update/4",
          "a complete update must clear all outstanding input requests",
          bounded(complete.input_requests)
        )
  end

  defp off_status_update!(ctx, approval_response) do
    fresh = ctx.factory.()
    create!(ctx, fresh)

    case raw_update(ctx, fresh, %{"approval" => approval_response}) do
      :ok ->
        stored = get!(ctx, fresh.owner_key, fresh.id, "an updated task must remain readable")

        unless stored.revision == fresh.revision,
          do:
            fail!(
              "update/4",
              "an update on a non-input_required task must not advance the revision",
              bounded(stored.revision)
            )

      {:error, :invalid_state} ->
        :ok

      other ->
        fail!(
          "update/4",
          "an update on a non-input_required task must be a no-op or fail with :invalid_state",
          bounded(other)
        )
    end
  end

  defp cancellation(ctx) do
    task = ctx.factory.()
    create!(ctx, task)

    first = raw_cancel(ctx, task)

    unless first == :ok,
      do:
        fail!(
          "cancel/3",
          "cancelling a non-terminal task must succeed",
          bounded(first)
        )

    stored = get!(ctx, task.owner_key, task.id, "a cancelled-intent task must remain readable")

    unless stored.status in [:working, :input_required],
      do:
        fail!(
          "cancel/3",
          "a cancel intent must not make a non-terminal task terminal",
          bounded(stored.status)
        )

    unless raw_cancel(ctx, task) == :ok,
      do: fail!("cancel/3", "a repeated cancel intent must remain idempotent")

    terminal = ctx.factory.()
    create!(ctx, terminal)

    completed =
      transition!(ctx, terminal, :completed, %{
        result: complete_result(),
        last_updated_at: later(terminal.last_updated_at)
      })

    rejected = raw_cancel(ctx, completed)

    unless match?({:error, :invalid_state}, rejected) or match?({:error, %Error{}}, rejected),
      do: fail!("cancel/3", "a cancel against a terminal task must fail", bounded(rejected))

    :ok
  end

  defp durability(ctx) do
    fresh_options = ctx.fresh_instance.()

    unless is_list(fresh_options),
      do:
        raise(
          ArgumentError,
          ":fresh_instance must return a keyword list of fresh adapter options"
        )

    task = ctx.factory.()
    create!(ctx, task)
    next = transition!(ctx, task, :working, working_attributes(task, "durable step"))

    case call!("get/3", fn -> ctx.adapter.get(task.owner_key, task.id, fresh_options) end) do
      {:ok, %Task{} = stored} when stored.revision == next.revision ->
        :ok

      other ->
        fail!(
          "get/3",
          "a durable task must be retrievable through fresh adapter options",
          bounded(other)
        )
    end
  end

  # Fixtures ----------------------------------------------------------------

  defp working_attributes(task, message) do
    %{status_message: message, last_updated_at: later(task.last_updated_at)}
  end

  defp later(timestamp), do: DateTime.add(timestamp, 1, :millisecond)

  defp elicitation_request do
    %{
      "method" => "elicitation/create",
      "params" => %{
        "message" => "Conformance approval",
        "mode" => "form",
        "requestedSchema" => %{
          "type" => "object",
          "properties" => %{"approved" => %{"type" => "boolean"}},
          "required" => ["approved"]
        }
      }
    }
  end

  defp followup_request do
    %{
      "method" => "elicitation/create",
      "params" => %{
        "message" => "Conformance follow-up",
        "mode" => "form",
        "requestedSchema" => %{
          "type" => "object",
          "properties" => %{"notes" => %{"type" => "string"}}
        }
      }
    }
  end

  defp response(value) do
    %{"values" => %{"mode" => "form", "value" => value}}
  end

  defp complete_result do
    %{"resultType" => "complete", "content" => [], "isError" => false}
  end

  @spec fail!(String.t(), String.t()) :: no_return
  @spec fail!(String.t(), String.t(), term()) :: no_return

  defp fail!(callback, rule, details \\ nil) do
    raise Failure, callback: callback, rule: rule, details: details
  end

  defp bounded(term) when is_binary(term), do: term
  defp bounded(term), do: inspect(term, limit: 40)
end
