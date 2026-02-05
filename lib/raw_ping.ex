defmodule RawPing do
  @moduledoc """
  Pure Erlang/OTP ICMP ping library using the modern `:socket` API.

  No NIFs, no external dependencies. Requires Elixir 1.17+ (OTP 25+).

  ## Usage

      # Single ping
      {:ok, rtt_ms} = RawPing.ping("8.8.8.8")
      {:ok, rtt_ms} = RawPing.ping({8, 8, 8, 8})

      # With options
      {:ok, rtt_ms} = RawPing.ping("8.8.8.8", timeout: 2000)

      # Multiple pings with stats
      {:ok, stats} = RawPing.ping_stats("8.8.8.8", count: 5)
      # => {:ok, %{min: 10.5, max: 15.2, avg: 12.3, success_rate: 1.0, ...}}

      # Batch ping multiple hosts
      results = RawPing.ping_batch(["8.8.8.8", "1.1.1.1", "192.168.1.1"])
      # => %{"8.8.8.8" => {:ok, 12.5}, "1.1.1.1" => {:ok, 8.2}, ...}

  ## Privileges

  Raw ICMP sockets typically require elevated privileges. Options:
  - Run as root/sudo
  - Set CAP_NET_RAW capability on the BEAM: `setcap cap_net_raw+ep /path/to/beam.smp`
  - Use a setuid wrapper

  ## How It Works

  Uses Erlang's `:socket` module to open a raw ICMP socket, builds ICMP echo
  request packets manually, sends them, and parses the echo replies to calculate
  round-trip time.
  """

  alias RawPing.{Socket, Packet}

  @default_timeout 5_000
  @default_count 1
  @default_payload_size 56

  @type ip_address :: String.t() | :inet.ip_address() | [integer()]
  @type ping_result :: {:ok, float()} | {:error, term()}
  @type ping_stats :: %{
          min: float() | nil,
          max: float() | nil,
          avg: float() | nil,
          success_rate: float(),
          success_count: non_neg_integer(),
          failure_count: non_neg_integer(),
          rtts: [float()]
        }

  @doc """
  Ping a host and return the round-trip time in milliseconds.

  ## Options

    * `:timeout` - Timeout in milliseconds (default: #{@default_timeout})
    * `:payload_size` - Size of ICMP payload in bytes (default: #{@default_payload_size})

  ## Examples

      {:ok, rtt} = RawPing.ping("8.8.8.8")
      {:ok, rtt} = RawPing.ping({8, 8, 8, 8}, timeout: 1000)
      {:error, :timeout} = RawPing.ping("10.255.255.1", timeout: 100)
  """
  @spec ping(ip_address(), keyword()) :: ping_result()
  def ping(host, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    payload_size = Keyword.get(opts, :payload_size, @default_payload_size)

    with {:ok, ip} <- parse_ip(host),
         {:ok, socket} <- Socket.open(),
         result <- do_ping(socket, ip, timeout, payload_size) do
      Socket.close(socket)
      result
    else
      {:error, _} = error -> error
    end
  end

  @doc """
  Ping a host multiple times and return statistics.

  ## Options

    * `:count` - Number of pings to send (default: #{@default_count})
    * `:timeout` - Timeout per ping in milliseconds (default: #{@default_timeout})
    * `:payload_size` - Size of ICMP payload in bytes (default: #{@default_payload_size})

  ## Examples

      {:ok, stats} = RawPing.ping_stats("8.8.8.8", count: 5)
      # %{min: 10.2, max: 15.8, avg: 12.5, success_rate: 1.0, ...}
  """
  @spec ping_stats(ip_address(), keyword()) :: {:ok, ping_stats()} | {:error, term()}
  def ping_stats(host, opts \\ []) do
    count = Keyword.get(opts, :count, @default_count)
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    payload_size = Keyword.get(opts, :payload_size, @default_payload_size)

    with {:ok, ip} <- parse_ip(host),
         {:ok, socket} <- Socket.open() do
      results =
        Enum.map(1..count, fn seq ->
          do_ping(socket, ip, timeout, payload_size, seq)
        end)

      Socket.close(socket)
      {:ok, calculate_stats(results)}
    end
  end

  @doc """
  Ping multiple hosts concurrently.

  Returns a map of host => result.

  ## Options

    * `:timeout` - Timeout per ping in milliseconds (default: #{@default_timeout})
    * `:max_concurrency` - Maximum concurrent pings (default: 50)

  ## Examples

      results = RawPing.ping_batch(["8.8.8.8", "1.1.1.1"])
      # %{"8.8.8.8" => {:ok, 12.5}, "1.1.1.1" => {:ok, 8.2}}
  """
  @spec ping_batch([ip_address()], keyword()) :: %{String.t() => ping_result()}
  def ping_batch(hosts, opts \\ []) do
    max_concurrency = Keyword.get(opts, :max_concurrency, 50)

    hosts
    |> Task.async_stream(
      fn host -> {to_string_ip(host), ping(host, opts)} end,
      max_concurrency: max_concurrency,
      timeout: Keyword.get(opts, :timeout, @default_timeout) + 1000
    )
    |> Enum.reduce(%{}, fn
      {:ok, {host, result}}, acc -> Map.put(acc, host, result)
      {:exit, _reason}, acc -> acc
    end)
  end

  # Private functions

  defp do_ping(socket, ip, timeout, payload_size, seq \\ 1) do
    id = :rand.uniform(65535)
    packet = Packet.build_echo_request(id, seq, payload_size)
    send_time = System.monotonic_time(:microsecond)
    deadline = send_time + timeout * 1000

    case Socket.send(socket, packet, ip) do
      :ok ->
        recv_loop(socket, id, seq, send_time, deadline)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Keep receiving until we get our reply or timeout
  defp recv_loop(socket, expected_id, expected_seq, send_time, deadline) do
    now = System.monotonic_time(:microsecond)
    remaining_ms = div(deadline - now, 1000)

    if remaining_ms <= 0 do
      {:error, :timeout}
    else
      case Socket.recv(socket, remaining_ms) do
        {:ok, reply} ->
          case Packet.parse_echo_reply(reply) do
            {:ok, ^expected_id, ^expected_seq, _ttl} ->
              recv_time = System.monotonic_time(:microsecond)
              rtt_ms = (recv_time - send_time) / 1000.0
              {:ok, rtt_ms}

            {:ok, _other_id, _other_seq, _ttl} ->
              # Got someone else's reply, keep waiting
              recv_loop(socket, expected_id, expected_seq, send_time, deadline)

            {:error, _reason} ->
              # Malformed packet, keep waiting
              recv_loop(socket, expected_id, expected_seq, send_time, deadline)
          end

        {:error, :timeout} ->
          {:error, :timeout}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp calculate_stats(results) do
    # Single-pass extraction and stats calculation
    {rtts, min, max, sum, success_count, total_count} =
      Enum.reduce(results, {[], nil, nil, 0.0, 0, 0}, fn
        {:ok, rtt}, {rtts, min, max, sum, success, total} ->
          new_min = if min == nil, do: rtt, else: min(min, rtt)
          new_max = if max == nil, do: rtt, else: max(max, rtt)
          {[rtt | rtts], new_min, new_max, sum + rtt, success + 1, total + 1}

        {:error, _}, {rtts, min, max, sum, success, total} ->
          {rtts, min, max, sum, success, total + 1}
      end)

    %{
      min: min,
      max: max,
      avg: if(success_count > 0, do: sum / success_count, else: nil),
      success_rate: if(total_count > 0, do: success_count / total_count, else: 0.0),
      success_count: success_count,
      failure_count: total_count - success_count,
      rtts: Enum.reverse(rtts)
    }
  end

  defp parse_ip(ip) when is_tuple(ip), do: {:ok, ip}

  defp parse_ip([a, b, c, d] = _ip)
       when is_integer(a) and is_integer(b) and is_integer(c) and is_integer(d),
       do: {:ok, {a, b, c, d}}

  defp parse_ip(ip) when is_binary(ip) do
    case :inet.parse_address(String.to_charlist(ip)) do
      {:ok, ip_tuple} -> {:ok, ip_tuple}
      {:error, _} -> {:error, :invalid_ip}
    end
  end

  defp to_string_ip(ip) when is_binary(ip), do: ip
  defp to_string_ip(ip) when is_tuple(ip), do: :inet.ntoa(ip) |> to_string()
  defp to_string_ip([a, b, c, d]), do: "#{a}.#{b}.#{c}.#{d}"
end
