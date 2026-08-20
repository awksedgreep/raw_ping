defmodule RawPing.Packet do
  @moduledoc """
  ICMP packet construction and parsing.

  Handles building ICMP echo request packets and parsing echo reply packets.

  ## ICMP Echo Request/Reply Format

      0                   1                   2                   3
      0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
      +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
      |     Type      |     Code      |          Checksum             |
      +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
      |           Identifier          |        Sequence Number        |
      +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
      |     Data ...
      +-+-+-+-+-+-+-+-

  - Type 8, Code 0: Echo Request
  - Type 0, Code 0: Echo Reply
  """

  import Bitwise

  # ICMP types
  @icmp_echo_reply 0
  @icmp_echo_request 8

  @doc """
  Build an ICMP echo request packet.

  ## Parameters

    * `id` - Identifier (16-bit)
    * `seq` - Sequence number (16-bit)
    * `payload_size` - Size of payload data in bytes

  Returns a binary packet ready to send.
  """
  @spec build_echo_request(non_neg_integer(), non_neg_integer(), non_neg_integer()) :: binary()
  def build_echo_request(id, seq, payload_size \\ 56) do
    timestamp = System.system_time(:microsecond)
    padding_size = max(0, payload_size - 8)

    # Build packet with zero checksum placeholder
    # Optimization: zero padding contributes nothing to checksum, so we only
    # checksum the 16-byte header+timestamp regardless of payload size
    packet = <<
      @icmp_echo_request::8,
      0::8,
      0::16,
      id::16,
      seq::16,
      timestamp::64,
      0::size(padding_size)-unit(8)
    >>

    # Calculate checksum over header+timestamp only (first 16 bytes)
    <<header::binary-size(16), _rest::binary>> = packet
    checksum = calculate_checksum(header)

    # Insert checksum at bytes 2-3
    <<pre::binary-size(2), _::16, post::binary>> = packet
    <<pre::binary, checksum::16, post::binary>>
  end

  @doc """
  Parse an ICMP echo reply packet.

  Accepts input with or without a leading IP header, detecting which it got.
  Whether the kernel includes the IP header is a property of the **host**, not
  of the socket type: on Linux a datagram ICMP socket strips it, while on
  macOS/BSD the same socket delivers it intact. Assuming either one breaks on
  the other platform, so this inspects the data instead.

  When an IP header is present, TTL comes from it. When it is absent, TTL is
  returned as `nil` — recovering it would need `IP_RECVTTL` ancillary data.

  The `mode` argument is accepted for symmetry with `RawPing.Socket.open/1` and
  does not affect parsing.

  Note that Linux substitutes its own value for the identifier on datagram
  sockets, so the returned `id` may not be the one passed to
  `build_echo_request/3`. Match on sequence when reading from a datagram socket.

  Returns `{:ok, id, seq, ttl}` or `{:error, reason}`.
  """
  @spec parse_echo_reply(binary(), RawPing.Socket.mode()) ::
          {:ok, non_neg_integer(), non_neg_integer(), non_neg_integer() | nil} | {:error, term()}
  def parse_echo_reply(data, mode \\ :raw)

  # 8 bytes is the ICMP header, the smallest thing that could be a valid reply.
  def parse_echo_reply(data, _mode) when byte_size(data) < 8 do
    {:error, :malformed_packet}
  end

  def parse_echo_reply(data, _mode) do
    case split_ip_header(data) do
      {:ok, icmp_data, ttl} -> parse_icmp(icmp_data, ttl)
      :error -> {:error, :malformed_packet}
    end
  end

  # An IPv4 header opens with version 4 in the high nibble (0x4_). An ICMP echo
  # reply opens with type 0, and every ICMP type we care about is small, so the
  # two cannot be confused in practice.
  defp split_ip_header(<<version_ihl::8, _rest::binary>> = data)
       when version_ihl >>> 4 == 4 do
    ihl = version_ihl &&& 0x0F
    ip_header_length = ihl * 4

    # A valid IPv4 header is at least 5 words, and the ICMP message needs 8 more
    if ihl >= 5 and byte_size(data) >= ip_header_length + 8 do
      # Extract TTL from byte 8 of IP header
      <<_::binary-size(8), ttl::8, _::binary>> = data
      {:ok, binary_part(data, ip_header_length, byte_size(data) - ip_header_length), ttl}
    else
      :error
    end
  end

  defp split_ip_header(data), do: {:ok, data, nil}

  defp parse_icmp(icmp_data, ttl) do
    case icmp_data do
      <<@icmp_echo_reply::8, 0::8, _checksum::16, id::16, seq::16, _payload::binary>> ->
        {:ok, id, seq, ttl}

      <<type::8, _::binary>> ->
        {:error, {:unexpected_icmp_type, type}}

      _ ->
        {:error, :malformed_icmp}
    end
  end

  @doc """
  Calculate the ICMP checksum (one's complement of one's complement sum).
  """
  @spec calculate_checksum(binary()) :: non_neg_integer()
  def calculate_checksum(data) do
    # Pad to even length if needed
    padded =
      if rem(byte_size(data), 2) == 1 do
        data <> <<0>>
      else
        data
      end

    # Sum all 16-bit words
    sum = sum_words(padded, 0)

    # Fold 32-bit sum to 16 bits
    folded = fold_sum(sum)

    # One's complement
    bnot(folded) &&& 0xFFFF
  end

  # Sum 16-bit words
  defp sum_words(<<>>, acc), do: acc
  defp sum_words(<<word::16, rest::binary>>, acc), do: sum_words(rest, acc + word)

  # Fold 32-bit sum into 16 bits
  defp fold_sum(sum) when sum <= 0xFFFF, do: sum
  defp fold_sum(sum), do: fold_sum((sum &&& 0xFFFF) + (sum >>> 16))
end
