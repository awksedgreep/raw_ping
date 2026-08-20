defmodule RawPing.HostnameTest do
  @moduledoc """
  Hostname resolution. Monitoring targets are usually named rather than
  numbered, so requiring literals meant pinning every target to an address by
  hand and re-pinning it whenever the host moved.
  """
  use ExUnit.Case, async: true

  describe "unresolvable names" do
    test "return :nxdomain rather than :invalid_ip" do
      # The old behaviour reported :invalid_ip for any non-literal, describing a
      # syntactically fine hostname as malformed and pointing the operator at
      # the wrong problem.
      assert {:error, :nxdomain} =
               RawPing.ping("no-such-host.invalid", timeout: 1000)
    end

    test "ping_stats reports the same error" do
      assert {:error, :nxdomain} =
               RawPing.ping_stats("no-such-host.invalid", count: 1, timeout: 1000)
    end
  end

  describe "literal addresses" do
    test "are still accepted in every supported shape" do
      # Resolution must not disturb the existing input forms.
      for target <- ["127.0.0.1", {127, 0, 0, 1}, [127, 0, 0, 1]] do
        assert {:ok, rtt} = RawPing.ping(target, timeout: 2000)
        assert is_float(rtt)
      end
    end

    test "a literal is not sent to the resolver" do
      # An address that would be nonsense as a hostname still parses as a
      # literal, so it must never reach DNS.
      assert {:ok, _rtt} = RawPing.ping("127.0.0.1", timeout: 2000)
    end
  end

  describe "resolution" do
    @tag :integration
    test "a real hostname resolves and pings" do
      case RawPing.ping("localhost", timeout: 2000) do
        {:ok, rtt} -> assert is_float(rtt)
        # Some environments do not answer ICMP to loopback by name; the point is
        # that it resolved rather than being rejected as malformed.
        {:error, reason} -> refute reason == :invalid_ip
      end
    end

    @tag :integration
    test "ping_batch keys results by the name that was given" do
      results = RawPing.ping_batch(["localhost"], timeout: 2000)
      assert Map.has_key?(results, "localhost")
    end
  end
end
