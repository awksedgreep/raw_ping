# RawPing

Pure Erlang/OTP ICMP ping library using the modern `:socket` API.

No NIFs, no external dependencies, no debug trace memory leaks. Requires Elixir 1.17+ (OTP 25+).

## Installation

Add `raw_ping` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:raw_ping, "~> 0.2.0"}
  ]
end
```

## Usage

```elixir
# Single ping - returns RTT in milliseconds
{:ok, rtt} = RawPing.ping("8.8.8.8")
{:ok, rtt} = RawPing.ping({8, 8, 8, 8})
{:ok, rtt} = RawPing.ping([8, 8, 8, 8])  # list format also works

# With options
{:ok, rtt} = RawPing.ping("8.8.8.8", timeout: 2000)
{:error, :timeout} = RawPing.ping("192.0.2.1", timeout: 100)

# Multiple pings with statistics
{:ok, stats} = RawPing.ping_stats("8.8.8.8", count: 5)
# %{min: 10.2, max: 15.8, avg: 12.5, success_rate: 1.0, success_count: 5, failure_count: 0, rtts: [...]}

# Batch ping multiple hosts concurrently
results = RawPing.ping_batch(["8.8.8.8", "1.1.1.1", "192.168.1.1"], timeout: 1000)
# %{"8.8.8.8" => {:ok, 12.5}, "1.1.1.1" => {:ok, 8.2}, "192.168.1.1" => {:error, :timeout}}
```

## Options

| Option | Default | Description |
|--------|---------|-------------|
| `:timeout` | 5000 | Timeout in milliseconds |
| `:count` | 1 | Number of pings (for `ping_stats/2`) |
| `:payload_size` | 56 | ICMP payload size in bytes |
| `:max_concurrency` | 50 | Max concurrent pings (for `ping_batch/2`) |

## Privileges

Raw ICMP sockets require elevated privileges. Options:

1. **Run as root** (development/testing)
   ```bash
   sudo mix run -e 'RawPing.ping("8.8.8.8") |> IO.inspect'
   ```

2. **Set CAP_NET_RAW capability** (Linux production)
   ```bash
   sudo setcap cap_net_raw+ep /path/to/beam.smp
   ```

3. **Container with NET_RAW** (Docker/Kubernetes)
   ```yaml
   securityContext:
     capabilities:
       add: ["NET_RAW"]
   ```

## Why Not gen_icmp?

This library was created as an alternative to `gen_icmp` which:

- Uses NIFs via `procket` for raw socket access
- Abuses `gen_udp` internals in ways that can trigger debug traces
- Can cause severe memory leaks (20GB+) when pinging unreachable hosts at scale

`RawPing` uses Erlang/OTP's native `:socket` API (available since OTP 22) which provides clean, safe access to raw sockets without any of these issues.

## How It Works

1. Opens a raw ICMP socket via `:socket.open(:inet, :raw, :icmp)`
2. Builds ICMP echo request packets with proper checksums
3. Sends to target and receives replies with timeout handling
4. Parses ICMP echo replies, filtering by ID/sequence to handle concurrent pings

## Testing

```bash
# Run non-privileged tests (packet building/parsing)
mix test --exclude privileged

# Run all tests (requires sudo)
sudo mix test
```

## License

MIT License - see [LICENSE](LICENSE) for details.
