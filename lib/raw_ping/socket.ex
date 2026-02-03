defmodule RawPing.Socket do
  @moduledoc """
  Low-level socket operations for ICMP using Erlang's `:socket` API.

  This module handles opening raw ICMP sockets, sending packets, and receiving
  replies with proper timeout handling.
  """

  @doc """
  Open a raw ICMP socket.

  Returns `{:ok, socket}` or `{:error, reason}`.

  Requires elevated privileges (root or CAP_NET_RAW).
  """
  @spec open() :: {:ok, :socket.socket()} | {:error, term()}
  def open do
    case :socket.open(:inet, :raw, :icmp) do
      {:ok, socket} ->
        # Set receive buffer size for better performance
        :socket.setopt(socket, {:socket, :rcvbuf}, 65536)
        {:ok, socket}

      {:error, :eperm} ->
        {:error, :permission_denied}

      {:error, reason} ->
        {:error, reason}
    end
  end

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
