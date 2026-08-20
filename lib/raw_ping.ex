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

  Most hosts need none. By default an unprivileged ICMP datagram socket is used,
  falling back to a raw socket only where that is unavailable:

      RawPing.socket_mode()
      #=> {:ok, :dgram}   # no privileges required
      #=> {:ok, :raw}     # fell back; needed root or CAP_NET_RAW

  On Linux the datagram path is gated by `net.ipv4.ping_group_range`, which must
  include the process's GID; many distributions ship it wide open. Where it is
  restricted, the raw path still needs root, `CAP_NET_RAW` on the BEAM
  (`setcap cap_net_raw+ep /path/to/beam.smp`), or a container granted `NET_RAW`.

  See `RawPing.Socket` for the trade-offs and the platform differences.

  ## How It Works

  Uses Erlang's `:socket` module to open an ICMP socket, builds ICMP echo
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
    * `:mode` - Socket mode, `:auto` (default), `:dgram`, or `:raw`. See
      `RawPing.Socket` for what each requires.

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
         {:ok, socket, mode} <- Socket.open(socket_opts(opts)),
         result <- do_ping(socket, mode, ip, timeout, payload_size) do
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
    * `:mode` - Socket mode, `:auto` (default), `:dgram`, or `:raw`. See
      `RawPing.Socket` for what each requires.

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
         {:ok, socket, mode} <- Socket.open(socket_opts(opts)) do
      results =
        Enum.map(1..count, fn seq ->
          do_ping(socket, mode, ip, timeout, payload_size, seq)
        end)

      Socket.close(socket)
      {:ok, calculate_stats(results)}
    end
  end

  @doc """
  Report which socket mode is available to this process.

  Opens a socket using the same negotiation as `ping/2` and closes it
  immediately. `:dgram` means ICMP works with no elevated privileges; `:raw`
  means it fell back to a raw socket, which required root or `CAP_NET_RAW`.

  Useful for confirming a deployment is running unprivileged.

      {:ok, :dgram} = RawPing.socket_mode()
  """
  @spec socket_mode(keyword()) :: {:ok, RawPing.Socket.mode()} | {:error, term()}
  def socket_mode(opts \\ []) do
    case Socket.open(socket_opts(opts)) do
      {:ok, socket, mode} ->
        Socket.close(socket)
        {:ok, mode}

      {:error, _} = error ->
        error
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

  defp socket_opts(opts), do: Keyword.take(opts, [:mode])

  defp do_ping(socket, mode, ip, timeout, payload_size, seq \\ 1) do
    id = :rand.uniform(65535)
    packet = Packet.build_echo_request(id, seq, payload_size)
    send_time = System.monotonic_time(:microsecond)
    deadline = send_time + timeout * 1000

    case Socket.send(socket, packet, ip) do
      :ok ->
        recv_loop(socket, mode, id, seq, send_time, deadline)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Keep receiving until we get our reply or timeout
  defp recv_loop(socket, mode, expected_id, expected_seq, send_time, deadline) do
    now = System.monotonic_time(:microsecond)
    remaining_ms = div(deadline - now, 1000)

    if remaining_ms <= 0 do
      {:error, :timeout}
    else
      case Socket.recv(socket, remaining_ms) do
        {:ok, reply} ->
          case Packet.parse_echo_reply(reply, mode) do
            {:ok, id, seq, _ttl} ->
              if reply_matches?(mode, id, seq, expected_id, expected_seq) do
                recv_time = System.monotonic_time(:microsecond)
                rtt_ms = (recv_time - send_time) / 1000.0
                {:ok, rtt_ms}
              else
                # Got someone else's reply, keep waiting
                recv_loop(socket, mode, expected_id, expected_seq, send_time, deadline)
              end

            {:error, _reason} ->
              # Malformed packet, keep waiting
              recv_loop(socket, mode, expected_id, expected_seq, send_time, deadline)
          end

        {:error, :timeout} ->
          {:error, :timeout}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # On datagram sockets the kernel substitutes its own identifier, so the id we
  # wrote never comes back and matching on it would reject every reply. The
  # sequence number is still ours, and each ping owns its socket, so sequence
  # alone identifies the reply. Raw sockets see every ICMP packet on the host,
  # so they keep the stricter check.
  defp reply_matches?(:dgram, _id, seq, _expected_id, expected_seq), do: seq == expected_seq

  defp reply_matches?(:raw, id, seq, expected_id, expected_seq),
    do: id == expected_id and seq == expected_seq

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

  # A literal address first, then DNS. Resolution happens per call: the OS
  # resolver caches, and a monitoring target that starts pointing somewhere else
  # should be followed rather than pinned to whatever it resolved to at startup.
  #
  # A name that does not resolve returns :inet.getaddr/2's own error — usually
  # :nxdomain — rather than :invalid_ip, which described a perfectly valid
  # hostname as malformed and sent you looking in the wrong place.
  #
  # IPv4 only for now: the socket family is fixed at :inet in RawPing.Socket, so
  # returning a v6 address here would open a v4 socket against it.
  defp parse_ip(ip) when is_binary(ip) do
    charlist = String.to_charlist(ip)

    case :inet.parse_address(charlist) do
      {:ok, ip_tuple} -> {:ok, ip_tuple}
      {:error, _} -> :inet.getaddr(charlist, :inet)
    end
  end

  defp to_string_ip(ip) when is_binary(ip), do: ip
  defp to_string_ip(ip) when is_tuple(ip), do: :inet.ntoa(ip) |> to_string()
  defp to_string_ip([a, b, c, d]), do: "#{a}.#{b}.#{c}.#{d}"
end
