defmodule RawPingTest do
  use ExUnit.Case, async: false

  # These tests require root/sudo privileges to run.
  # Run with: sudo mix test
  #
  # Tests are tagged so you can skip privileged tests:
  #   mix test --exclude privileged
  #   sudo mix test --only privileged

  @moduletag :privileged

  describe "ping/2" do
    test "successfully pings localhost" do
      assert {:ok, rtt} = RawPing.ping("127.0.0.1")
      assert is_float(rtt)
      assert rtt >= 0
      assert rtt < 100  # localhost should be < 100ms
    end

    test "successfully pings localhost with tuple IP" do
      assert {:ok, rtt} = RawPing.ping({127, 0, 0, 1})
      assert is_float(rtt)
      assert rtt >= 0
    end

    test "returns timeout for unreachable host" do
      # RFC 5737 test network - should not be routable
      assert {:error, :timeout} = RawPing.ping("192.0.2.1", timeout: 200)
    end

    test "returns error for invalid IP" do
      assert {:error, :invalid_ip} = RawPing.ping("not.an.ip.address")
    end

    test "respects custom timeout" do
      start = System.monotonic_time(:millisecond)
      {:error, :timeout} = RawPing.ping("192.0.2.1", timeout: 100)
      elapsed = System.monotonic_time(:millisecond) - start

      # Should complete within timeout + some buffer
      assert elapsed < 300
    end

    test "pings external DNS servers" do
      # Google DNS
      assert {:ok, rtt} = RawPing.ping("8.8.8.8", timeout: 5000)
      assert is_float(rtt)
      assert rtt > 0
    end
  end

  describe "ping_stats/2" do
    test "returns correct stats structure" do
      assert {:ok, stats} = RawPing.ping_stats("127.0.0.1", count: 3)

      assert Map.has_key?(stats, :min)
      assert Map.has_key?(stats, :max)
      assert Map.has_key?(stats, :avg)
      assert Map.has_key?(stats, :success_rate)
      assert Map.has_key?(stats, :success_count)
      assert Map.has_key?(stats, :failure_count)
      assert Map.has_key?(stats, :rtts)
    end

    test "calculates correct success rate for localhost" do
      assert {:ok, stats} = RawPing.ping_stats("127.0.0.1", count: 5)

      assert stats.success_rate == 1.0
      assert stats.success_count == 5
      assert stats.failure_count == 0
      assert length(stats.rtts) == 5
    end

    test "calculates correct stats for unreachable host" do
      assert {:ok, stats} = RawPing.ping_stats("192.0.2.1", count: 2, timeout: 200)

      assert stats.success_rate == 0.0
      assert stats.success_count == 0
      assert stats.failure_count == 2
      assert stats.min == nil
      assert stats.max == nil
      assert stats.avg == nil
      assert stats.rtts == []
    end

    test "min <= avg <= max" do
      assert {:ok, stats} = RawPing.ping_stats("127.0.0.1", count: 5)

      assert stats.min <= stats.avg
      assert stats.avg <= stats.max
    end
  end

  describe "ping_batch/2" do
    test "pings multiple hosts concurrently" do
      hosts = ["127.0.0.1", "8.8.8.8"]
      results = RawPing.ping_batch(hosts, timeout: 5000)

      assert is_map(results)
      assert Map.has_key?(results, "127.0.0.1")
      assert Map.has_key?(results, "8.8.8.8")
    end

    test "returns correct results for mixed reachable/unreachable" do
      hosts = ["127.0.0.1", "192.0.2.1"]
      results = RawPing.ping_batch(hosts, timeout: 300)

      assert {:ok, _rtt} = results["127.0.0.1"]
      assert {:error, :timeout} = results["192.0.2.1"]
    end

    test "handles empty host list" do
      results = RawPing.ping_batch([])
      assert results == %{}
    end

    test "respects max_concurrency" do
      # Create enough hosts to test concurrency limiting
      hosts = for i <- 1..10, do: "127.0.0.#{rem(i, 255)}"

      # This should not crash with limited concurrency
      results = RawPing.ping_batch(hosts, max_concurrency: 3, timeout: 1000)

      assert map_size(results) == 10
    end
  end
end
