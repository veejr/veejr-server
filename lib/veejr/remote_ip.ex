defmodule Veejr.RemoteIp do
  @moduledoc """
  Resolves the real client address behind a reverse proxy.

  Every deployed instance sits behind a TLS-terminating proxy (Caddy in the
  project deployment, see `docs/HOST_RUNBOOK.md`), so `conn.remote_ip` is the
  proxy's address for every request. Rate limiting on that value would put the
  entire internet into one bucket and lock the instance out on the first burst,
  so the client address has to come from `x-forwarded-for` instead.

  `x-forwarded-for` is caller-controlled, and a client can prepend arbitrary
  entries to it. The header is therefore only consulted when the immediate peer
  is itself a trusted proxy, and the chain is then walked from right to left,
  returning the first address that is *not* a configured proxy. That address is
  the last one a trusted hop actually observed; everything to its left may be
  forged.

  Configure trusted hops with:

      config :veejr, :trusted_proxies, ["127.0.0.0/8", "::1/128", ...]

  The default covers loopback and the RFC 1918 / RFC 4193 private ranges, which
  is what a container or same-host proxy connects from. An instance exposed
  directly to the internet with no proxy is unaffected: its peer address is
  public, is not trusted, and `x-forwarded-for` is ignored entirely.
  """

  import Bitwise

  @default_trusted_proxies [
    "127.0.0.0/8",
    "::1/128",
    "10.0.0.0/8",
    "172.16.0.0/12",
    "192.168.0.0/16",
    "169.254.0.0/16",
    "fc00::/7",
    "fe80::/10"
  ]

  @doc """
  Returns the client address for a `Plug.Conn` as a string.
  """
  def from_conn(%Plug.Conn{} = conn) do
    resolve(conn.remote_ip, Plug.Conn.get_req_header(conn, "x-forwarded-for"))
  end

  @doc """
  Returns the client address for a LiveView socket as a string.

  Requires `:peer_data` and `:x_headers` in the endpoint's socket
  `connect_info`. Falls back to `"unknown"` on a static (not yet connected)
  render, where no peer information exists yet.
  """
  def from_socket(socket) do
    peer = Phoenix.LiveView.get_connect_info(socket, :peer_data)
    headers = Phoenix.LiveView.get_connect_info(socket, :x_headers) || []

    case peer do
      %{address: address} ->
        forwarded =
          for {"x-forwarded-for", value} <- headers, do: value

        resolve(address, forwarded)

      _ ->
        "unknown"
    end
  end

  @doc """
  Resolves a peer address plus `x-forwarded-for` header values to a client
  address string.
  """
  def resolve(peer_address, forwarded_values) when is_list(forwarded_values) do
    if trusted_proxy?(peer_address) do
      forwarded_values
      |> Enum.flat_map(&String.split(&1, ","))
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.map(&strip_port/1)
      |> Enum.reverse()
      |> Enum.find_value(fn candidate ->
        case parse(candidate) do
          {:ok, address} -> if trusted_proxy?(address), do: nil, else: to_string_address(address)
          :error -> nil
        end
      end)
      |> case do
        nil -> to_string_address(peer_address)
        client -> client
      end
    else
      to_string_address(peer_address)
    end
  end

  @doc "Returns true when the address falls inside a configured trusted-proxy range."
  def trusted_proxy?(address) when is_tuple(address) do
    Enum.any?(trusted_proxies(), &in_range?(address, &1))
  end

  def trusted_proxy?(_address), do: false

  defp trusted_proxies do
    Application.get_env(:veejr, :trusted_proxies, @default_trusted_proxies)
    |> Enum.map(&parse_cidr/1)
    |> Enum.reject(&is_nil/1)
  end

  # IPv6 addresses in a forwarded chain may be bracketed, and any entry may
  # carry a source port. Neither belongs in the address we bucket on.
  defp strip_port("[" <> rest) do
    case String.split(rest, "]", parts: 2) do
      [address | _] -> address
      _ -> rest
    end
  end

  defp strip_port(value) do
    # Only strip a port from IPv4/hostname forms: a bare IPv6 address contains
    # several colons and must be left intact.
    case String.split(value, ":") do
      [address, _port] -> address
      _ -> value
    end
  end

  defp parse(value) do
    case :inet.parse_address(String.to_charlist(value)) do
      {:ok, address} -> {:ok, address}
      {:error, _} -> :error
    end
  end

  defp to_string_address(address) when is_tuple(address) do
    case :inet.ntoa(address) do
      {:error, _} -> "unknown"
      charlist -> List.to_string(charlist)
    end
  end

  defp to_string_address(_), do: "unknown"

  defp parse_cidr(cidr) when is_binary(cidr) do
    with [address, bits] <- String.split(cidr, "/", parts: 2),
         {:ok, parsed} <- parse(address),
         {prefix, ""} <- Integer.parse(bits) do
      {parsed, prefix}
    else
      _ ->
        case parse(cidr) do
          {:ok, parsed} -> {parsed, full_prefix(parsed)}
          :error -> nil
        end
    end
  end

  defp parse_cidr(_), do: nil

  defp full_prefix(address) when tuple_size(address) == 4, do: 32
  defp full_prefix(address) when tuple_size(address) == 8, do: 128

  # An IPv4 peer never falls inside an IPv6 range and vice versa, so compare
  # only same-family tuples.
  defp in_range?(address, {network, prefix})
       when tuple_size(address) == tuple_size(network) do
    size = bit_size_for(address)
    mask = mask(size, prefix)
    band(to_integer(address), mask) == band(to_integer(network), mask)
  end

  defp in_range?(_address, _range), do: false

  defp bit_size_for(address) when tuple_size(address) == 4, do: 32
  defp bit_size_for(address) when tuple_size(address) == 8, do: 128

  defp mask(size, prefix) when prefix >= 0 and prefix <= size do
    bsl(bsl(1, prefix) - 1, size - prefix)
  end

  defp mask(size, _prefix), do: bsl(1, size) - 1

  defp to_integer(address) do
    width = if tuple_size(address) == 4, do: 8, else: 16

    address
    |> Tuple.to_list()
    |> Enum.reduce(0, fn part, acc -> bsl(acc, width) + part end)
  end
end
