# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
