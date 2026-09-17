defmodule TamaMCP.Transport.StreamableHTTP.Subscriptions do
  @moduledoc false

  import Plug.Conn

  alias TamaMCP.{Authorization, Error, Notification, Protocol, Task}
  alias TamaMCP.Authorization.Decision
  alias TamaMCP.Schema.Protocol, as: ProtocolSchema
  alias TamaMCP.Schema.Tasks, as: TaskSchema
  alias TamaMCP.Transport.StreamableHTTP.{Events, Result, Runtime, Wire}

  @tasks_capability Protocol.tasks_extension()
  @subscription_key Protocol.meta_key(:subscription_id)
  @maximum_receive_timeout 4_294_967_295

  def call(conn, request, decision, %Runtime{} = runtime, base) do
    base = Map.merge(base, %{method: request.method})
    notifications = request.params["notifications"]
    requested = Map.get(notifications, "taskIds", [])

    result =
      with :ok <- validate_request(request, decision, requested, runtime),
           {:ok, task_ids} <- authorized_task_ids(requested, decision.owner_key, runtime) do
        start_stream(conn, request, decision, task_ids, runtime, base)
      end

    respond(result, conn, request, runtime, base)
  end

  defp respond({%Plug.Conn{} = conn, meta}, _original, _request, _runtime, _base),
    do: {conn, meta}

  defp respond({:error, %Error{} = error, status, authenticate}, conn, request, runtime, base) do
    Wire.error(
      conn,
      request.request_id,
      error,
      Map.merge(base, %{status: :rejected, reason: Error.reason(error)}),
      runtime,
      status: status,
      authenticate: authenticate
    )
  end

  defp respond({:error, %Error{} = error}, conn, request, runtime, base) do
    Wire.error(
      conn,
      request.request_id,
      error,
      Map.merge(base, %{status: :error, reason: Error.reason(error)}),
      runtime
    )
  end

  defp respond({:error, reason}, conn, request, runtime, base) do
    Wire.error(
      conn,
      request.request_id,
      Error.internal(),
      Map.merge(base, %{status: :error, reason: reason}),
      runtime
    )
  end

  defp start_stream(conn, request, decision, task_ids, runtime, base) do
    case subscribe(task_ids, runtime) do
      {:ok, subscription} ->
        register_and_stream(conn, request, decision, task_ids, subscription, runtime, base)

      error ->
        error
    end
  end

  defp register_and_stream(conn, request, decision, task_ids, subscription, runtime, base) do
    case register_invalidation(decision, runtime) do
      {:ok, invalidation} ->
        result =
          open_stream(
            conn,
            request,
            decision,
            task_ids,
            subscription,
            invalidation,
            runtime,
            base
          )

        cleanup(subscription, invalidation, runtime)
        result

      error ->
        cleanup(subscription, nil, runtime)
        error
    end
  end

  defp open_stream(
         conn,
         request,
         decision,
         task_ids,
         subscription,
         invalidation,
         runtime,
         base
       ) do
    acknowledgement_result =
      acknowledgement(request.request_id, request.params["notifications"], task_ids, runtime)

    with {:ok, acknowledgement} <- acknowledgement_result,
         {:ok, decision} <-
           reauthorize_before_open(conn, decision, task_ids, invalidation, runtime) do
      case open(conn, acknowledgement) do
        {:ok, conn} ->
          state =
            stream_state(
              conn,
              request,
              decision,
              task_ids,
              subscription,
              invalidation,
              runtime
            )

          Events.emit(runtime, [:subscription, :open], %{}, Map.put(base, :status, :ok))

          Events.emit(
            runtime,
            [:subscription, :acknowledgement],
            %{},
            Map.put(base, :status, :ok)
          )

          finish_stream(loop(state), runtime, base)

        {:transport_closed, conn} ->
          finish_stream({conn, :transport_closed}, runtime, base)

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp finish_stream({conn, reason}, runtime, base) do
    status = if reason in [:maximum_lifetime, :credential_expired], do: :closed, else: reason
    meta = Map.merge(base, %{status: status, reason: reason})
    Events.emit(runtime, [:subscription, :close], %{}, meta)
    {conn, meta}
  end

  defp validate_request(request, decision, requested, runtime) do
    with :ok <- validate_task_ids(requested, runtime),
         :ok <- validate_task_subscription(request, decision, requested, runtime) do
      validate_credential(decision)
    end
  end

  defp validate_task_ids(requested, runtime) when is_list(requested) do
    if length(requested) <= runtime.limits.max_task_ids_per_subscription,
      do: :ok,
      else:
        {:error,
         Error.invalid_params("notifications.taskIds exceeds max_task_ids_per_subscription")}
  end

  defp validate_task_ids(_requested, _runtime),
    do: {:error, Error.invalid_params("notifications.taskIds must be an array")}

  defp validate_task_subscription(_request, _decision, [], _runtime), do: :ok

  defp validate_task_subscription(request, decision, _requested, runtime) do
    cond do
      not tasks_declared?(request.client_capabilities) ->
        {:error, missing_capability()}

      not Runtime.task_capable?(runtime) ->
        {:error, Error.method_not_found(request.method)}

      is_nil(decision.owner_key) ->
        {:error, :missing_owner_key}

      true ->
        :ok
    end
  end

  defp validate_credential(decision) do
    if expired?(decision),
      do: {:error, Error.invalid_request("Credential has expired"), 401, :credential},
      else: :ok
  end

  defp authorized_task_ids(_requested, _owner_key, %Runtime{notification: nil}),
    do: {:ok, []}

  defp authorized_task_ids(requested, owner_key, runtime) do
    requested
    |> Enum.uniq()
    |> Enum.reduce_while({:ok, []}, fn task_id, {:ok, authorized} ->
      case fetch_task(owner_key, task_id, runtime) do
        {:ok, _task} -> {:cont, {:ok, [task_id | authorized]}}
        {:error, :not_found} -> {:cont, {:ok, authorized}}
        {:error, %Error{} = error} -> {:halt, {:error, error}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, authorized} -> {:ok, Enum.reverse(authorized)}
      error -> error
    end
  end

  defp subscribe([], _runtime), do: {:ok, nil}

  defp subscribe(task_ids, runtime) do
    adapter(runtime, :subscribe, [
      task_ids,
      self(),
      runtime.limits.notification_buffer_capacity,
      runtime.notification_options
    ])
    |> case do
      {:ok, subscription} when not is_nil(subscription) -> {:ok, subscription}
      {:error, %Error{} = error} -> {:error, error}
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _invalid -> {:error, :invalid_notification_return}
    end
  end

  defp register_invalidation(decision, runtime) do
    authorization(runtime, :register_invalidation, [
      decision,
      self(),
      runtime.authorization_options
    ])
    |> case do
      :unsupported -> {:ok, nil}
      {:ok, reference} -> {:ok, reference}
      {:error, %Error{} = error} -> {:error, error}
      _invalid -> {:error, :invalid_authorization_return}
    end
  end

  defp open(conn, acknowledgement) do
    conn =
      conn
      |> put_resp_content_type("text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> send_chunked(200)

    case chunk_event(conn, acknowledgement) do
      {:ok, conn} -> {:ok, conn}
      {:error, _reason} -> {:transport_closed, conn}
    end
  rescue
    _exception -> {:error, :stream_open_failed}
  catch
    _kind, _reason -> {:error, :stream_open_failed}
  end

  defp stream_state(conn, request, decision, task_ids, subscription, invalidation, runtime) do
    now = now_ms()

    %{
      conn: conn,
      request: request,
      decision: decision,
      owner_key: decision.owner_key,
      task_ids: task_ids,
      subscription: subscription,
      invalidation: invalidation,
      runtime: runtime,
      maximum_deadline: now + runtime.limits.stream_max_lifetime_ms,
      expiry_deadline: expiry_deadline(decision, now),
      recheck_deadline: now + runtime.limits.stream_authorization_recheck_ms,
      keepalive_deadline: now + runtime.limits.stream_keepalive_interval_ms
    }
  end

  defp loop(state) do
    case due(state) do
      :maximum_lifetime -> graceful_close(state, :maximum_lifetime)
      :credential_expired -> graceful_close(state, :credential_expired)
      :reauthorize -> recheck_and_continue(state)
      :keepalive -> keepalive_and_continue(state)
      {:wait, timeout} -> receive_event(state, timeout)
    end
  end

  defp receive_event(state, timeout) do
    subscription = state.subscription
    invalidation = state.invalidation

    receive do
      {Notification, ^subscription, :ready} when not is_nil(subscription) ->
        deliver(state)

      {Notification, ^subscription, :overflow} when not is_nil(subscription) ->
        Events.emit(
          state.runtime,
          [:subscription, :overflow],
          %{},
          stream_meta(state, :overflow)
        )

        graceful_close(state, :overflow)

      {Authorization, ^invalidation, :invalidated} when not is_nil(invalidation) ->
        recheck_and_continue(state)
    after
      timeout -> loop(state)
    end
  end

  defp deliver(state) do
    case adapter(state.runtime, :take, [state.subscription, state.runtime.notification_options]) do
      {:ok, %Task{id: task_id}} ->
        deliver_task(state, task_id)

      :empty ->
        loop(state)

      {:error, :overflow} ->
        Events.emit(
          state.runtime,
          [:subscription, :overflow],
          %{},
          stream_meta(state, :overflow)
        )

        graceful_close(state, :overflow)

      {:error, reason} ->
        delivery_failure(state, close_reason(reason))

      _invalid ->
        delivery_failure(state, :invalid_notification_return)
    end
  end

  defp deliver_task(state, task_id) do
    if task_id in state.task_ids,
      do: deliver_authorized_task(state, task_id),
      else: delivery_failure(state, :invalid_notification)
  end

  defp deliver_authorized_task(state, task_id) do
    with {:ok, state, tasks} <- reauthorize(state),
         {:ok, task} <- Map.fetch(tasks, task_id),
         {:ok, notification} <- task_notification(task, state.request.request_id, state.runtime),
         :ok <- validate_delivery_boundaries(state),
         {:ok, conn} <- chunk_event(state.conn, notification) do
      loop(%{state | conn: conn})
    else
      {:reauthorize, :authorization_invalidated} ->
        deliver_authorized_task(state, task_id)

      {:error, reason} when reason in [:maximum_lifetime, :credential_expired] ->
        graceful_close(state, reason)

      {:error, reason} ->
        delivery_failure(state, close_reason(reason))

      :error ->
        delivery_failure(state, :task_not_authorized)
    end
  end

  defp recheck_and_continue(state) do
    case reauthorize(state) do
      {:ok, state, _tasks} -> loop(state)
      {:error, reason} -> graceful_close(state, close_reason(reason))
    end
  end

  defp reauthorize_before_open(conn, previous, task_ids, invalidation, runtime) do
    case reauthorize_visible_before_open(conn, previous, task_ids, runtime) do
      {:ok, decision} ->
        case take_pending_invalidation(invalidation) do
          :clear -> {:ok, decision}
          :invalidated -> reauthorize_before_open(conn, decision, task_ids, invalidation, runtime)
        end

      error ->
        error
    end
  end

  defp reauthorize_visible_before_open(conn, previous, task_ids, runtime) do
    with {:ok, %Decision{} = decision} <-
           reauthorize_credential(conn, previous, runtime),
         true <- Decision.valid?(decision),
         true <- decision.owner_key === previous.owner_key,
         :ok <- validate_credential(decision),
         {:ok, _tasks} <- visible_tasks(task_ids, decision.owner_key, runtime),
         :ok <- validate_credential(decision) do
      {:ok, decision}
    else
      {:error, %Error{} = error} ->
        {:error, error}

      {:error, %Error{} = error, status, authenticate} ->
        {:error, error, status, authenticate}

      {:error, reason} ->
        {:error, reason}

      _denied ->
        {:error, :authorization_rejected}
    end
  end

  defp reauthorize_credential(conn, previous, runtime) do
    case authorization(runtime, :reauthorize, [
           conn,
           previous,
           runtime.authorization_options
         ]) do
      {:error, %Error{} = error} -> {:error, error, 401, :credential}
      result -> result
    end
  end

  defp reauthorize(state) do
    runtime = state.runtime

    with {:ok, %Decision{} = decision} <-
           authorization(runtime, :reauthorize, [
             state.conn,
             state.decision,
             runtime.authorization_options
           ]),
         true <- Decision.valid?(decision),
         false <- expired?(decision),
         true <- decision.owner_key === state.owner_key,
         {:ok, tasks} <- visible_tasks(state.task_ids, decision.owner_key, runtime),
         false <- expired?(decision) do
      now = now_ms()

      {:ok,
       %{
         state
         | decision: decision,
           expiry_deadline: expiry_deadline(decision, now),
           recheck_deadline: now + runtime.limits.stream_authorization_recheck_ms
       }, tasks}
    else
      {:error, %Error{} = error} -> {:error, error}
      {:error, reason} -> {:error, reason}
      _denied -> {:error, :authorization_rejected}
    end
  end

  defp visible_tasks(task_ids, owner_key, runtime) do
    Enum.reduce_while(task_ids, {:ok, %{}}, fn task_id, {:ok, tasks} ->
      case fetch_task(owner_key, task_id, runtime) do
        {:ok, task} -> {:cont, {:ok, Map.put(tasks, task_id, task)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp fetch_task(owner_key, task_id, runtime) do
    store_options = Runtime.effective_task_store_options(runtime)

    case safe_apply(runtime.task_store, :get, [owner_key, task_id, store_options]) do
      {:ok, %Task{} = task} ->
        if task.owner_key === owner_key and task.id === task_id and
             Task.validate(task, Runtime.task_validation_options(runtime)) == :ok,
           do: {:ok, task},
           else: {:error, :invalid_task}

      {:error, :not_found} ->
        {:error, :not_found}

      {:error, %Error{} = error} ->
        {:error, error}

      _invalid ->
        {:error, :invalid_task_store_return}
    end
  end

  defp keepalive_and_continue(state) do
    case Plug.Conn.chunk(state.conn, ": keepalive\n\n") do
      {:ok, conn} ->
        deadline = now_ms() + state.runtime.limits.stream_keepalive_interval_ms
        loop(%{state | conn: conn, keepalive_deadline: deadline})

      {:error, _reason} ->
        {state.conn, :transport_closed}
    end
  rescue
    _exception -> {state.conn, :transport_closed}
  catch
    _kind, _reason -> {state.conn, :transport_closed}
  end

  defp delivery_failure(state, reason) do
    Events.emit(
      state.runtime,
      [:notification, :delivery_failure],
      %{},
      stream_meta(state, reason)
    )

    graceful_close(state, reason)
  end

  defp graceful_close(state, reason) do
    case closing_response(state.request.request_id, state.runtime) do
      {:ok, response} ->
        case chunk_event(state.conn, response) do
          {:ok, conn} -> {conn, reason}
          {:error, _chunk_reason} -> {state.conn, :transport_closed}
        end

      {:error, _validation_reason} ->
        {state.conn, :invalid_close_response}
    end
  end

  defp acknowledgement(subscription_id, requested, task_ids, runtime) do
    notifications = acknowledged_notifications(requested, task_ids)

    value = %{
      "jsonrpc" => "2.0",
      "method" => Protocol.notification(:subscriptions_acknowledged),
      "params" => %{
        "_meta" => %{@subscription_key => subscription_id},
        "notifications" => notifications
      }
    }

    acknowledgement_validation =
      validate(ProtocolSchema, :subscriptions_acknowledged_notification, value, runtime)

    with :ok <- acknowledgement_validation,
         :ok <-
           validate(
             TaskSchema,
             :task_subscription_acknowledged_notifications,
             notifications,
             runtime
           ),
         :ok <- validate_size(value, runtime) do
      {:ok, value}
    end
  end

  defp acknowledged_notifications(requested, task_ids) do
    if Map.has_key?(requested, "taskIds"), do: %{"taskIds" => task_ids}, else: %{}
  end

  defp task_notification(task, subscription_id, runtime) do
    params =
      task
      |> Task.get_result(runtime.limits.max_error_data_bytes)
      |> Map.delete("resultType")
      |> Map.put("_meta", %{@subscription_key => subscription_id})

    value = %{
      "jsonrpc" => "2.0",
      "method" => Protocol.notification(:tasks),
      "params" => params
    }

    with :ok <- validate(TaskSchema, :task_status_notification_params, params, runtime),
         :ok <- validate(TaskSchema, :task_status_notification, value, runtime),
         :ok <- validate_size(value, runtime) do
      {:ok, value}
    end
  end

  defp closing_response(subscription_id, runtime) do
    result =
      %{
        "resultType" => Protocol.result_type(:complete),
        "_meta" => %{@subscription_key => subscription_id}
      }
      |> Wire.merge_meta(Result.metadata(runtime.server))

    response = %{"jsonrpc" => "2.0", "id" => subscription_id, "result" => result}

    with :ok <- validate(ProtocolSchema, :subscriptions_listen_result, result, runtime),
         :ok <- validate(ProtocolSchema, :subscriptions_listen_response, response, runtime),
         :ok <- validate_size(response, runtime) do
      {:ok, response}
    end
  end

  defp validate(schema, kind, value, runtime) do
    case schema.validate(kind, value, runtime.cache, runtime.cache_options) do
      :ok -> :ok
      {:error, _details} -> {:error, :invalid_protocol_value}
    end
  rescue
    _exception -> {:error, :invalid_protocol_value}
  catch
    _kind, _reason -> {:error, :invalid_protocol_value}
  end

  defp validate_size(value, runtime) do
    case Jason.encode(value) do
      {:ok, encoded} when byte_size(encoded) <= runtime.limits.max_result_bytes -> :ok
      {:ok, _encoded} -> {:error, :result_too_large}
      {:error, _reason} -> {:error, :invalid_result}
    end
  end

  defp chunk_event(conn, value) do
    Plug.Conn.chunk(conn, ["data: ", Jason.encode!(value), "\n\n"])
  rescue
    _exception -> {:error, :closed}
  catch
    _kind, _reason -> {:error, :closed}
  end

  defp validate_delivery_boundaries(state) do
    case take_pending_invalidation(state.invalidation) do
      :clear ->
        validate_delivery_deadlines(state)

      :invalidated ->
        with :ok <- validate_delivery_deadlines(state),
             do: {:reauthorize, :authorization_invalidated}
    end
  end

  defp validate_delivery_deadlines(state) do
    now = now_ms()

    cond do
      now >= state.maximum_deadline ->
        {:error, :maximum_lifetime}

      not is_nil(state.expiry_deadline) and now >= state.expiry_deadline ->
        {:error, :credential_expired}

      true ->
        :ok
    end
  end

  defp take_pending_invalidation(nil), do: :clear

  defp take_pending_invalidation(invalidation) do
    receive do
      {Authorization, ^invalidation, :invalidated} -> :invalidated
    after
      0 -> :clear
    end
  end

  defp due(state) do
    now = now_ms()

    cond do
      now >= state.maximum_deadline -> :maximum_lifetime
      not is_nil(state.expiry_deadline) and now >= state.expiry_deadline -> :credential_expired
      now >= state.recheck_deadline -> :reauthorize
      now >= state.keepalive_deadline -> :keepalive
      true -> {:wait, wait_timeout(state, now)}
    end
  end

  defp wait_timeout(state, now) do
    deadlines =
      [
        state.maximum_deadline,
        state.expiry_deadline,
        state.recheck_deadline,
        state.keepalive_deadline
      ]
      |> Enum.reject(&is_nil/1)

    deadlines
    |> Enum.min()
    |> Kernel.-(now)
    |> max(0)
    |> min(@maximum_receive_timeout)
  end

  defp expiry_deadline(%Decision{expires_at: nil}, _now), do: nil

  defp expiry_deadline(%Decision{expires_at: expires_at}, now) do
    remaining = max(DateTime.diff(expires_at, DateTime.utc_now(), :millisecond), 0)
    now + remaining
  end

  defp expired?(%Decision{expires_at: nil}), do: false

  defp expired?(%Decision{expires_at: expires_at}) do
    DateTime.compare(expires_at, DateTime.utc_now()) != :gt
  end

  defp cleanup(subscription, invalidation, runtime) do
    if not is_nil(subscription),
      do: adapter(runtime, :unsubscribe, [subscription, runtime.notification_options])

    flush_notification_signals(subscription)

    if not is_nil(invalidation),
      do:
        authorization(runtime, :unregister_invalidation, [
          invalidation,
          runtime.authorization_options
        ])

    flush_authorization_signals(invalidation)

    :ok
  end

  defp flush_notification_signals(nil), do: :ok

  defp flush_notification_signals(subscription) do
    receive do
      {Notification, ^subscription, signal} when signal in [:ready, :overflow] ->
        flush_notification_signals(subscription)
    after
      0 -> :ok
    end
  end

  defp flush_authorization_signals(nil), do: :ok

  defp flush_authorization_signals(invalidation) do
    receive do
      {Authorization, ^invalidation, :invalidated} ->
        flush_authorization_signals(invalidation)
    after
      0 -> :ok
    end
  end

  defp adapter(runtime, function, arguments),
    do: safe_apply(runtime.notification, function, arguments)

  defp authorization(runtime, function, arguments) do
    if function_exported?(runtime.authorization, function, length(arguments)) do
      safe_apply(runtime.authorization, function, arguments)
    else
      authorization_fallback(runtime, function, arguments)
    end
  end

  defp authorization_fallback(runtime, :reauthorize, [conn, _decision, options]),
    do: safe_apply(runtime.authorization, :authenticate, [conn, options])

  defp authorization_fallback(_runtime, :register_invalidation, _arguments), do: :unsupported
  defp authorization_fallback(_runtime, :unregister_invalidation, _arguments), do: :ok

  defp safe_apply(module, function, arguments) when is_atom(module) do
    apply(module, function, arguments)
  rescue
    _exception -> {:error, :adapter_exception}
  catch
    _kind, _reason -> {:error, :adapter_exception}
  end

  defp tasks_declared?(capabilities) do
    get_in(capabilities, ["extensions", @tasks_capability]) |> is_map()
  end

  defp missing_capability do
    Error.missing_required_client_capability(%{
      "extensions" => %{@tasks_capability => %{}}
    })
  end

  defp close_reason(%Error{}), do: :authorization_rejected
  defp close_reason(reason) when is_atom(reason), do: reason
  defp close_reason(_reason), do: :stream_error

  defp stream_meta(state, reason) do
    %{
      server: state.runtime.server.name(),
      method: state.request.method,
      status: :error,
      reason: reason
    }
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
