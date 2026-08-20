defmodule RawPing.Socket do
  @moduledoc """
  Low-level socket operations for ICMP using Erlang's `:socket` API.

  This module handles opening ICMP sockets, sending packets, and receiving
  replies with proper timeout handling.

  ## Socket modes

  Two kernel interfaces can carry ICMP echo:

    * `:dgram` — unprivileged ICMP datagram sockets (`SOCK_DGRAM`/`IPPROTO_ICMP`).
      Needs **no capability**. On Linux, availability is gated by
      `net.ipv4.ping_group_range`, which must include the running process's GID;
      many distributions ship this wide open. macOS permits it by default.

    * `:raw` — raw sockets (`SOCK_RAW`). Requires root or `CAP_NET_RAW`.

  `:auto` (the default) tries `:dgram` first and falls back to `:raw`, so a
  process gets the least-privileged interface that works on the host.

  The mode matters to callers because the two deliver different bytes: raw
  sockets include the IP header on receive, datagram sockets do not, and the
  kernel rewrites the ICMP identifier on the datagram path. `open/1` returns the
  negotiated mode so parsing and reply matching can adapt. See
  `RawPing.Packet.parse_echo_reply/2`.
  """

  @type mode :: :dgram | :raw

  @doc """
  Open an ICMP socket.

  ## Options

    * `:mode` - `:auto` (default), `:dgram`, or `:raw`

  Returns `{:ok, socket, mode}` or `{:error, reason}`, where `mode` is the
  interface actually negotiated.

  With `:auto`, no elevated privileges are needed as long as datagram ICMP is
  permitted for this process; otherwise it falls back to `:raw`, which requires
  root or `CAP_NET_RAW`.
  """
  @spec open(keyword()) :: {:ok, :socket.socket(), mode()} | {:error, term()}
  def open(opts \\ []) do
    case Keyword.get(opts, :mode, :auto) do
      :auto ->
        case open_mode(:dgram) do
          {:ok, _socket, _mode} = ok -> ok
          {:error, _reason} -> open_mode(:raw)
        end

      :dgram ->
        open_mode(:dgram)

      :raw ->
        open_mode(:raw)

      other ->
        {:error, {:invalid_mode, other}}
    end
  end

  # IPPROTO_ICMP. Passed as a number rather than the atom `:icmp` on purpose:
  # Erlang resolves protocol atoms through the system protocol database, and
  # minimal container images routinely omit /etc/protocols (it ships in Debian's
  # `netbase`, which slim variants leave out). There, `:icmp` fails with
  # `{:invalid, {:protocol, :icmp}}` — a confusing error, since nothing is wrong
  # with the address or the permissions. The number is universal.
  @ipproto_icmp 1

  defp open_mode(mode) do
    case :socket.open(:inet, mode, @ipproto_icmp) do
      {:ok, socket} ->
        # Set receive buffer size for better performance
        :socket.setopt(socket, {:socket, :rcvbuf}, 65536)
        {:ok, socket, mode}

      {:error, reason} ->
        {:error, normalize_error(reason)}
    end
  end

  # Both appear in practice: :eperm for a denied raw socket, :eacces when the
  # process GID falls outside net.ipv4.ping_group_range.
  defp normalize_error(:eperm), do: :permission_denied
  defp normalize_error(:eacces), do: :permission_denied
  defp normalize_error(reason), do: reason

  @doc """
  Close an ICMP socket.
  """
  @spec close(:socket.socket()) :: :ok | {:error, term()}
  def close(socket) do
    :socket.close(socket)
  end

  @doc """
  Send an ICMP packet to a destination IP.
  """
  @spec send(:socket.socket(), binary(), :inet.ip_address()) :: :ok | {:error, term()}
  def send(socket, packet, dest_ip) do
    dest = %{family: :inet, addr: dest_ip, port: 0}

    case :socket.sendto(socket, packet, dest) do
      :ok -> :ok
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Receive an ICMP reply with timeout.

  Returns `{:ok, data}` or `{:error, :timeout}` / `{:error, reason}`.

  On `:raw` sockets `data` begins with the IP header. On `:dgram` sockets the
  kernel strips it and `data` is the ICMP message alone.
  """
  @spec recv(:socket.socket(), non_neg_integer()) :: {:ok, binary()} | {:error, term()}
  def recv(socket, timeout_ms) do
    # Use select to implement timeout
    case :socket.recvfrom(socket, 0, [], timeout_ms) do
      {:ok, {_source, data}} ->
        {:ok, data}

      {:error, :timeout} ->
        {:error, :timeout}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
