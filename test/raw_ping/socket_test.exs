defmodule RawPing.SocketTest do
  use ExUnit.Case, async: false

  alias RawPing.Socket

  @moduletag :privileged

  describe "open/1" do
    test "opens a socket successfully" do
      assert {:ok, socket, _mode} = Socket.open()
      assert :ok = Socket.close(socket)
    end

    test "can open multiple sockets" do
      assert {:ok, s1, _} = Socket.open()
      assert {:ok, s2, _} = Socket.open()

      Socket.close(s1)
      Socket.close(s2)
    end
  end

  describe "close/1" do
    test "closes socket successfully" do
      {:ok, socket, _mode} = Socket.open()
      assert :ok = Socket.close(socket)
    end

    test "returns error for already closed socket" do
      {:ok, socket, _mode} = Socket.open()
      Socket.close(socket)

      # Second close should return error
      assert {:error, _reason} = Socket.close(socket)
    end
  end

  describe "send/3" do
    test "sends packet to valid destination" do
      {:ok, socket, _mode} = Socket.open()

      # Build a minimal ICMP packet
      packet = RawPing.Packet.build_echo_request(1, 1, 8)
      dest = {127, 0, 0, 1}

      assert :ok = Socket.send(socket, packet, dest)

      Socket.close(socket)
    end
  end

  describe "recv/2" do
    test "times out when no packet arrives" do
      {:ok, socket, _mode} = Socket.open()

      # Don't send anything, just wait
      start = System.monotonic_time(:millisecond)
      assert {:error, :timeout} = Socket.recv(socket, 100)
      elapsed = System.monotonic_time(:millisecond) - start

      # Should have waited approximately the timeout
      assert elapsed >= 90
      assert elapsed < 300

      Socket.close(socket)
    end

    test "receives packet after send" do
      {:ok, socket, _mode} = Socket.open()

      # Send ping to localhost
      packet = RawPing.Packet.build_echo_request(12345, 1, 8)
      dest = {127, 0, 0, 1}

      :ok = Socket.send(socket, packet, dest)

      # Should receive reply
      assert {:ok, reply} = Socket.recv(socket, 1000)
      assert is_binary(reply)
      assert byte_size(reply) > 0

      Socket.close(socket)
    end
  end
end
