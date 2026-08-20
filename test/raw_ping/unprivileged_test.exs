defmodule RawPing.UnprivilegedTest do
  @moduledoc """
  Exercises the datagram path, which is the whole point of supporting it: ICMP
  with no root and no CAP_NET_RAW.

  These tests are deliberately tolerant of the host. Datagram ICMP is gated on
  Linux by `net.ipv4.ping_group_range`, so on a host that excludes this GID the
  correct behaviour is a clean `:permission_denied` rather than a crash — and
  that is asserted too.
  """
  use ExUnit.Case, async: false

  alias RawPing.Socket

  defp dgram_available? do
    case Socket.open(mode: :dgram) do
      {:ok, socket, :dgram} ->
        Socket.close(socket)
        true

      {:error, _reason} ->
        false
    end
  end

  describe "open/1 mode negotiation" do
    test "dgram either opens or fails cleanly with permission_denied" do
      case Socket.open(mode: :dgram) do
        {:ok, socket, mode} ->
          assert mode == :dgram
          assert :ok = Socket.close(socket)

        {:error, reason} ->
          assert reason == :permission_denied,
                 "expected a clean permission error, got #{inspect(reason)}"
      end
    end

    test "auto reports whichever mode it negotiated" do
      case Socket.open() do
        {:ok, socket, mode} ->
          assert mode in [:dgram, :raw]
          Socket.close(socket)

        {:error, reason} ->
          # No privileges and no datagram permission is a legitimate host state.
          assert reason == :permission_denied
      end
    end

    test "rejects an unknown mode" do
      assert {:error, {:invalid_mode, :nonsense}} = Socket.open(mode: :nonsense)
    end
  end

  describe "unprivileged ping" do
    @tag :integration
    test "pings loopback with no elevated privileges" do
      if dgram_available?() do
        assert {:ok, rtt} = RawPing.ping({127, 0, 0, 1}, mode: :dgram, timeout: 2000)
        assert is_float(rtt)
        assert rtt >= 0.0
      else
        # Nothing to prove on a host that forbids datagram ICMP.
        :ok
      end
    end

    @tag :integration
    test "ping_stats works over the datagram path" do
      if dgram_available?() do
        assert {:ok, stats} = RawPing.ping_stats({127, 0, 0, 1}, mode: :dgram, count: 3, timeout: 2000)
        assert stats.success_count == 3
        assert stats.success_rate == 1.0
        assert is_float(stats.avg)
      else
        :ok
      end
    end
  end

  describe "socket_mode/1" do
    test "reports the negotiated mode without leaking a socket" do
      case RawPing.socket_mode() do
        {:ok, mode} -> assert mode in [:dgram, :raw]
        {:error, reason} -> assert reason == :permission_denied
      end
    end
  end
end
