# RawPing IEx Helpers
# Run with: sudo iex -S mix

IO.puts("""
\e[36m
╔═══════════════════════════════════════════════════════════════════╗
║                         RawPing Console                           ║
╠═══════════════════════════════════════════════════════════════════╣
║  Quick Commands:                                                  ║
║    p("8.8.8.8")              - Single ping                        ║
║    ps("8.8.8.8", 5)          - Ping 5 times with stats            ║
║    pb(["8.8.8.8", "1.1.1.1"]) - Batch ping multiple hosts         ║
║    dns_servers()             - Ping common DNS servers            ║
║    speedtest()               - Poor man's bandwidth test          ║
║    help()                    - Show all available helpers         ║
╚═══════════════════════════════════════════════════════════════════╝
\e[0m
""")

# Aliases
alias RawPing
alias RawPing.{Socket, Packet}

# ============================================================================
# Quick Ping Helpers
# ============================================================================

# Single ping with formatted output
defmodule H do
  @moduledoc "RawPing IEx helpers"

  @doc "Quick ping - returns RTT in ms"
  def p(host, opts \\ []) do
    case RawPing.ping(host, opts) do
      {:ok, rtt} ->
        IO.puts("\e[32m✓ #{host} - #{Float.round(rtt, 2)}ms\e[0m")
        {:ok, rtt}

      {:error, reason} ->
        IO.puts("\e[31m✗ #{host} - #{inspect(reason)}\e[0m")
        {:error, reason}
    end
  end

  @doc "Ping with statistics"
  def ps(host, count \\ 5, opts \\ []) do
    opts = Keyword.put(opts, :count, count)

    case RawPing.ping_stats(host, opts) do
      {:ok, stats} ->
        print_stats(host, stats)
        {:ok, stats}

      {:error, reason} ->
        IO.puts("\e[31m✗ #{host} - #{inspect(reason)}\e[0m")
        {:error, reason}
    end
  end

  @doc "Batch ping multiple hosts"
  def pb(hosts, opts \\ []) do
    results = RawPing.ping_batch(hosts, opts)
    print_batch(results)
    results
  end

  @doc "Continuous ping (like ping -c n)"
  def pn(host, count, opts \\ []) do
    IO.puts("PING #{host}")

    Enum.reduce(1..count, [], fn seq, rtts ->
      case RawPing.ping(host, opts) do
        {:ok, rtt} ->
          IO.puts("seq=#{seq} time=#{Float.round(rtt, 2)}ms")
          Process.sleep(1000)
          [rtt | rtts]

        {:error, reason} ->
          IO.puts("seq=#{seq} \e[31m#{inspect(reason)}\e[0m")
          Process.sleep(1000)
          rtts
      end
    end)
    |> Enum.reverse()
    |> then(fn rtts ->
      if length(rtts) > 0 do
        IO.puts("\n--- #{host} statistics ---")
        IO.puts("#{count} packets transmitted, #{length(rtts)} received")
        IO.puts("rtt min/avg/max = #{Float.round(Enum.min(rtts), 2)}/#{Float.round(Enum.sum(rtts) / length(rtts), 2)}/#{Float.round(Enum.max(rtts), 2)} ms")
      end
    end)
  end

  defp print_stats(host, stats) do
    IO.puts("""
    \e[36m--- #{host} ping statistics ---\e[0m
    #{stats.success_count + stats.failure_count} packets transmitted, #{stats.success_count} received, #{Float.round((1 - stats.success_rate) * 100, 1)}% loss
    rtt min/avg/max = #{format_rtt(stats.min)}/#{format_rtt(stats.avg)}/#{format_rtt(stats.max)} ms
    """)
  end

  defp format_rtt(nil), do: "-"
  defp format_rtt(rtt), do: Float.round(rtt, 2) |> to_string()

  defp print_batch(results) do
    IO.puts("\n\e[36m--- Batch Ping Results ---\e[0m")

    results
    |> Enum.sort_by(fn {host, _} -> host end)
    |> Enum.each(fn {host, result} ->
      case result do
        {:ok, rtt} ->
          IO.puts("  \e[32m✓\e[0m #{String.pad_trailing(host, 20)} #{Float.round(rtt, 2)}ms")

        {:error, reason} ->
          IO.puts("  \e[31m✗\e[0m #{String.pad_trailing(host, 20)} #{inspect(reason)}")
      end
    end)

    IO.puts("")
  end

  @doc "Show help"
  def help do
    IO.puts("""
    \e[36mRawPing IEx Helpers\e[0m

    \e[33mBasic Pings:\e[0m
      p(host)                  - Single ping with formatted output
      p(host, timeout: 2000)   - Ping with custom timeout (ms)
      ps(host)                 - Ping 5 times, show statistics
      ps(host, 10)             - Ping n times, show statistics
      pn(host, 10)             - Continuous ping n times (1s interval)

    \e[33mBatch Operations:\e[0m
      pb(hosts)                - Ping list of hosts concurrently
      pb(hosts, max_concurrency: 10)

    \e[33mPresets:\e[0m
      dns_servers()            - Ping common public DNS servers
      local()                  - Ping localhost
      gateway()                - Ping common gateway IPs
      speedtest()              - Poor man's speed test (large payload flood)
      speedtest("1.1.1.1", count: 50, payload_size: 1400)

    \e[33mDirect API:\e[0m
      RawPing.ping(host, opts)
      RawPing.ping_stats(host, opts)
      RawPing.ping_batch(hosts, opts)

    \e[33mOptions:\e[0m
      :timeout       - Timeout in ms (default: 5000)
      :count         - Number of pings for stats (default: 1)
      :payload_size  - ICMP payload bytes (default: 56)
      :max_concurrency - Max concurrent batch pings (default: 50)
    """)
  end

  @doc "Ping common DNS servers"
  def dns_servers do
    hosts = [
      "8.8.8.8",        # Google
      "8.8.4.4",        # Google Secondary
      "1.1.1.1",        # Cloudflare
      "1.0.0.1",        # Cloudflare Secondary
      "9.9.9.9",        # Quad9
      "208.67.222.222"  # OpenDNS
    ]

    IO.puts("\e[36mPinging public DNS servers...\e[0m\n")
    pb(hosts)
  end

  @doc "Ping localhost"
  def local do
    p("127.0.0.1")
  end

  @doc "Ping common gateway addresses"
  def gateway do
    hosts = ["192.168.1.1", "192.168.0.1", "10.0.0.1"]
    pb(hosts, timeout: 1000)
  end

  @doc """
  Poor man's speed test - flood pings with large payloads.

  Options:
    - count: number of pings (default: 20)
    - payload_size: bytes per ping (default: 1472, max unfragmented)
    - timeout: ms per ping (default: 2000)
  """
  def speedtest(host \\ "8.8.8.8", opts \\ []) do
    count = Keyword.get(opts, :count, 20)
    payload_size = Keyword.get(opts, :payload_size, 1472)
    timeout = Keyword.get(opts, :timeout, 2000)

    # Total bytes per round trip (payload * 2 for send + receive)
    bytes_per_ping = payload_size * 2

    IO.puts("\e[36m--- Speed Test to #{host} ---\e[0m")
    IO.puts("Sending #{count} pings with #{payload_size} byte payloads...\n")

    start_time = System.monotonic_time(:millisecond)

    results =
      1..count
      |> Enum.map(fn _seq ->
        case RawPing.ping(host, timeout: timeout, payload_size: payload_size) do
          {:ok, rtt} ->
            IO.write("\e[32m.\e[0m")
            {:ok, rtt}

          {:error, reason} ->
            IO.write("\e[31mx\e[0m")
            {:error, reason}
        end
      end)

    elapsed_ms = System.monotonic_time(:millisecond) - start_time
    IO.puts("\n")

    successful = Enum.filter(results, &match?({:ok, _}, &1))
    success_count = length(successful)
    rtts = Enum.map(successful, fn {:ok, rtt} -> rtt end)

    if success_count > 0 do
      total_bytes = success_count * bytes_per_ping
      elapsed_sec = elapsed_ms / 1000
      throughput_kbps = total_bytes * 8 / 1000 / elapsed_sec
      throughput_mbps = throughput_kbps / 1000

      avg_rtt = Enum.sum(rtts) / success_count
      min_rtt = Enum.min(rtts)
      max_rtt = Enum.max(rtts)

      IO.puts("""
      \e[33mResults:\e[0m
        Packets: #{success_count}/#{count} successful (#{Float.round(success_count / count * 100, 1)}%)
        RTT: #{Float.round(min_rtt, 2)}/#{Float.round(avg_rtt, 2)}/#{Float.round(max_rtt, 2)} ms (min/avg/max)
        Time: #{Float.round(elapsed_sec, 2)}s
        Data: #{Float.round(total_bytes / 1024, 1)} KB transferred

      \e[33mEstimated throughput:\e[0m
        #{Float.round(throughput_kbps, 1)} Kbps (~#{Float.round(throughput_mbps, 2)} Mbps)

      \e[90mNote: ICMP throughput is rate-limited by most hosts and networks.
      This is not a real bandwidth test, just a rough indication.\e[0m
      """)
    else
      IO.puts("\e[31mAll pings failed - cannot calculate throughput\e[0m")
    end

    :ok
  end
end

# Import helpers into main scope
import H

# ============================================================================
# Example Usage - Copy/paste these to try the library
# ============================================================================
#
# --- Single Ping ---
#
#   # Basic ping (returns RTT in milliseconds)
#   {:ok, rtt} = RawPing.ping("8.8.8.8")
#
#   # Ping with tuple IP address
#   {:ok, rtt} = RawPing.ping({1, 1, 1, 1})
#
#   # Custom timeout (milliseconds)
#   {:ok, rtt} = RawPing.ping("8.8.8.8", timeout: 2000)
#
#   # Custom payload size (bytes)
#   {:ok, rtt} = RawPing.ping("8.8.8.8", payload_size: 128)
#
#   # Handle errors
#   case RawPing.ping("192.0.2.1", timeout: 500) do
#     {:ok, rtt} -> IO.puts("RTT: #{rtt}ms")
#     {:error, :timeout} -> IO.puts("Host unreachable")
#     {:error, :invalid_ip} -> IO.puts("Bad IP address")
#     {:error, reason} -> IO.puts("Error: #{inspect(reason)}")
#   end
#
# --- Ping Statistics ---
#
#   # Ping multiple times and get stats
#   {:ok, stats} = RawPing.ping_stats("8.8.8.8", count: 10)
#
#   # Stats structure:
#   # %{
#   #   min: 12.3,           # minimum RTT (ms)
#   #   max: 18.7,           # maximum RTT (ms)
#   #   avg: 14.2,           # average RTT (ms)
#   #   success_rate: 1.0,   # 0.0 to 1.0
#   #   success_count: 10,
#   #   failure_count: 0,
#   #   rtts: [12.3, ...]    # all successful RTTs
#   # }
#
#   # Access individual stats
#   IO.puts("Average: #{stats.avg}ms, Loss: #{(1 - stats.success_rate) * 100}%")
#
# --- Batch Ping ---
#
#   # Ping multiple hosts concurrently
#   results = RawPing.ping_batch(["8.8.8.8", "1.1.1.1", "9.9.9.9"])
#
#   # Results structure:
#   # %{
#   #   "8.8.8.8" => {:ok, 12.5},
#   #   "1.1.1.1" => {:ok, 8.2},
#   #   "9.9.9.9" => {:ok, 15.1}
#   # }
#
#   # Control concurrency
#   results = RawPing.ping_batch(hosts, max_concurrency: 10, timeout: 2000)
#
#   # Process results
#   Enum.each(results, fn {host, result} ->
#     case result do
#       {:ok, rtt} -> IO.puts("#{host}: #{rtt}ms")
#       {:error, reason} -> IO.puts("#{host}: #{reason}")
#     end
#   end)
#
# --- Low-Level API ---
#
#   # Direct socket operations (for advanced use)
#   {:ok, socket} = RawPing.Socket.open()
#   packet = RawPing.Packet.build_echo_request(_id = 1, _seq = 1, _payload_size = 56)
#   :ok = RawPing.Socket.send(socket, packet, {8, 8, 8, 8})
#   {:ok, reply} = RawPing.Socket.recv(socket, _timeout = 5000)
#   {:ok, id, seq, ttl} = RawPing.Packet.parse_echo_reply(reply)
#   RawPing.Socket.close(socket)
#
