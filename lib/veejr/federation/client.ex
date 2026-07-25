defmodule Veejr.Federation.Client do
  @moduledoc """
  Thin HTTP client for instance-to-instance calls.

  Loopback authorities use plain http so two dev instances can talk;
  everything else is https, no exceptions. `:federation_req_options` lets
  tests plug in `Req.Test`.
  """

  def base_url("localhost" <> _ = authority), do: "http://" <> authority
  def base_url("127.0.0.1" <> _ = authority), do: "http://" <> authority
  def base_url(authority), do: "https://" <> authority

  def get_json(authority, path) do
    case Req.get(req(authority), url: path) do
      {:ok, %Req.Response{status: 200, body: %{} = body}} -> {:ok, body}
      {:ok, %Req.Response{status: status}} -> {:error, {:http, status}}
      {:error, exception} -> {:error, {:unreachable, Exception.message(exception)}}
    end
  end

  def get_avatar(authority, username, version, max_bytes)
      when is_binary(authority) and is_binary(username) and is_integer(version) and
             is_integer(max_bytes) do
    into = fn {:data, data}, {request, response} ->
      body = if is_binary(response.body), do: response.body <> data, else: data
      response = %{response | body: body}

      if byte_size(body) <= max_bytes do
        {:cont, {request, response}}
      else
        {:halt, {request, %{response | body: :too_large}}}
      end
    end

    case Req.get(req(authority),
           url: "/avatars/#{URI.encode(username)}",
           params: [v: version],
           headers: [{"accept", "image/jpeg"}],
           redirect: false,
           decode_body: false,
           into: into
         ) do
      {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) ->
        {:ok, body}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:http, status}}

      {:error, exception} ->
        {:error, {:unreachable, Exception.message(exception)}}
    end
  end

  @doc """
  Signed federation POST: the JSON body is encoded once, and the signature
  covers path, timestamp, and a hash of those exact bytes.
  """
  def post_json(authority, path, payload) do
    body = Jason.encode!(payload)
    timestamp = Integer.to_string(System.system_time(:second))
    signature = Veejr.Federation.Identity.sign_request(path, timestamp, body)

    headers = [
      {"content-type", "application/json"},
      {"x-veejr-authority", Veejr.instance_authority()},
      {"x-veejr-timestamp", timestamp},
      {"x-veejr-signature", signature}
    ]

    case Req.post(req(authority), url: path, body: body, headers: headers) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 -> {:ok, body}
      {:ok, %Req.Response{status: status}} -> {:error, {:http, status}}
      {:error, exception} -> {:error, {:unreachable, Exception.message(exception)}}
    end
  end

  defp req(authority) do
    options =
      [
        base_url: base_url(authority),
        retry: false,
        connect_options: [timeout: 4_000],
        receive_timeout: 8_000,
        # Bypass the ngrok/tunnel browser interstitial so instance-to-instance
        # calls always get the JSON API, never the HTML warning page. Harmless
        # for non-tunnel hosts.
        headers: [{"ngrok-skip-browser-warning", "true"}]
      ] ++ Application.get_env(:veejr, :federation_req_options, [])

    Req.new(options)
  end
end
