defmodule TamaMCP.Conformance.TestViolatingStore do
  @moduledoc false

  @behaviour TamaMCP.Task.Store

  alias TamaMCP.Task
  alias TamaMCP.TestSupport.Tasks.Store

  @impl true
  def create(task, options), do: Store.create(task, options)

  @impl true
  def get(_owner_key, _task_id, _options) do
    timestamp = ~U[2026-01-01 00:00:00Z]

    {:ok,
     %Task{
       id: "conformance-ghost",
       owner_key: "conformance-ghost-owner",
       method: "tools/call",
       request_id: "conformance-ghost-request",
       client_capabilities: %{},
       status: :working,
       created_at: timestamp,
       last_updated_at: timestamp,
       ttl_ms: 60_000
     }}
  end

  @impl true
  def transition(owner_key, task_id, revision, status, attributes, options),
    do: Store.transition(owner_key, task_id, revision, status, attributes, options)

  @impl true
  def update(owner_key, task_id, input_responses, options),
    do: Store.update(owner_key, task_id, input_responses, options)

  @impl true
  def cancel(owner_key, task_id, options), do: Store.cancel(owner_key, task_id, options)
end

defmodule TamaMCP.Conformance.TestMaliciousNotification do
  @moduledoc false

  @behaviour TamaMCP.Notification

  alias TamaMCP.Notification.Local

  @impl true
  def subscribe(task_ids, subscriber, capacity, options),
    do: Local.subscribe(task_ids, subscriber, capacity, options)

  @impl true
  def take(_subscription, _options), do: {:ok, "not a task"}

  @impl true
  def unsubscribe(subscription, options), do: Local.unsubscribe(subscription, options)

  @impl true
  def publish(task, options), do: Local.publish(task, options)
end

defmodule TamaMCP.Conformance.TestStrictNotification do
  @moduledoc false

  @behaviour TamaMCP.Notification

  alias TamaMCP.{Error, Task}
  alias TamaMCP.Notification.Local

  @impl true
  def subscribe(task_ids, subscriber, capacity, options),
    do: Local.subscribe(task_ids, subscriber, capacity, options)

  @impl true
  def take(subscription, options), do: Local.take(subscription, options)

  @impl true
  def unsubscribe(subscription, options), do: Local.unsubscribe(subscription, options)

  @impl true
  def publish(%Task{} = task, options) do
    guard = Keyword.fetch!(options, :strict_guard)
    latest = Agent.get(guard, &Map.get(&1, task.id, -1))

    if task.revision <= latest do
      :ok
    else
      Agent.update(guard, &Map.put(&1, task.id, task.revision))
      Local.publish(task, options)
    end
  end

  def publish(_task, _options), do: {:error, Error.internal()}
end

defmodule TamaMCP.Conformance.TestFailingSubscribeNotification do
  @moduledoc false

  @behaviour TamaMCP.Notification

  alias TamaMCP.{Error, Task}
  alias TamaMCP.Notification.Local

  @impl true
  def subscribe(_task_ids, _subscriber, _capacity, _options),
    do: {:error, Error.internal()}

  @impl true
  def take(subscription, options), do: Local.take(subscription, options)

  @impl true
  def unsubscribe(subscription, options), do: Local.unsubscribe(subscription, options)

  @impl true
  def publish(task, options), do: Local.publish(task, options)
end

defmodule TamaMCP.Conformance.TestFailingPublishNotification do
  @moduledoc false

  @behaviour TamaMCP.Notification

  alias TamaMCP.{Error, Task}
  alias TamaMCP.Notification.Local

  @impl true
  def subscribe(task_ids, subscriber, capacity, options),
    do: Local.subscribe(task_ids, subscriber, capacity, options)

  @impl true
  def take(subscription, options), do: Local.take(subscription, options)

  @impl true
  def unsubscribe(subscription, options), do: Local.unsubscribe(subscription, options)

  @impl true
  def publish(_task, _options), do: {:error, Error.internal()}
end

defmodule TamaMCP.Conformance.TestMutantStore do
  @moduledoc false

  @behaviour TamaMCP.Task.Store

  alias TamaMCP.{Error, Task, TestSupport}

  @impl true
  def create(task, options) do
    case mutation(options) do
      :conflict_create ->
        {:error, :conflict}

      :error_create ->
        {:error, Error.internal()}

      :ghost_create ->
        {:ok, "not a task"}

      _invalid ->
        TestSupport.Tasks.Store.create(task, options)
    end
  end

  @impl true
  def get(owner_key, task_id, options) do
    case mutation(options) do
      :raise_get ->
        raise("adapter exploded")

      :throw_get ->
        throw("adapter exploded")

      :ghost_get ->
        {:ok, "not a task"}

      :distinguishable_get ->
        distinguishable_get(owner_key, task_id, options)

      _invalid ->
        TestSupport.Tasks.Store.get(owner_key, task_id, options)
    end
  end

  @impl true
  def transition(owner_key, task_id, revision, status, attributes, options) do
    args = {owner_key, task_id, revision, status, attributes, options}

    case mutation(options) do
      :stale_transition -> stale_transition(args)
      :missing_transition -> missing_transition(args)
      :frozen_transition -> frozen_transition(args)
      :mangle_transition -> mangle_transition(args)
      :replay_conflict -> replay_transition(args)
      _invalid -> transition_ref(args)
    end
  end

  @impl true
  def update(owner_key, task_id, input_responses, options) do
    case mutation(options) do
      :advancing_update ->
        advancing_update(owner_key, task_id, input_responses, options)

      _invalid ->
        TestSupport.Tasks.Store.update(owner_key, task_id, input_responses, options)
    end
  end

  @impl true
  def cancel(owner_key, task_id, options) do
    case mutation(options) do
      :terminal_cancel -> terminal_cancel(owner_key, task_id, options)
      _invalid -> TestSupport.Tasks.Store.cancel(owner_key, task_id, options)
    end
  end

  defp transition_ref({owner_key, task_id, revision, status, attributes, options}) do
    TestSupport.Tasks.Store.transition(owner_key, task_id, revision, status, attributes, options)
  end

  defp distinguishable_get(owner_key, task_id, options) do
    case TestSupport.Tasks.Store.get(owner_key, task_id, options) do
      {:error, :not_found} ->
        if is_tuple(owner_key), do: {:error, :not_found}, else: {:error, Error.internal()}

      other ->
        other
    end
  end

  defp stale_transition({owner_key, task_id, revision, status, attributes, options}) do
    case TestSupport.Tasks.Store.get(owner_key, task_id, options) do
      {:ok, %Task{revision: stored}} when stored > revision ->
        {:error, :invalid_state}

      {:ok, _} ->
        transition_ref({owner_key, task_id, revision, status, attributes, options})

      other ->
        other
    end
  end

  defp missing_transition({owner_key, task_id, revision, status, attributes, options}) do
    case TestSupport.Tasks.Store.get(owner_key, task_id, options) do
      {:ok, _} ->
        transition_ref({owner_key, task_id, revision, status, attributes, options})

      {:error, _} ->
        {:ok, ghost(:working)}
    end
  end

  defp frozen_transition({owner_key, task_id, revision, status, attributes, options}) do
    before = TestSupport.Tasks.Store.get(owner_key, task_id, options)

    case {before, transition_ref({owner_key, task_id, revision, status, attributes, options})} do
      {{:ok, %Task{revision: before_revision}}, {:ok, %Task{} = committed}} ->
        {:ok, %{committed | revision: before_revision}}

      {_before, other} ->
        other
    end
  end

  defp mangle_transition(args) do
    {owner_key, _task_id, _revision, status, _attributes, options} = args
    stored = TestSupport.Tasks.Store.get(owner_key, _task_id, options)
    transition_ref(args) |> mangle(stored, status)
  end

  defp replay_transition(args) do
    {owner_key, task_id, _revision, status, attributes, options} = args
    stored = TestSupport.Tasks.Store.get(owner_key, task_id, options)
    transition_ref(args) |> replay_conflict(stored, status, attributes)
  end

  defp advancing_update(owner_key, task_id, input_responses, options) do
    before = TestSupport.Tasks.Store.get(owner_key, task_id, options)
    result = TestSupport.Tasks.Store.update(owner_key, task_id, input_responses, options)

    if result == :ok, do: advance_if_no_op(before, owner_key, task_id, options)
    result
  end

  defp advance_if_no_op(before, owner_key, task_id, options) do
    with {:ok, %Task{} = before_task} <- before,
         {:ok, %Task{} = committed} <- TestSupport.Tasks.Store.get(owner_key, task_id, options) do
      if committed.revision == before_task.revision do
        TestSupport.Tasks.Store.replace(
          owner_key,
          task_id,
          %{committed | revision: committed.revision + 1},
          options
        )
      end
    end
  end

  defp terminal_cancel(owner_key, task_id, options) do
    result = TestSupport.Tasks.Store.cancel(owner_key, task_id, options)

    if result == :ok, do: mark_cancelled(owner_key, task_id, options)
    result
  end

  defp mark_cancelled(owner_key, task_id, options) do
    with {:ok, %Task{} = task} <- TestSupport.Tasks.Store.get(owner_key, task_id, options) do
      TestSupport.Tasks.Store.replace(owner_key, task_id, %{task | status: :cancelled}, options)
    end
  end

  defp mangle({:ok, %Task{status: :input_required} = task}, _stored, _status) do
    {:ok, %{task | input_requests: %{}}}
  end

  defp mangle({:ok, %Task{status: :completed} = task}, _stored, _status) do
    {:ok, %{task | status: :working}}
  end

  defp mangle({:error, :invalid_state}, {:ok, %Task{status: stored_status}}, next_status)
       when stored_status in [:completed, :failed, :cancelled] do
    if next_status == stored_status, do: {:error, :invalid_state}, else: {:ok, ghost(next_status)}
  end

  defp mangle(other, _stored, _status), do: other

  defp replay_conflict(
         result,
         {:ok, %Task{status: status, result: stored_result}},
         next_status,
         attributes
       )
       when status in [:completed, :failed, :cancelled] and next_status == status do
    if Map.get(Map.new(attributes), :result) == stored_result do
      {:error, :conflict}
    else
      {:ok, ghost(status)}
    end
  end

  defp replay_conflict(result, _stored, _next_status, _attributes), do: result

  defp ghost(status) do
    timestamp = ~U[2026-01-01 00:00:00Z]

    %Task{
      id: "conformance-ghost",
      owner_key: "conformance-ghost-owner",
      method: "tools/call",
      request_id: "conformance-ghost-request",
      client_capabilities: %{},
      status: status,
      created_at: timestamp,
      last_updated_at: timestamp,
      ttl_ms: 60_000
    }
  end

  defp mutation(options), do: Keyword.get(options, :mutation)
end

defmodule TamaMCP.Conformance.TestMutantNotification do
  @moduledoc false

  @behaviour TamaMCP.Notification

  alias TamaMCP.{Error, Task}
  alias TamaMCP.Notification.Local

  @impl true
  def subscribe(task_ids, subscriber, capacity, options) do
    case mutation(options) do
      :fail_subscribe ->
        {:error, Error.internal()}

      :bad_subscribe ->
        :ok

      _invalid ->
        Local.subscribe(task_ids, subscriber, capacity, options)
    end
  end

  @impl true
  def take(subscription, options) do
    case mutation(options) do
      :raise_take ->
        raise("adapter exploded")

      :throw_take ->
        throw("adapter exploded")

      :error_take ->
        {:error, Error.internal()}

      :ghost_take ->
        ghostify(Local.take(subscription, options))

      :bump_take ->
        bump(Local.take(subscription, options))

      _invalid ->
        Local.take(subscription, options)
    end
  end

  @impl true
  def unsubscribe(subscription, options) do
    case mutation(options) do
      :fail_unsubscribe ->
        {:error, Error.internal()}

      _invalid ->
        Local.unsubscribe(subscription, options)
    end
  end

  @impl true
  def publish(task, options) do
    case mutation(options) do
      :silent_publish ->
        :ok

      :fail_publish ->
        {:error, Error.internal()}

      _invalid ->
        Local.publish(task, options)
    end
  end

  defp ghostify({:ok, %Task{} = task}), do: {:ok, %{task | id: "conformance-ghost"}}
  defp ghostify(other), do: other

  defp bump({:ok, %Task{} = task}), do: {:ok, %{task | revision: task.revision + 5}}
  defp bump(other), do: other

  defp mutation(options), do: Keyword.get(options, :mutation)
end

defmodule TamaMCP.Conformance.TestRaisingStore do
  @moduledoc false

  @behaviour TamaMCP.Task.Store

  alias TamaMCP.TestSupport.Tasks.Store

  @impl true
  def create(task, options), do: Store.create(task, options)

  @impl true
  def get(_owner_key, _task_id, _options), do: raise("adapter exploded")

  @impl true
  def transition(owner_key, task_id, revision, status, attributes, options),
    do: Store.transition(owner_key, task_id, revision, status, attributes, options)

  @impl true
  def update(owner_key, task_id, input_responses, options),
    do: Store.update(owner_key, task_id, input_responses, options)

  @impl true
  def cancel(owner_key, task_id, options), do: Store.cancel(owner_key, task_id, options)
end

defmodule TamaMCP.Conformance.TestConflictStore do
  @moduledoc false

  @behaviour TamaMCP.Task.Store

  alias TamaMCP.TestSupport.Tasks.Store

  @impl true
  def create(_task, _options), do: {:error, :conflict}

  @impl true
  def get(owner_key, task_id, options), do: Store.get(owner_key, task_id, options)

  @impl true
  def transition(owner_key, task_id, revision, status, attributes, options),
    do: Store.transition(owner_key, task_id, revision, status, attributes, options)

  @impl true
  def update(owner_key, task_id, input_responses, options),
    do: Store.update(owner_key, task_id, input_responses, options)

  @impl true
  def cancel(owner_key, task_id, options), do: Store.cancel(owner_key, task_id, options)
end

defmodule TamaMCP.Conformance.TestInvalidTransitionStore do
  @moduledoc false

  @behaviour TamaMCP.Task.Store

  alias TamaMCP.TestSupport.Tasks.Store

  @impl true
  def create(task, options), do: Store.create(task, options)

  @impl true
  def get(owner_key, task_id, options), do: Store.get(owner_key, task_id, options)

  @impl true
  def transition(_owner_key, _task_id, _revision, _status, _attributes, _options),
    do: {:error, :invalid_state}

  @impl true
  def update(owner_key, task_id, input_responses, options),
    do: Store.update(owner_key, task_id, input_responses, options)

  @impl true
  def cancel(owner_key, task_id, options), do: Store.cancel(owner_key, task_id, options)
end

defmodule TamaMCP.Conformance.TestFailingUpdateStore do
  @moduledoc false

  @behaviour TamaMCP.Task.Store

  alias TamaMCP.{Error, TestSupport}

  @impl true
  def create(task, options), do: TestSupport.Tasks.Store.create(task, options)

  @impl true
  def get(owner_key, task_id, options),
    do: TestSupport.Tasks.Store.get(owner_key, task_id, options)

  @impl true
  def transition(owner_key, task_id, revision, status, attributes, options),
    do:
      TestSupport.Tasks.Store.transition(
        owner_key,
        task_id,
        revision,
        status,
        attributes,
        options
      )

  @impl true
  def update(_owner_key, _task_id, _input_responses, _options),
    do: {:error, Error.internal()}

  @impl true
  def cancel(owner_key, task_id, options),
    do: TestSupport.Tasks.Store.cancel(owner_key, task_id, options)
end

defmodule TamaMCP.Conformance.TestRejectingCancelStore do
  @moduledoc false

  @behaviour TamaMCP.Task.Store

  alias TamaMCP.TestSupport.Tasks.Store

  @impl true
  def create(task, options), do: Store.create(task, options)

  @impl true
  def get(owner_key, task_id, options), do: Store.get(owner_key, task_id, options)

  @impl true
  def transition(owner_key, task_id, revision, status, attributes, options),
    do: Store.transition(owner_key, task_id, revision, status, attributes, options)

  @impl true
  def update(owner_key, task_id, input_responses, options),
    do: Store.update(owner_key, task_id, input_responses, options)

  @impl true
  def cancel(owner_key, task_id, options) do
    case Store.cancel(owner_key, task_id, options) do
      {:error, :not_found} -> {:error, :not_found}
      _other -> {:error, :conflict}
    end
  end
end

defmodule TamaMCP.Conformance.TestErrorLookupStore do
  @moduledoc false

  @behaviour TamaMCP.Task.Store

  alias TamaMCP.{Error, TestSupport}

  @impl true
  def create(task, options), do: TestSupport.Tasks.Store.create(task, options)

  @impl true
  def get(owner_key, task_id, options) do
    case TestSupport.Tasks.Store.get(owner_key, task_id, options) do
      {:error, :not_found} -> {:error, Error.internal()}
      other -> other
    end
  end

  @impl true
  def transition(owner_key, task_id, revision, status, attributes, options),
    do:
      TestSupport.Tasks.Store.transition(
        owner_key,
        task_id,
        revision,
        status,
        attributes,
        options
      )

  @impl true
  def update(owner_key, task_id, input_responses, options) do
    case TestSupport.Tasks.Store.update(owner_key, task_id, input_responses, options) do
      {:error, :not_found} -> {:error, Error.internal()}
      other -> other
    end
  end

  @impl true
  def cancel(owner_key, task_id, options) do
    case TestSupport.Tasks.Store.cancel(owner_key, task_id, options) do
      {:error, :not_found} -> {:error, Error.internal()}
      other -> other
    end
  end
end

defmodule TamaMCP.Conformance.AdapterHarnessTest do
  @moduledoc false

  use ExUnit.Case, async: false

  alias TamaMCP.Conformance
  alias TamaMCP.Conformance.Failure
  alias TamaMCP.Notification.Local
  alias TamaMCP.{Task, TestSupport}

  setup do
    store = TestSupport.Tasks.Store.start_link() |> elem(1)

    %{store: store, validation: [cache: TestSupport.Cache]}
  end

  test "the reference task store passes the store conformance harness",
       %{store: store, validation: validation} do
    :ok =
      Conformance.Store.check(TestSupport.Tasks.Store,
        adapter_options: [
          agent: store,
          tama_mcp: [task_validation_options: validation]
        ],
        task_factory: fn -> fresh_task() end,
        task_validation_options: validation,
        fresh_instance: fn -> [agent: store] end
      )
  end

  test "the local notification adapter passes the notification conformance harness" do
    local = Local.start_link([]) |> elem(1)

    :ok =
      Conformance.Notification.check(
        Local,
        adapter_options: [server: local],
        task_factory: fn -> fresh_task() end
      )
  end

  test "the strict revision check passes for an adapter that drops stale snapshots" do
    local = Local.start_link([]) |> elem(1)
    guard = Agent.start_link(fn -> %{} end) |> elem(1)

    :ok =
      Conformance.Notification.check(
        Conformance.TestStrictNotification,
        adapter_options: [server: local, strict_guard: guard],
        task_factory: fn -> fresh_task() end,
        strict_revisions: true
      )
  end

  test "the store harness identifies the violated callback and rule" do
    store = TestSupport.Tasks.Store.start_link() |> elem(1)

    assert_raise(Failure, ~r/get\/3.*created task/, fn ->
      Conformance.Store.check(Conformance.TestViolatingStore,
        adapter_options: [agent: store],
        task_factory: fn -> fresh_task() end,
        task_validation_options: [cache: TestSupport.Cache]
      )
    end)
  end

  test "the notification harness identifies the violated callback and rule" do
    local = Local.start_link([]) |> elem(1)

    assert_raise(Failure, ~r/take\/2/, fn ->
      Conformance.Notification.check(Conformance.TestMaliciousNotification,
        adapter_options: [server: local],
        task_factory: fn -> fresh_task() end
      )
    end)
  end

  test "host misconfiguration raises ArgumentError" do
    assert_raise(ArgumentError, ~r/task_factory/, fn ->
      Conformance.Store.check(TestSupport.Tasks.Store,
        adapter_options: [],
        task_validation_options: [cache: TestSupport.Cache]
      )
    end)
  end

  test "failure messages name the callback, rule, and bounded details" do
    failure =
      Failure.exception(
        callback: "cancel/3",
        rule: "terminal cancels must fail",
        details: String.duplicate("x", 2_000)
      )

    message = Exception.message(failure)
    assert message =~ "cancel/3"
    assert message =~ "terminal cancels must fail"
    assert byte_size(message) < 800
  end

  test "the store harness reports an adapter exception with the callback and rule" do
    store = TestSupport.Tasks.Store.start_link() |> elem(1)

    assert_raise(Failure, ~r/get\/?3.*must not raise/, fn ->
      Conformance.Store.check(Conformance.TestRaisingStore,
        adapter_options: [
          agent: store,
          tama_mcp: [task_validation_options: [cache: TestSupport.Cache]]
        ],
        task_factory: fn -> fresh_task() end,
        task_validation_options: [cache: TestSupport.Cache]
      )
    end)
  end

  test "the store harness reports a first-create conflict" do
    store = TestSupport.Tasks.Store.start_link() |> elem(1)

    assert_raise(Failure, ~r/create\/?2.*first create/, fn ->
      Conformance.Store.check(Conformance.TestConflictStore,
        adapter_options: [
          agent: store,
          tama_mcp: [task_validation_options: [cache: TestSupport.Cache]]
        ],
        task_factory: fn -> fresh_task() end,
        task_validation_options: [cache: TestSupport.Cache]
      )
    end)
  end

  test "the store harness reports an invalid transition result" do
    store = TestSupport.Tasks.Store.start_link() |> elem(1)

    assert_raise(Failure, ~r/transition\/6.*valid transition must succeed/, fn ->
      Conformance.Store.check(Conformance.TestInvalidTransitionStore,
        adapter_options: [
          agent: store,
          tama_mcp: [task_validation_options: [cache: TestSupport.Cache]]
        ],
        task_factory: fn -> fresh_task() end,
        task_validation_options: [cache: TestSupport.Cache]
      )
    end)
  end

  test "the store harness reports a failing input update" do
    store = TestSupport.Tasks.Store.start_link() |> elem(1)

    assert_raise(Failure, ~r/update\/?4.*partial input response/, fn ->
      Conformance.Store.check(Conformance.TestFailingUpdateStore,
        adapter_options: [
          agent: store,
          tama_mcp: [task_validation_options: [cache: TestSupport.Cache]]
        ],
        task_factory: fn -> fresh_task() end,
        task_validation_options: [cache: TestSupport.Cache]
      )
    end)
  end

  test "the store harness reports a failing cancellation" do
    store = TestSupport.Tasks.Store.start_link() |> elem(1)

    assert_raise(Failure, ~r/cancel\/?3.*non-terminal task must succeed/, fn ->
      Conformance.Store.check(Conformance.TestRejectingCancelStore,
        adapter_options: [
          agent: store,
          tama_mcp: [task_validation_options: [cache: TestSupport.Cache]]
        ],
        task_factory: fn -> fresh_task() end,
        task_validation_options: [cache: TestSupport.Cache]
      )
    end)
  end

  test "the store harness accepts bounded package errors for lookups" do
    store = TestSupport.Tasks.Store.start_link() |> elem(1)

    :ok =
      Conformance.Store.check(Conformance.TestErrorLookupStore,
        adapter_options: [
          agent: store,
          tama_mcp: [task_validation_options: [cache: TestSupport.Cache]]
        ],
        task_factory: fn -> fresh_task() end,
        task_validation_options: [cache: TestSupport.Cache]
      )
  end

  test "the notification harness reports a failing subscribe" do
    local = Local.start_link([]) |> elem(1)

    assert_raise(Failure, ~r/subscribe\/?4.*valid subscription/, fn ->
      Conformance.Notification.check(Conformance.TestFailingSubscribeNotification,
        adapter_options: [server: local],
        task_factory: fn -> fresh_task() end
      )
    end)
  end

  test "the notification harness reports a failing publish" do
    local = Local.start_link([]) |> elem(1)

    assert_raise(Failure, ~r/publish\/?2.*healthy adapter/, fn ->
      Conformance.Notification.check(Conformance.TestFailingPublishNotification,
        adapter_options: [server: local],
        task_factory: fn -> fresh_task() end
      )
    end)
  end

  test "failure details bound non-binary terms" do
    failure =
      Failure.exception(
        callback: "get/3",
        rule: "bounded details",
        details: %{"payload" => String.duplicate("y", 2_000)}
      )

    assert Exception.message(failure) |> byte_size() < 800
  end

  test "the store harness reports a throwing adapter" do
    store = TestSupport.Tasks.Store.start_link() |> elem(1)

    assert_raise(Failure, ~r/get\/?3.*must not raise/, fn ->
      Conformance.Store.check(Conformance.TestMutantStore,
        adapter_options: [
          agent: store,
          mutation: :throw_get,
          tama_mcp: [task_validation_options: [cache: TestSupport.Cache]]
        ],
        task_factory: fn -> fresh_task() end,
        task_validation_options: [cache: TestSupport.Cache]
      )
    end)
  end

  test "the store harness reports a malformed create result" do
    store = TestSupport.Tasks.Store.start_link() |> elem(1)

    assert_raise(Failure, ~r/create\/?2.*must return \{:ok, task\}/, fn ->
      Conformance.Store.check(Conformance.TestMutantStore,
        adapter_options: [
          agent: store,
          mutation: :ghost_create,
          tama_mcp: [task_validation_options: [cache: TestSupport.Cache]]
        ],
        task_factory: fn -> fresh_task() end,
        task_validation_options: [cache: TestSupport.Cache]
      )
    end)
  end

  test "the store harness reports a package-error create result" do
    store = TestSupport.Tasks.Store.start_link() |> elem(1)

    assert_raise(Failure, ~r/create\/?2.*first create/, fn ->
      Conformance.Store.check(Conformance.TestMutantStore,
        adapter_options: [
          agent: store,
          mutation: :error_create,
          tama_mcp: [task_validation_options: [cache: TestSupport.Cache]]
        ],
        task_factory: fn -> fresh_task() end,
        task_validation_options: [cache: TestSupport.Cache]
      )
    end)
  end

  test "the store harness reports a malformed get result" do
    store = TestSupport.Tasks.Store.start_link() |> elem(1)

    assert_raise(Failure, ~r/get\/?3.*immediately visible/, fn ->
      Conformance.Store.check(Conformance.TestMutantStore,
        adapter_options: [
          agent: store,
          mutation: :ghost_get,
          tama_mcp: [task_validation_options: [cache: TestSupport.Cache]]
        ],
        task_factory: fn -> fresh_task() end,
        task_validation_options: [cache: TestSupport.Cache]
      )
    end)
  end

  test "the store harness reports distinguishable missing and unauthorized gets" do
    store = TestSupport.Tasks.Store.start_link() |> elem(1)

    assert_raise(Failure, ~r/get\/?3.*indistinguishable/, fn ->
      Conformance.Store.check(Conformance.TestMutantStore,
        adapter_options: [
          agent: store,
          mutation: :distinguishable_get,
          tama_mcp: [task_validation_options: [cache: TestSupport.Cache]]
        ],
        task_factory: fn -> fresh_task() end,
        task_validation_options: [cache: TestSupport.Cache]
      )
    end)
  end

  test "the store harness reports a stale transition that is not a conflict" do
    store = TestSupport.Tasks.Store.start_link() |> elem(1)

    assert_raise(Failure, ~r/transition\/6.*stale revision/, fn ->
      Conformance.Store.check(Conformance.TestMutantStore,
        adapter_options: [
          agent: store,
          mutation: :stale_transition,
          tama_mcp: [task_validation_options: [cache: TestSupport.Cache]]
        ],
        task_factory: fn -> fresh_task() end,
        task_validation_options: [cache: TestSupport.Cache]
      )
    end)
  end

  test "the store harness reports a missing-task transition that succeeds" do
    store = TestSupport.Tasks.Store.start_link() |> elem(1)

    assert_raise(Failure, ~r/transition\/6.*missing task/, fn ->
      Conformance.Store.check(Conformance.TestMutantStore,
        adapter_options: [
          agent: store,
          mutation: :missing_transition,
          tama_mcp: [task_validation_options: [cache: TestSupport.Cache]]
        ],
        task_factory: fn -> fresh_task() end,
        task_validation_options: [cache: TestSupport.Cache]
      )
    end)
  end

  test "the store harness reports a snapshot that does not match the store" do
    store = TestSupport.Tasks.Store.start_link() |> elem(1)

    assert_raise(Failure, ~r/transition\/6.*returned snapshot/, fn ->
      Conformance.Store.check(Conformance.TestMutantStore,
        adapter_options: [
          agent: store,
          mutation: :frozen_transition,
          tama_mcp: [task_validation_options: [cache: TestSupport.Cache]]
        ],
        task_factory: fn -> fresh_task() end,
        task_validation_options: [cache: TestSupport.Cache]
      )
    end)
  end

  test "the store harness reports mangled transitions" do
    store = TestSupport.Tasks.Store.start_link() |> elem(1)

    assert_raise(Failure, ~r/transition\/6.*input requests/, fn ->
      Conformance.Store.check(Conformance.TestMutantStore,
        adapter_options: [
          agent: store,
          mutation: :mangle_transition,
          tama_mcp: [task_validation_options: [cache: TestSupport.Cache]]
        ],
        task_factory: fn -> fresh_task() end,
        task_validation_options: [cache: TestSupport.Cache]
      )
    end)
  end

  test "the store harness reports a failed exact terminal replay" do
    store = TestSupport.Tasks.Store.start_link() |> elem(1)

    assert_raise(Failure, ~r/transition\/6.*exact terminal replay/, fn ->
      Conformance.Store.check(Conformance.TestMutantStore,
        adapter_options: [
          agent: store,
          mutation: :replay_conflict,
          tama_mcp: [task_validation_options: [cache: TestSupport.Cache]]
        ],
        task_factory: fn -> fresh_task() end,
        task_validation_options: [cache: TestSupport.Cache]
      )
    end)
  end

  test "the store harness reports an advancing no-op update" do
    store = TestSupport.Tasks.Store.start_link() |> elem(1)

    assert_raise(Failure, ~r/update\/?4.*no-op update must not advance/, fn ->
      Conformance.Store.check(Conformance.TestMutantStore,
        adapter_options: [
          agent: store,
          mutation: :advancing_update,
          tama_mcp: [task_validation_options: [cache: TestSupport.Cache]]
        ],
        task_factory: fn -> fresh_task() end,
        task_validation_options: [cache: TestSupport.Cache]
      )
    end)
  end

  test "the store harness reports a cancel that makes the task terminal" do
    store = TestSupport.Tasks.Store.start_link() |> elem(1)

    assert_raise(Failure, ~r/cancel\/?3.*cancel intent must not make/, fn ->
      Conformance.Store.check(Conformance.TestMutantStore,
        adapter_options: [
          agent: store,
          mutation: :terminal_cancel,
          tama_mcp: [task_validation_options: [cache: TestSupport.Cache]]
        ],
        task_factory: fn -> fresh_task() end,
        task_validation_options: [cache: TestSupport.Cache]
      )
    end)
  end

  test "the store harness reports a fresh instance that loses the task" do
    store = TestSupport.Tasks.Store.start_link() |> elem(1)
    fresh = TestSupport.Tasks.Store.start_link() |> elem(1)

    assert_raise(Failure, ~r/get\/?3.*fresh adapter options/, fn ->
      Conformance.Store.check(Conformance.TestMutantStore,
        adapter_options: [
          agent: store,
          tama_mcp: [task_validation_options: [cache: TestSupport.Cache]]
        ],
        task_factory: fn -> fresh_task() end,
        task_validation_options: [cache: TestSupport.Cache],
        fresh_instance: fn -> [agent: fresh] end
      )
    end)
  end

  test "the store harness rejects host misconfiguration" do
    store = TestSupport.Tasks.Store.start_link() |> elem(1)
    validation = [cache: TestSupport.Cache]

    assert_raise(ArgumentError, ~r/:adapter_options/, fn ->
      Conformance.Store.check(Conformance.TestMutantStore,
        adapter_options: "not a keyword",
        task_factory: fn -> fresh_task() end,
        task_validation_options: validation
      )
    end)

    assert_raise(ArgumentError, ~r/:task_factory/, fn ->
      Conformance.Store.check(Conformance.TestMutantStore,
        adapter_options: [agent: store],
        task_factory: "not a function",
        task_validation_options: validation
      )
    end)

    assert_raise(ArgumentError, ~r/working status/, fn ->
      Conformance.Store.check(Conformance.TestMutantStore,
        adapter_options: [agent: store],
        task_factory: fn -> :not_a_task end,
        task_validation_options: validation
      )
    end)

    timestamp = ~U[2026-09-14 12:00:00Z]

    invalid =
      struct(Task, %{
        id: "conformance-invalid",
        owner_key: "conformance-owner",
        method: "tools/call",
        request_id: "conformance-request",
        status: :working,
        created_at: timestamp,
        last_updated_at: timestamp,
        ttl_ms: -1,
        client_capabilities: %{}
      })

    assert_raise(ArgumentError, ~r/Task\.validate/, fn ->
      Conformance.Store.check(Conformance.TestMutantStore,
        adapter_options: [agent: store],
        task_factory: fn -> invalid end,
        task_validation_options: validation
      )
    end)

    assert_raise(ArgumentError, ~r/:fresh_instance/, fn ->
      Conformance.Store.check(Conformance.TestMutantStore,
        adapter_options: [agent: store],
        task_factory: fn -> fresh_task() end,
        task_validation_options: validation,
        fresh_instance: :not_a_function
      )
    end)
  end

  test "the store harness rejects an invalid fresh-instance result" do
    store = TestSupport.Tasks.Store.start_link() |> elem(1)

    assert_raise(ArgumentError, ~r/fresh adapter options/, fn ->
      Conformance.Store.check(Conformance.TestMutantStore,
        adapter_options: [
          agent: store,
          tama_mcp: [task_validation_options: [cache: TestSupport.Cache]]
        ],
        task_factory: fn -> fresh_task() end,
        task_validation_options: [cache: TestSupport.Cache],
        fresh_instance: fn -> "not a keyword" end
      )
    end)
  end

  test "the notification harness reports a throwing adapter" do
    local = Local.start_link([]) |> elem(1)

    assert_raise(Failure, ~r/take\/?2.*must not raise/, fn ->
      Conformance.Notification.check(Conformance.TestMutantNotification,
        adapter_options: [server: local, mutation: :throw_take],
        task_factory: fn -> fresh_task() end
      )
    end)
  end

  test "the notification harness reports a raising adapter" do
    local = Local.start_link([]) |> elem(1)

    assert_raise(Failure, ~r/take\/?2.*must not raise/, fn ->
      Conformance.Notification.check(Conformance.TestMutantNotification,
        adapter_options: [server: local, mutation: :raise_take],
        task_factory: fn -> fresh_task() end
      )
    end)
  end

  test "the notification harness reports a malformed subscribe result" do
    local = Local.start_link([]) |> elem(1)

    assert_raise(Failure, ~r/subscribe\/?4.*must return \{:ok, subscription\}/, fn ->
      Conformance.Notification.check(Conformance.TestMutantNotification,
        adapter_options: [server: local, mutation: :bad_subscribe],
        task_factory: fn -> fresh_task() end
      )
    end)
  end

  test "the notification harness reports a snapshot for an unsubscribed task" do
    local = Local.start_link([]) |> elem(1)

    assert_raise(Failure, ~r/take\/?2.*unsubscribed task ID/, fn ->
      Conformance.Notification.check(Conformance.TestMutantNotification,
        adapter_options: [server: local, mutation: :ghost_take],
        task_factory: fn -> fresh_task() end
      )
    end)
  end

  test "the notification harness reports a snapshot that is not the committed one" do
    local = Local.start_link([]) |> elem(1)

    assert_raise(Failure, ~r/take\/?2.*complete committed snapshot/, fn ->
      Conformance.Notification.check(Conformance.TestMutantNotification,
        adapter_options: [server: local, mutation: :bump_take],
        task_factory: fn -> fresh_task() end
      )
    end)
  end

  test "the notification harness reports a failing unsubscribe" do
    local = Local.start_link([]) |> elem(1)

    assert_raise(Failure, ~r/unsubscribe\/?2.*idempotent unsubscribe/, fn ->
      Conformance.Notification.check(Conformance.TestMutantNotification,
        adapter_options: [server: local, mutation: :fail_unsubscribe],
        task_factory: fn -> fresh_task() end
      )
    end)
  end

  test "the notification harness reports a publish that never sends ready" do
    local = Local.start_link([]) |> elem(1)

    assert_raise(Failure, ~r/publish\/?2.*ready hint/, fn ->
      Conformance.Notification.check(Conformance.TestMutantNotification,
        adapter_options: [server: local, mutation: :silent_publish],
        task_factory: fn -> fresh_task() end
      )
    end)
  end

  test "the notification harness rejects host misconfiguration" do
    local = Local.start_link([]) |> elem(1)

    assert_raise(ArgumentError, ~r/:adapter_options/, fn ->
      Conformance.Notification.check(Conformance.TestMutantNotification,
        adapter_options: "not a keyword",
        task_factory: fn -> fresh_task() end
      )
    end)

    assert_raise(ArgumentError, ~r/:task_factory/, fn ->
      Conformance.Notification.check(Conformance.TestMutantNotification,
        adapter_options: [server: local],
        task_factory: "not a function"
      )
    end)

    assert_raise(ArgumentError, ~r/:setup/, fn ->
      Conformance.Notification.check(Conformance.TestMutantNotification,
        adapter_options: [server: local],
        task_factory: fn -> fresh_task() end,
        setup: "not a function"
      )
    end)

    assert_raise(ArgumentError, ~r/working status/, fn ->
      Conformance.Notification.check(Conformance.TestMutantNotification,
        adapter_options: [server: local],
        task_factory: fn -> :not_a_task end
      )
    end)
  end

  test "the notification harness reports stale snapshots for strict adapters" do
    local = Local.start_link([]) |> elem(1)

    assert_raise(Failure, ~r/publish\/?2.*older revision must be ignored/, fn ->
      Conformance.Notification.check(
        Local,
        adapter_options: [server: local],
        task_factory: fn -> fresh_task() end,
        strict_revisions: true
      )
    end)
  end

  defp fresh_task do
    {:ok, task} =
      Task.new(
        %{
          id: "conformance-#{System.unique_integer([:positive])}",
          owner_key: "conformance-owner",
          method: "tools/call",
          request_id: "conformance-request",
          created_at: ~U[2026-09-14 12:00:00Z],
          last_updated_at: ~U[2026-09-14 12:00:00Z],
          ttl_ms: 60_000,
          client_capabilities: %{"elicitation" => %{"form" => %{}}}
        },
        cache: TestSupport.Cache
      )

    task
  end
end
