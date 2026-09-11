defmodule TamaMCP.Transport.StreamableHTTP.Body do
  @moduledoc false

  @json "application/json"
  @event_stream "text/event-stream"

  @spec validate(Plug.Conn.t()) :: :ok | {:error, TamaMCP.Error.t()}
  def validate(conn) do
    case content_type(conn.req_headers) do
      :ok -> accept(conn.req_headers)
      {:error, _error} = failure -> failure
    end
  end

  @spec read(Plug.Conn.t(), map()) ::
          {:ok, binary(), Plug.Conn.t()}
          | {:error, :too_large | :timeout | :read, Plug.Conn.t()}
          | {:error, TamaMCP.Error.t(), Plug.Conn.t()}
  def read(conn, limits) do
    case content_length(conn.req_headers, limits.max_body_bytes) do
      :ok ->
        deadline = System.monotonic_time(:millisecond) + limits.body_read_timeout_ms
        read_chunks(conn, limits.max_body_bytes, deadline, [], 0)

      {:error, reason} ->
        {:error, reason, conn}
    end
  end

  defp content_type(headers) do
    case header(headers, "content-type") do
      {:ok, value} ->
        if media(value) == @json,
          do: :ok,
          else: {:error, TamaMCP.Error.invalid_request("Content-Type must be application/json")}

      _ ->
        {:error, TamaMCP.Error.invalid_request("Content-Type must be application/json")}
    end
  end

  defp accept(headers) do
    case header(headers, "accept") do
      {:ok, value} ->
        accepted =
          value
          |> String.split(",")
          |> Enum.filter(&(quality(&1) > 0.0))
          |> Enum.map(&media/1)

        if @json in accepted and @event_stream in accepted do
          :ok
        else
          accept_error()
        end

      _ ->
        accept_error()
    end
  end

  defp accept_error do
    {:error,
     TamaMCP.Error.invalid_request("Accept must list both application/json and text/event-stream")}
  end

  defp content_length(headers, maximum) do
    case header(headers, "content-length") do
      :missing ->
        :ok

      {:ok, value} ->
        case Integer.parse(value) do
          {size, ""} when size >= 0 and size <= maximum -> :ok
          {size, ""} when size > maximum -> {:error, :too_large}
          _ -> {:error, TamaMCP.Error.invalid_request("Content-Length header is invalid")}
        end

      :duplicate ->
        {:error, TamaMCP.Error.invalid_request("Content-Length must be a single value")}
    end
  end

  defp read_chunks(conn, maximum, deadline, chunks, size) do
    remaining_time = deadline - System.monotonic_time(:millisecond)

    if remaining_time <= 0 do
      {:error, :timeout, conn}
    else
      remaining_bytes = maximum - size

      case Plug.Conn.read_body(conn, length: remaining_bytes + 1, read_timeout: remaining_time) do
        {:ok, data, conn} -> finish(conn, chunks, size, data, maximum)
        {:more, data, conn} -> continue(conn, chunks, size, data, maximum, deadline)
        {:error, :timeout} -> {:error, :timeout, conn}
        {:error, _reason} -> {:error, :read, conn}
      end
    end
  end

  defp finish(conn, chunks, size, data, maximum) do
    if size + byte_size(data) > maximum do
      {:error, :too_large, conn}
    else
      {:ok, IO.iodata_to_binary(Enum.reverse([data | chunks])), conn}
    end
  end

  defp continue(conn, chunks, size, data, maximum, deadline) do
    next_size = size + byte_size(data)

    if next_size > maximum do
      {:error, :too_large, conn}
    else
      read_chunks(conn, maximum, deadline, [data | chunks], next_size)
    end
  end

  defp header(headers, name) do
    case for({key, value} <- headers, String.downcase(key) == name, do: value) do
      [] -> :missing
      [value] -> {:ok, value}
      _ -> :duplicate
    end
  end

  defp media(value) do
    value |> String.split(";", parts: 2) |> hd() |> String.trim() |> String.downcase()
  end

  defp quality(value) do
    value
    |> String.split(";")
    |> tl()
    |> Enum.find_value(1.0, fn parameter ->
      case String.split(String.trim(parameter), "=", parts: 2) do
        [name, quality] when name in ["q", "Q"] -> parse_quality(quality)
        _ -> nil
      end
    end)
  end

  defp parse_quality(value) do
    case Float.parse(String.trim(value)) do
      {quality, ""} when quality >= 0.0 and quality <= 1.0 -> quality
      _ -> 0.0
    end
  end
end
