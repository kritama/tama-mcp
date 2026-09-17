defmodule TamaMCP.Transport.StreamableHTTP.Runtime.Validation do
  @moduledoc false

  alias TamaMCP.Authorization.Challenge
  alias TamaMCP.Transport.StreamableHTTP.{Result, Runtime, Wire}

  @min_www_authenticate_bytes Challenge.minimum_size()
  @maximum_protocol_integer 9_007_199_254_740_991

  def options!(opts, allowed) do
    unless Keyword.keyword?(opts) do
      raise ArgumentError, "options must be a keyword list, got: #{inspect(opts)}"
    end

    keys = Keyword.keys(opts)
    reject_unknown!(keys, allowed, "option(s)", "supported: #{inspect(Enum.sort(allowed))}")
    reject_duplicates!(keys, "option(s)")
  end

  def module!(opts, key) do
    case Keyword.fetch!(opts, key) do
      value when is_atom(value) and not is_nil(value) -> value
      other -> raise ArgumentError, "#{key}: expected a compiled module, got: #{inspect(other)}"
    end
  end

  def optional_module!(opts, key, default \\ nil) do
    case Keyword.get(opts, key, default) do
      nil -> nil
      value when is_atom(value) -> value
      other -> raise ArgumentError, "#{key}: expected a compiled module, got: #{inspect(other)}"
    end
  end

  def server!(server) do
    unless exports?(server, tools: 0, name: 0, version: 0, tool: 1, instructions: 0) do
      raise ArgumentError,
            "server: #{inspect(server)} is not a compiled TamaMCP server " <>
              "(define it with `use TamaMCP.Server`)"
    end
  end

  def authorization!(authorization) do
    unless exports?(authorization, authenticate: 2) do
      raise ArgumentError,
            "authorization: #{inspect(authorization)} does not implement " <>
              "TamaMCP.Authorization (missing authenticate/2)"
    end
  end

  def cache!(cache) do
    unless exports?(cache, fetch: 3) do
      raise ArgumentError,
            "cache: #{inspect(cache)} does not implement TamaMCP.Cache (missing fetch/3)"
    end
  end

  def task_selector!(nil), do: fn _module, _input, _context -> :sync end
  def task_selector!(selector) when is_function(selector, 3), do: selector

  def task_selector!({module, function}) when is_atom(module) and is_atom(function) do
    if exports?(module, [{function, 3}]) do
      &apply(module, function, [&1, &2, &3])
    else
      raise ArgumentError,
            "task_selector: #{inspect(module)}.#{inspect(function)}/3 is not exported"
    end
  end

  def task_selector!(other) do
    raise ArgumentError,
          "task_selector must be a 3-arity function or {module, function}, got: #{inspect(other)}"
  end

  def keyword!(value, label) do
    unless Keyword.keyword?(value) do
      raise ArgumentError, "#{label} must be a keyword list, got: #{inspect(value)}"
    end

    value
  end

  def telemetry!(value) do
    unless is_list(value) and value != [] and Enum.all?(value, &is_atom/1) do
      raise ArgumentError,
            "telemetry_prefix must be a non-empty list of atoms, got: #{inspect(value)}"
    end

    value
  end

  def metadata!(nil), do: nil
  def metadata!(fun) when is_function(fun, 2), do: fun

  def metadata!({module, function}) when is_atom(module) and is_atom(function) do
    if exports?(module, [{function, 2}]) do
      &apply(module, function, [&1, &2])
    else
      raise ArgumentError,
            "safe_metadata: #{inspect(module)}.#{inspect(function)}/2 is not an exported function"
    end
  end

  def metadata!(other) do
    raise ArgumentError,
          "safe_metadata must be a 2-arity function or {module, function}, got: #{inspect(other)}"
  end

  def headers!(headers) do
    valid? =
      is_list(headers) and Enum.all?(headers, &is_binary/1) and
        Enum.all?(headers, &Regex.match?(~r/\A[!#$%&'*+\-.^_`|~0-9A-Za-z]+\z/, &1))

    unless valid?,
      do: raise(ArgumentError, "context_headers must contain valid HTTP header names")

    normalized = Enum.map(headers, &String.downcase/1)
    reject_duplicates!(normalized, "context header name(s)")
    normalized
  end

  def limits!(limits, defaults) when is_map(limits) do
    limits |> validate_limit_keys!(defaults) |> merge_limits!(defaults)
  end

  def limits!(limits, defaults) when is_list(limits) do
    unless Keyword.keyword?(limits) do
      raise ArgumentError, "limits must be a keyword list or map of limit overrides"
    end

    reject_duplicates!(Keyword.keys(limits), "limit override(s)")
    limits |> Map.new() |> validate_limit_keys!(defaults) |> merge_limits!(defaults)
  end

  def limits!(_limits, _defaults) do
    raise ArgumentError, "limits must be a keyword list or map of limit overrides"
  end

  def tasks!(%Runtime{} = runtime, selector_configured?) do
    task_pair!(runtime.task_store, runtime.task_runner, selector_configured?)
    clock!(runtime.clock)
    identifier!(runtime.identifier)
  end

  def notifications!(%Runtime{notification: nil, notification_options: []}), do: :ok

  def notifications!(%Runtime{notification: nil}) do
    raise ArgumentError, "notification_options requires notification"
  end

  def notifications!(%Runtime{} = runtime) do
    unless Runtime.task_capable?(runtime) do
      raise ArgumentError, "notification requires task_store and task_runner"
    end

    unless exports?(runtime.notification,
             subscribe: 4,
             take: 2,
             unsubscribe: 2,
             publish: 2
           ) do
      raise ArgumentError,
            "notification: #{inspect(runtime.notification)} does not implement " <>
              "TamaMCP.Notification"
    end
  end

  defp task_pair!(nil, nil, false), do: :ok

  defp task_pair!(nil, nil, true),
    do: raise(ArgumentError, "task_selector requires task_store and task_runner")

  defp task_pair!(nil, _runner, _selector),
    do: raise(ArgumentError, "task_runner requires task_store")

  defp task_pair!(_store, nil, _selector),
    do: raise(ArgumentError, "task_store requires task_runner")

  defp task_pair!(store, runner, _selector) do
    unless exports?(store, create: 2, get: 3, transition: 6, update: 4, cancel: 3) do
      raise ArgumentError,
            "task_store: #{inspect(store)} does not implement TamaMCP.Task.Store"
    end

    unless exports?(runner, start: 4) do
      raise ArgumentError,
            "task_runner: #{inspect(runner)} does not implement TamaMCP.Task.Runner"
    end
  end

  defp clock!(clock) do
    unless exports?(clock, now: 1),
      do: raise(ArgumentError, "clock: #{inspect(clock)} does not implement TamaMCP.Clock")
  end

  defp identifier!(identifier) do
    unless exports?(identifier, generate: 1) do
      raise ArgumentError,
            "identifier: #{inspect(identifier)} does not implement TamaMCP.Identifier"
    end
  end

  def catalog!(server, %Runtime{} = runtime) do
    tools = server.tools()
    limits = runtime.limits

    required = for entry <- tools, entry.module.task_policy() == :required, do: entry.name

    if required != [] and not Runtime.task_capable?(runtime) do
      raise ArgumentError,
            "tools #{inspect(Enum.sort(required))} use task policy :required, which " <>
              "requires a configured task_store and task_runner"
    end

    if length(tools) > limits.max_tools_per_server do
      raise ArgumentError,
            "server defines #{length(tools)} tools; limit is #{limits.max_tools_per_server} " <>
              "(max_tools_per_server)"
    end

    Enum.each(tools, fn entry ->
      schemas!(entry, limits.max_schema_bytes)
      challenge!(entry, limits.max_www_authenticate_bytes)
    end)

    results!(server, Runtime.task_capable?(runtime), limits.max_result_bytes)
  end

  defp challenge!(entry, maximum) do
    case entry.module.scopes() do
      [] ->
        :ok

      scopes ->
        case Challenge.insufficient_scope(scopes, maximum) do
          {:ok, _challenge} ->
            :ok

          {:error, :too_large} ->
            raise ArgumentError,
                  "tool #{inspect(entry.name)} scope challenge exceeds #{maximum} bytes " <>
                    "(max_www_authenticate_bytes)"
        end
    end
  end

  defp results!(server, task_capable?, maximum) do
    results = [
      {"server/discover", Result.discover(server, task_capable?)},
      {"tools/list", Result.tools(server)}
    ]

    Enum.each(results, fn {name, result} -> result!(name, result, maximum) end)
  end

  defp result!(name, result, maximum) do
    case Wire.validate_result(result, maximum) do
      :ok ->
        :ok

      {:error, :result_too_large} ->
        raise ArgumentError, "#{name} result exceeds #{maximum} bytes (max_result_bytes)"

      {:error, :invalid_result} ->
        raise ArgumentError, "#{name} result is not JSON encodable"
    end
  end

  defp schemas!(entry, maximum) do
    metadata = entry.module.tool_metadata()
    schema!(entry.name, :input, metadata.input_schema, maximum)
    schema!(entry.name, :output, metadata.output_schema, maximum)
  end

  defp schema!(_name, _kind, nil, _maximum), do: :ok

  defp schema!(name, kind, schema, maximum) do
    size = schema |> Jason.encode!() |> byte_size()

    if size > maximum do
      raise ArgumentError,
            "tool #{inspect(name)} #{kind} schema is #{size} bytes; limit is #{maximum} " <>
              "(max_schema_bytes)"
    end
  end

  defp validate_limit_keys!(overrides, defaults) do
    reject_unknown!(Map.keys(overrides), Map.keys(defaults), "limit(s)", nil)
    overrides
  end

  defp merge_limits!(overrides, defaults) do
    limits =
      Map.new(defaults, fn {key, default} ->
        {key, positive!(key, Map.get(overrides, key, default))}
      end)

    if limits.default_task_ttl_ms > limits.max_task_ttl_ms do
      raise ArgumentError, "default_task_ttl_ms cannot exceed max_task_ttl_ms"
    end

    limits
  end

  defp positive!(:max_safe_metadata_bytes, value) when is_integer(value) and value >= 2, do: value

  defp positive!(:max_safe_metadata_bytes, value) do
    raise ArgumentError,
          "limit :max_safe_metadata_bytes must be an integer of at least 2, got: #{inspect(value)}"
  end

  defp positive!(:max_www_authenticate_bytes, value)
       when is_integer(value) and value >= @min_www_authenticate_bytes,
       do: value

  defp positive!(:max_www_authenticate_bytes, value) do
    raise ArgumentError,
          "limit :max_www_authenticate_bytes must be an integer of at least " <>
            "#{@min_www_authenticate_bytes}, got: #{inspect(value)}"
  end

  defp positive!(key, value)
       when key in [:default_task_ttl_ms, :max_task_ttl_ms, :default_poll_interval_ms] and
              is_integer(value) and value > 0 and value <= @maximum_protocol_integer,
       do: value

  defp positive!(key, value)
       when key in [:default_task_ttl_ms, :max_task_ttl_ms, :default_poll_interval_ms] do
    raise ArgumentError,
          "limit #{inspect(key)} must be a positive protocol-safe integer no greater than " <>
            "#{@maximum_protocol_integer}, got: #{inspect(value)}"
  end

  defp positive!(_key, value) when is_integer(value) and value > 0, do: value

  defp positive!(key, value) do
    raise ArgumentError,
          "limit #{inspect(key)} must be a positive integer, got: #{inspect(value)}"
  end

  defp reject_unknown!(keys, allowed, label, suffix) do
    case Enum.reject(keys, &(&1 in allowed)) |> Enum.uniq() |> Enum.sort() do
      [] ->
        :ok

      unknown ->
        detail = if suffix, do: "; #{suffix}", else: ""
        raise ArgumentError, "unknown #{label} #{inspect(unknown)}#{detail}"
    end
  end

  defp reject_duplicates!(keys, label) do
    case keys -- Enum.uniq(keys) do
      [] -> :ok
      duplicates -> raise ArgumentError, "duplicate #{label}: #{inspect(Enum.uniq(duplicates))}"
    end
  end

  defp exports?(module, exports) do
    match?({:module, ^module}, Code.ensure_compiled(module)) and
      Enum.all?(exports, fn {name, arity} -> function_exported?(module, name, arity) end)
  end
end
