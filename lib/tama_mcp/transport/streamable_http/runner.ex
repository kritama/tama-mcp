defmodule TamaMCP.Transport.StreamableHTTP.Runner do
  @moduledoc false

  @spec run(module(), map(), TamaMCP.Context.t(), pos_integer()) ::
          {:ok, term()} | {:error, :timeout | :tool_exception}
  def run(module, arguments, context, timeout) do
    caller = self()
    tag = make_ref()

    {manager, monitor} =
      spawn_monitor(fn -> manage(caller, tag, module, arguments, context, timeout) end)

    receive do
      {^tag, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^manager, _reason} ->
        {:error, :tool_exception}
    end
  end

  defp manage(caller, tag, module, arguments, context, timeout) do
    Process.flag(:trap_exit, true)
    caller_monitor = Process.monitor(caller)
    manager = self()

    worker =
      spawn_link(fn ->
        send(manager, {tag, execute(module, arguments, context)})
      end)

    timer = Process.send_after(self(), {tag, :timeout}, timeout)
    await(caller, caller_monitor, worker, timer, tag)
  end

  defp await(caller, caller_monitor, worker, timer, tag) do
    receive do
      {^tag, {:result, result}} ->
        cancel(timer)
        await_exit(worker)
        Process.demonitor(caller_monitor, [:flush])
        send(caller, {tag, {:ok, result}})

      {^tag, :failure} ->
        cancel(timer)
        await_exit(worker)
        Process.demonitor(caller_monitor, [:flush])
        send(caller, {tag, {:error, :tool_exception}})

      {:EXIT, ^worker, _reason} ->
        cancel(timer)
        Process.demonitor(caller_monitor, [:flush])
        send(caller, {tag, {:error, :tool_exception}})

      {:DOWN, ^caller_monitor, :process, ^caller, _reason} ->
        cancel(timer)
        stop(worker)

      {^tag, :timeout} ->
        Process.demonitor(caller_monitor, [:flush])
        stop(worker)
        send(caller, {tag, {:error, :timeout}})
    end
  end

  defp execute(module, arguments, context) do
    {:result, module.call(arguments, context)}
  rescue
    _exception -> :failure
  catch
    _kind, _reason -> :failure
  end

  defp cancel(timer), do: Process.cancel_timer(timer, async: false, info: false)

  defp stop(worker) do
    Process.exit(worker, :kill)
    await_exit(worker)
  end

  defp await_exit(worker) do
    receive do
      {:EXIT, ^worker, _reason} -> :ok
    end
  end
end
