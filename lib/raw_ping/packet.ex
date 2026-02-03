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
    type = @icmp_echo_request
    code = 0

    # Generate payload (timestamp + padding)
    timestamp = System.system_time(:microsecond)
    timestamp_bytes = <<timestamp::64>>
    padding_size = max(0, payload_size - 8)
    padding = :binary.copy(<<0>>, padding_size)
    payload = timestamp_bytes <> padding

    # Build packet without checksum first
    packet_without_checksum = <<
      type::8,
      code::8,
      0::16,
      id::16,
      seq::16,
      payload::binary
    >>

    # Calculate checksum
    checksum = calculate_checksum(packet_without_checksum)

    # Build final packet with checksum
    <<
      type::8,
      code::8,
      checksum::16,
      id::16,
      seq::16,
      payload::binary
    >>
  end

  @doc """
  Parse an ICMP echo reply packet.

  The input includes the IP header (20 bytes typically) followed by the ICMP packet.

  Returns `{:ok, id, seq, ttl}` or `{:error, reason}`.
  """
  @spec parse_echo_reply(binary()) :: {:ok, non_neg_integer(), non_neg_integer(), non_neg_integer()} | {:error, term()}
  def parse_echo_reply(data) when byte_size(data) < 28 do
    {:error, :malformed_packet}
  end

  def parse_echo_reply(<<version_ihl::8, _rest::binary>> = data) do
    ihl = version_ihl &&& 0x0F
    ip_header_length = ihl * 4

    # Ensure we have enough data for IP header + at least 8 bytes of ICMP
    if byte_size(data) < ip_header_length + 8 do
      {:error, :malformed_packet}
    else
      # Extract TTL from byte 8 of IP header
      <<_::binary-size(8), ttl::8, _::binary>> = data

      # Extract ICMP portion after IP header
      icmp_data = binary_part(data, ip_header_length, byte_size(data) - ip_header_length)

      case icmp_data do
        <<@icmp_echo_reply::8, 0::8, _checksum::16, id::16, seq::16, _payload::binary>> ->
          {:ok, id, seq, ttl}

        <<type::8, _::binary>> ->
          {:error, {:unexpected_icmp_type, type}}

        _ ->
          {:error, :malformed_icmp}
      end
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
