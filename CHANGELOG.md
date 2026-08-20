# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.3.1] - 2026-08-20

### Added
- **Hostnames are resolved.** `ping/2`, `ping_stats/2` and `ping_batch/2` accept a
  hostname, resolved via `:inet.getaddr/2` when the value is not already a literal
  address. Monitoring targets are usually named rather than numbered, and requiring
  literals meant re-pinning every target by hand whenever a host moved. IPv4 only:
  the socket family is fixed at `:inet`, so IPv6 targets remain out of scope.

### Changed
- A name that does not resolve returns `:inet.getaddr/2`'s error, normally
  `{:error, :nxdomain}`, instead of `{:error, :invalid_ip}` — which described a
  syntactically valid hostname as malformed and pointed at the wrong problem.

### Fixed
- **ICMP sockets open in minimal container images.** The protocol is passed as the
  number `1` rather than the atom `:icmp`. Erlang resolves protocol atoms through
  the system protocol database, and slim images routinely omit `/etc/protocols` (it
  ships in Debian's `netbase`), where `:icmp` failed with
  `{:invalid, {:protocol, :icmp}}` — an error that reads like a bad address or a
  missing capability and is neither.

## [0.3.0] - 2026-08-20

### Added
- **Unprivileged ICMP.** Sockets now open in `SOCK_DGRAM`/`IPPROTO_ICMP` mode by
  default, which requires no root and no `CAP_NET_RAW`, falling back to
  `SOCK_RAW` only where the datagram path is unavailable. On Linux availability
  is gated by `net.ipv4.ping_group_range`, which many distributions ship open.
- `:mode` option (`:auto` | `:dgram` | `:raw`) on `ping/2` and `ping_stats/2`.
- `RawPing.socket_mode/1` reports which interface was negotiated, so a
  deployment can confirm it is running unprivileged.
- `RawPing.Packet.parse_echo_reply/2` accepts the socket mode.

### Changed
- **Breaking:** `RawPing.Socket.open/1` now returns `{:ok, socket, mode}` rather
  than `{:ok, socket}`.
- Reply parsing detects whether an IP header is present instead of assuming one.
  That is a property of the host rather than of the socket: Linux strips the
  header on datagram sockets while macOS/BSD includes it, so neither assumption
  is portable.
- Replies from datagram sockets are matched on sequence number. Linux replaces
  the ICMP identifier with its own value, so matching on the id we wrote could
  never succeed there. Raw sockets keep the stricter id-and-sequence match, as
  they receive every ICMP packet on the host.
- TTL is `nil` when a reply arrives without an IP header; recovering it would
  require `IP_RECVTTL` ancillary data.

### Fixed
- Echo replies shorter than 28 bytes are no longer rejected as malformed. That
  minimum assumed a 20-byte IP header, but a Linux datagram reply is 16 bytes
  and was being discarded.

### Notes
- A rootless container sharing the host network namespace cannot acquire
  `CAP_NET_RAW`, because that namespace is owned by the initial user namespace.
  The datagram path is what makes ICMP possible in that deployment shape.

## [0.2.0] - 2025-02-05

### Added
- List format IP addresses: `RawPing.ping([8, 8, 8, 8])`
- IEx helpers (`.iex.exs`) with convenient shortcuts for interactive use
- Auto-skip privileged tests when not running as root

### Changed
- **Performance**: `build_echo_request/3` now builds packet once instead of twice
- **Performance**: Checksum calculation is O(1) regardless of payload size (zero padding is skipped)
- **Performance**: `calculate_stats/1` uses single-pass reduce instead of multiple iterations

### Fixed
- `to_string_ip/1` now handles list format IPs (fixes crash in `ping_batch` with list IPs)

## [0.1.0] - 2025-02-04

### Added
- Initial release
- `RawPing.ping/2` - Single host ping with RTT
- `RawPing.ping_stats/2` - Multiple pings with min/max/avg statistics
- `RawPing.ping_batch/2` - Concurrent multi-host pinging
- Pure OTP implementation using `:socket` API
- No NIFs, no external dependencies
