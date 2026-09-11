defmodule TamaMCP.Transport.StreamableHTTP.Runtime.Validation do
  @moduledoc false

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

  def keyword!(value) do
    unless Keyword.keyword?(value) do
      raise ArgumentError, "authorization_options must be a keyword list, got: #{inspect(value)}"
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

  def catalog!(server, limits) do
    tools = server.tools()

    required = for entry <- tools, entry.module.task_policy() == :required, do: entry.name

    if required != [] do
      raise ArgumentError,
            "tools #{inspect(Enum.sort(required))} use task policy :required, which " <>
              "requires task execution; Phase 1 servers cannot declare task-required tools"
    end

    if length(tools) > limits.max_tools_per_server do
      raise ArgumentError,
            "server defines #{length(tools)} tools; limit is #{limits.max_tools_per_server} " <>
              "(max_tools_per_server)"
    end

    Enum.each(tools, &schemas!(&1, limits.max_schema_bytes))
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
    Map.new(defaults, fn {key, default} ->
      {key, positive!(key, Map.get(overrides, key, default))}
    end)
  end

  defp positive!(:max_safe_metadata_bytes, value) when is_integer(value) and value >= 2, do: value

  defp positive!(:max_safe_metadata_bytes, value) do
    raise ArgumentError,
          "limit :max_safe_metadata_bytes must be an integer of at least 2, got: #{inspect(value)}"
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
