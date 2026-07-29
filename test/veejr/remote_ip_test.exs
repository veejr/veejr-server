defmodule Veejr.RemoteIpTest do
  use ExUnit.Case, async: true

  alias Veejr.RemoteIp

  describe "resolve/2 without a trusted peer" do
    test "uses the peer address and ignores a forged forwarded chain" do
      # A client connecting directly can claim anything it likes in
      # x-forwarded-for; none of it may be believed.
      assert RemoteIp.resolve({203, 0, 113, 5}, ["1.2.3.4"]) == "203.0.113.5"
      assert RemoteIp.resolve({203, 0, 113, 5}, []) == "203.0.113.5"
    end
  end

  describe "resolve/2 behind a trusted proxy" do
    test "returns the client address from a single-hop chain" do
      assert RemoteIp.resolve({127, 0, 0, 1}, ["203.0.113.5"]) == "203.0.113.5"
      assert RemoteIp.resolve({172, 18, 0, 1}, ["203.0.113.5"]) == "203.0.113.5"
    end

    test "walks right to left and stops at the first untrusted address" do
      # Caddy appends the address it saw; entries to the left are attacker
      # controlled. The rightmost untrusted entry is the real client.
      assert RemoteIp.resolve({127, 0, 0, 1}, ["1.2.3.4, 203.0.113.5, 10.0.0.7"]) ==
               "203.0.113.5"
    end

    test "does not let a client spoof its address by prepending entries" do
      spoofed = "198.51.100.9, 203.0.113.5"
      assert RemoteIp.resolve({127, 0, 0, 1}, [spoofed]) == "203.0.113.5"
    end

    test "handles the chain arriving as separate header values" do
      assert RemoteIp.resolve({127, 0, 0, 1}, ["1.2.3.4", "203.0.113.5"]) == "203.0.113.5"
    end

    test "falls back to the peer when every hop is trusted" do
      assert RemoteIp.resolve({127, 0, 0, 1}, ["10.0.0.7, 192.168.1.4"]) == "127.0.0.1"
    end

    test "falls back to the peer when the chain is empty or unparseable" do
      assert RemoteIp.resolve({127, 0, 0, 1}, [""]) == "127.0.0.1"
      assert RemoteIp.resolve({127, 0, 0, 1}, ["not-an-address"]) == "127.0.0.1"
    end

    test "strips a source port from an IPv4 entry" do
      assert RemoteIp.resolve({127, 0, 0, 1}, ["203.0.113.5:51234"]) == "203.0.113.5"
    end

    test "handles bracketed IPv6 entries" do
      assert RemoteIp.resolve({0, 0, 0, 0, 0, 0, 0, 1}, ["[2001:db8::1]:443"]) == "2001:db8::1"
    end

    test "handles a bare IPv6 entry without stripping its colons" do
      assert RemoteIp.resolve({0, 0, 0, 0, 0, 0, 0, 1}, ["2001:db8::1"]) == "2001:db8::1"
    end
  end

  describe "trusted_proxy?/1" do
    test "recognises loopback and private ranges" do
      assert RemoteIp.trusted_proxy?({127, 0, 0, 1})
      assert RemoteIp.trusted_proxy?({10, 1, 2, 3})
      assert RemoteIp.trusted_proxy?({192, 168, 0, 251})
      assert RemoteIp.trusted_proxy?({172, 18, 0, 1})
      assert RemoteIp.trusted_proxy?({0, 0, 0, 0, 0, 0, 0, 1})
    end

    test "rejects public addresses, including ones adjacent to private ranges" do
      refute RemoteIp.trusted_proxy?({203, 0, 113, 5})
      refute RemoteIp.trusted_proxy?({8, 8, 8, 8})
      # 172.32/12 is public even though 172.16/12 is not.
      refute RemoteIp.trusted_proxy?({172, 32, 0, 1})
      refute RemoteIp.trusted_proxy?({11, 0, 0, 1})
      refute RemoteIp.trusted_proxy?({2001, 0xDB8, 0, 0, 0, 0, 0, 1})
    end
  end
end
