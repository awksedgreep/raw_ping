# RawPing

Pure Erlang/OTP ICMP ping library using the modern `:socket` API.

No NIFs, no external dependencies, no debug trace memory leaks. Requires Elixir 1.17+ (OTP 25+).

## Installation

Add `raw_ping` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:raw_ping, "~> 0.3"}
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

## Hostnames

Targets may be hostnames or literal addresses:

```elixir
RawPing.ping("example.com")
RawPing.ping("8.8.8.8")
RawPing.ping({8, 8, 8, 8})
```

Names are resolved per call, so a target that starts pointing somewhere else is
followed rather than pinned to whatever it resolved to at startup. A name that
does not resolve returns `{:error, :nxdomain}`.

IPv4 only: the socket family is fixed at `:inet`, so IPv6 targets are not yet
supported.

## Privileges

**Most hosts need none.** By default RawPing opens an unprivileged ICMP datagram
socket (`SOCK_DGRAM`/`IPPROTO_ICMP`), falling back to a raw socket only if that
is unavailable.

Check which interface you got:

```elixir
RawPing.socket_mode()
#=> {:ok, :dgram}   # unprivileged
#=> {:ok, :raw}     # fell back; needed root or CAP_NET_RAW
```

On Linux, datagram ICMP is gated by `net.ipv4.ping_group_range`, which must
include the running process's GID. Many distributions already ship it wide open:

```bash
$ cat /proc/sys/net/ipv4/ping_group_range
0	2147483647          # any GID may use unprivileged ICMP
```

If it is restrictive, either widen it — no runtime capability required:

```bash
sudo sysctl -w net.ipv4.ping_group_range="0 2147483647"
```

…or grant the raw-socket path a privilege, as before:

1. **Run as root** (development/testing)
   ```bash
   sudo mix run -e 'RawPing.ping("8.8.8.8") |> IO.inspect'
   ```

2. **Set CAP_NET_RAW capability** (Linux)
   ```bash
   sudo setcap cap_net_raw+ep /path/to/beam.smp
   ```

3. **Container with NET_RAW** (Docker/Kubernetes)
   ```yaml
   securityContext:
     capabilities:
       add: ["NET_RAW"]
   ```

Note that a **rootless container sharing the host network namespace cannot
obtain `CAP_NET_RAW` at all** — that namespace is owned by the initial user
namespace, so the capability has no force there. In that deployment shape the
datagram path is the only way ICMP works.

### When neither interface is available

If the datagram path is forbidden *and* the raw path lacks privileges, every call
returns a clean error rather than crashing:

```elixir
RawPing.socket_mode()    #=> {:error, :permission_denied}
RawPing.ping("8.8.8.8")  #=> {:error, :permission_denied}
RawPing.ping_stats(...)  #=> {:error, :permission_denied}
```

**Check for this at startup rather than per-ping.** A monitoring tool that treats
every error as "host unreachable" will report *all* of its targets as down, and
the real cause — that it cannot open a socket at all — looks identical to a total
outage. That is a bad page to receive at 3am.

```elixir
case RawPing.socket_mode() do
  {:ok, mode} ->
    Logger.info("ICMP available via #{mode} socket")

  {:error, reason} ->
    # Loud, and distinct from "the hosts are down"
    Logger.error("ICMP unavailable: #{inspect(reason)}. Check net.ipv4.ping_group_range, "
                 <> "or grant CAP_NET_RAW.")
end
```

This is most likely to bite in a rootless container where `ping_group_range` has
been tightened, since `CAP_NET_RAW` is unobtainable there as a fallback.

### Platform differences

The two platforms behave differently on datagram sockets. RawPing handles both
by inspecting the reply rather than assuming a format:

| | Linux | macOS/BSD |
|---|---|---|
| IP header on receive | stripped | included |
| ICMP identifier | rewritten by kernel | preserved |
| TTL available | no (`nil`) | yes |

Because Linux rewrites the identifier, replies from a datagram socket are
matched on **sequence**. Raw sockets keep the stricter id-and-sequence match,
since they see every ICMP packet on the host.

## Why Not gen_icmp?

This library was created as an alternative to `gen_icmp` which:

- Uses NIFs via `procket` for raw socket access
- Abuses `gen_udp` internals in ways that can trigger debug traces
- Can cause severe memory leaks (20GB+) when pinging unreachable hosts at scale

`RawPing` uses Erlang/OTP's native `:socket` API (available since OTP 22) which provides clean, safe access to raw sockets without any of these issues.

## How It Works

1. Opens an ICMP socket, preferring the unprivileged datagram interface and
   falling back to a raw socket (`:socket.open/3`, with `IPPROTO_ICMP` given
   numerically so it does not depend on the system protocol database)
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
