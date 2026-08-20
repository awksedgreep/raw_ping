defmodule RawPing.PacketTest do
  use ExUnit.Case, async: true

  alias RawPing.Packet

  describe "build_echo_request/3" do
    test "builds valid ICMP packet structure" do
      packet = Packet.build_echo_request(1234, 1, 56)

      # Type (1) + Code (1) + Checksum (2) + ID (2) + Seq (2) + Payload
      assert byte_size(packet) == 8 + 56
    end

    test "sets correct type and code" do
      packet = Packet.build_echo_request(1234, 1, 8)

      <<type::8, code::8, _rest::binary>> = packet

      assert type == 8  # Echo request
      assert code == 0
    end

    test "sets correct ID and sequence" do
      packet = Packet.build_echo_request(0xABCD, 0x1234, 8)

      <<_type::8, _code::8, _checksum::16, id::16, seq::16, _payload::binary>> = packet

      assert id == 0xABCD
      assert seq == 0x1234
    end

    test "generates valid checksum" do
      packet = Packet.build_echo_request(1234, 1, 56)

      # Verify checksum by recalculating
      # Zero out checksum field and recalculate
      <<pre::16, _checksum::16, post::binary>> = packet
      zeroed = <<pre::16, 0::16, post::binary>>

      calculated = Packet.calculate_checksum(zeroed)
      <<_::16, original::16, _::binary>> = packet

      assert calculated == original
    end

    test "creates different packets for different IDs" do
      p1 = Packet.build_echo_request(1, 1, 8)
      p2 = Packet.build_echo_request(2, 1, 8)

      assert p1 != p2
    end

    test "creates different packets for different sequences" do
      p1 = Packet.build_echo_request(1, 1, 8)
      p2 = Packet.build_echo_request(1, 2, 8)

      assert p1 != p2
    end

    test "handles minimum payload size" do
      packet = Packet.build_echo_request(1, 1, 0)

      # Even with 0 requested, we include 8-byte timestamp
      assert byte_size(packet) == 8 + 8
    end

    test "handles large payload size" do
      packet = Packet.build_echo_request(1, 1, 1000)

      assert byte_size(packet) == 8 + 1000
    end
  end

  describe "parse_echo_reply/1" do
    test "parses valid echo reply" do
      # Construct a minimal valid reply:
      # IP header (20 bytes) + ICMP echo reply

      ip_header = <<
        0x45::8,        # Version 4, IHL 5 (20 bytes)
        0::8,           # TOS
        0::16,          # Total length (ignored in test)
        0::16,          # Identification
        0::16,          # Flags + Fragment offset
        64::8,          # TTL = 64
        1::8,           # Protocol = ICMP
        0::16,          # Header checksum (ignored)
        127, 0, 0, 1,   # Source IP
        127, 0, 0, 1    # Dest IP
      >>

      icmp_reply = <<
        0::8,           # Type = Echo Reply
        0::8,           # Code = 0
        0::16,          # Checksum (ignored in parse)
        0xABCD::16,     # ID
        0x0001::16,     # Sequence
        "payload"::binary
      >>

      packet = ip_header <> icmp_reply

      assert {:ok, 0xABCD, 1, 64} = Packet.parse_echo_reply(packet)
    end

    test "extracts correct TTL" do
      ip_header = <<
        0x45::8, 0::8, 0::16, 0::16, 0::16,
        128::8,         # TTL = 128
        1::8, 0::16,
        0::32, 0::32
      >>

      icmp_reply = <<0::8, 0::8, 0::16, 100::16, 5::16>>

      assert {:ok, 100, 5, 128} = Packet.parse_echo_reply(ip_header <> icmp_reply)
    end

    test "returns error for non-echo-reply type" do
      ip_header = <<0x45::8, 0::8, 0::16, 0::16, 0::16, 64::8, 1::8, 0::16, 0::32, 0::32>>

      # Type 3 = Destination Unreachable
      icmp = <<3::8, 0::8, 0::16, 0::16, 0::16>>

      assert {:error, {:unexpected_icmp_type, 3}} = Packet.parse_echo_reply(ip_header <> icmp)
    end

    test "returns error for malformed packet" do
      assert {:error, :malformed_packet} = Packet.parse_echo_reply(<<1, 2, 3>>)
    end

    test "handles variable IP header length" do
      # IHL = 6 (24 bytes, with options)
      ip_header = <<
        0x46::8,        # Version 4, IHL 6
        0::8, 0::16, 0::16, 0::16,
        32::8,          # TTL = 32
        1::8, 0::16,
        0::32, 0::32,
        0::32           # 4 bytes of IP options
      >>

      icmp_reply = <<0::8, 0::8, 0::16, 999::16, 7::16>>

      assert {:ok, 999, 7, 32} = Packet.parse_echo_reply(ip_header <> icmp_reply)
    end
  end

  describe "parse_echo_reply/2 in :dgram mode" do
    test "parses a reply that carries no IP header" do
      icmp_reply = <<0::8, 0::8, 0::16, 4242::16, 3::16, "payload"::binary>>

      assert {:ok, 4242, 3, nil} = Packet.parse_echo_reply(icmp_reply, :dgram)
    end

    test "accepts a minimal 8-byte reply in either mode" do
      # Regression guard: the old parser required 28 bytes because it always
      # expected an IP header. On Linux a datagram echo reply is just the 8-byte
      # ICMP header, which that rule discarded as malformed.
      icmp_reply = <<0::8, 0::8, 0::16, 1::16, 1::16>>
      assert byte_size(icmp_reply) == 8

      assert {:ok, 1, 1, nil} = Packet.parse_echo_reply(icmp_reply, :dgram)
      assert {:ok, 1, 1, nil} = Packet.parse_echo_reply(icmp_reply, :raw)
    end

    test "detects an IP header regardless of the mode it is told" do
      # macOS delivers the IP header on datagram sockets; Linux does not. The
      # parser must follow the bytes, not the mode label.
      ip_header = <<0x45::8, 0::8, 0::16, 0::16, 0::16, 64::8, 1::8, 0::16, 0::32, 0::32>>
      icmp_reply = <<0::8, 0::8, 0::16, 4242::16, 7::16, 0::64>>

      assert {:ok, 4242, 7, 64} = Packet.parse_echo_reply(ip_header <> icmp_reply, :dgram)
      assert {:ok, 4242, 7, 64} = Packet.parse_echo_reply(ip_header <> icmp_reply, :raw)
    end

    test "reports TTL as nil since the kernel strips the IP header" do
      icmp_reply = <<0::8, 0::8, 0::16, 7::16, 9::16, 0::64>>

      assert {:ok, _id, _seq, nil} = Packet.parse_echo_reply(icmp_reply, :dgram)
    end

    test "rejects a reply shorter than the ICMP header" do
      assert {:error, :malformed_packet} = Packet.parse_echo_reply(<<0, 0, 0>>, :dgram)
    end

    test "returns error for non-echo-reply type" do
      icmp = <<3::8, 0::8, 0::16, 0::16, 0::16>>

      assert {:error, {:unexpected_icmp_type, 3}} = Packet.parse_echo_reply(icmp, :dgram)
    end

    test "does not misread the ICMP type byte as an IP header" do
      # In raw mode byte 0 is version/IHL; in dgram mode it is the ICMP type.
      # Parsing a datagram reply as raw would compute a bogus header length.
      icmp_reply = <<0::8, 0::8, 0::16, 555::16, 2::16, 0::128>>

      assert {:ok, 555, 2, nil} = Packet.parse_echo_reply(icmp_reply, :dgram)
    end

    test "parses a real Linux datagram reply" do
      # Captured from an unprivileged SOCK_DGRAM ICMP socket on Debian 13:
      # no IP header, 16 bytes, and the kernel replaced our id 4242 with 1.
      linux = Base.decode16!("0000eee2000100074142434445464748", case: :lower)

      assert byte_size(linux) == 16
      assert {:ok, 1, 7, nil} = Packet.parse_echo_reply(linux, :dgram)
    end

    test "parses a real macOS datagram reply" do
      # Same socket type on Darwin: IP header included and id 4242 preserved.
      darwin =
        Base.decode16!(
          "4500100081e40000400100007f0000017f0000010000cbaf109200070006597f1485b5ac",
          case: :lower
        )

      assert {:ok, 4242, 7, 64} = Packet.parse_echo_reply(darwin, :dgram)
    end

    test "sequence survives on both platforms, which is what matching relies on" do
      linux = Base.decode16!("0000eee2000100074142434445464748", case: :lower)

      darwin =
        Base.decode16!(
          "4500100081e40000400100007f0000017f0000010000cbaf109200070006597f1485b5ac",
          case: :lower
        )

      assert {:ok, _, 7, _} = Packet.parse_echo_reply(linux, :dgram)
      assert {:ok, _, 7, _} = Packet.parse_echo_reply(darwin, :dgram)
    end

    test "defaults to :raw when no mode is given" do
      ip_header = <<0x45::8, 0::8, 0::16, 0::16, 0::16, 64::8, 1::8, 0::16, 0::32, 0::32>>
      icmp_reply = <<0::8, 0::8, 0::16, 11::16, 22::16>>

      assert {:ok, 11, 22, 64} = Packet.parse_echo_reply(ip_header <> icmp_reply)
    end
  end

  describe "calculate_checksum/1" do
    test "returns 0 for all-ones input" do
      # One's complement of all 1s should be 0
      data = <<0xFFFF::16, 0xFFFF::16>>
      assert Packet.calculate_checksum(data) == 0
    end

    test "handles odd-length data" do
      # Should pad and calculate correctly
      data = <<1, 2, 3>>
      checksum = Packet.calculate_checksum(data)

      assert is_integer(checksum)
      assert checksum >= 0
      assert checksum <= 0xFFFF
    end

    test "produces consistent results" do
      data = <<"test data for checksum">>

      c1 = Packet.calculate_checksum(data)
      c2 = Packet.calculate_checksum(data)

      assert c1 == c2
    end

    test "different data produces different checksums" do
      c1 = Packet.calculate_checksum(<<"hello">>)
      c2 = Packet.calculate_checksum(<<"world">>)

      assert c1 != c2
    end

    test "validates known checksum" do
      # ICMP echo request: type=8, code=0, checksum=0, id=1, seq=1, data=8 zeros
      data_without_checksum = <<8, 0, 0, 0, 0, 1, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0>>
      checksum = Packet.calculate_checksum(data_without_checksum)

      # Verify by inserting checksum and rechecking (should be 0 or 0xFFFF)
      <<pre::16, _::16, post::binary>> = data_without_checksum
      with_checksum = <<pre::16, checksum::16, post::binary>>
      verify = Packet.calculate_checksum(with_checksum)

      # A valid checksum should make the overall sum 0xFFFF (or fold to 0)
      assert verify == 0 or verify == 0xFFFF
    end
  end
end
