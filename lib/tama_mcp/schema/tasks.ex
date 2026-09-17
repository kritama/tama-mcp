defmodule TamaMCP.Schema.Tasks do
  @moduledoc false

  alias TamaMCP.Cache.Validator
  alias TamaMCP.Schema

  @schema_path "protocol/2026-07-28/tasks/schema/2026-07-28/schema.json"
  @definitions %{
    cancel_task_request: "CancelTaskRequest",
    cancel_task_result: "CancelTaskResult",
    cancelled_task: "CancelledTask",
    completed_task: "CompletedTask",
    create_task_result: "CreateTaskResult",
    detailed_task: "DetailedTask",
    error: "Error",
    failed_task: "FailedTask",
    get_task_request: "GetTaskRequest",
    get_task_result: "GetTaskResult",
    input_requests: "InputRequests",
    input_required_task: "InputRequiredTask",
    task_status_notification: "TaskStatusNotification",
    task_status_notification_params: "TaskStatusNotificationParams",
    task_subscription_acknowledged_notifications: "TaskSubscriptionAcknowledgedNotifications",
    task_subscription_notifications: "TaskSubscriptionNotifications",
    update_task_request: "UpdateTaskRequest",
    update_task_result: "UpdateTaskResult",
    working_task: "WorkingTask"
  }

  @schema_file Path.expand("../../../priv/#{@schema_path}", __DIR__)
  @external_resource @schema_file
  @schema @schema_file |> File.read!() |> Jason.decode!()

  @validators Map.new(Enum.sort(@definitions), fn {kind, definition} ->
                root = %{
                  "$schema" => @schema["$schema"],
                  "$defs" => @schema["$defs"],
                  "$ref" => "#/$defs/#{definition}"
                }

                case Schema.compile(root) do
                  {:ok, compiled} -> {kind, Validator.artifact(__MODULE__, kind, compiled)}
                  {:error, reason} -> raise Schema.Error, message: reason
                end
              end)

  @type kind ::
          :cancel_task_request
          | :cancel_task_result
          | :cancelled_task
          | :completed_task
          | :create_task_result
          | :detailed_task
          | :error
          | :failed_task
          | :get_task_request
          | :get_task_result
          | :input_requests
          | :input_required_task
          | :task_status_notification
          | :task_status_notification_params
          | :task_subscription_acknowledged_notifications
          | :task_subscription_notifications
          | :update_task_request
          | :update_task_result
          | :working_task

  @spec validate(kind(), term(), module(), keyword()) :: :ok | {:error, [String.t()]}
  def validate(kind, value, cache, cache_options \\ []) when is_map_key(@definitions, kind) do
    artifact = Map.fetch!(@validators, kind)
    Schema.validate(Validator.fetch(artifact, cache, cache_options), value)
  end
end
